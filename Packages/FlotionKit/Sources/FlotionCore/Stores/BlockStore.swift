import Foundation
import GRDB

public extension Workspace {
    // MARK: Reads

    func blocks(pageID: String) throws -> [Block] {
        try pool.read { try Self.fetchBlocks($0, pageID) }
    }

    func block(id: String) throws -> Block? {
        try pool.read { try Self.fetchBlock($0, id) }
    }

    // MARK: Editor saves (the user's own edits: not logged, no cross-process ping)

    /// Applies one debounced editor save in a single transaction.
    func saveEditorChanges(pageID: String, upserts: [Block], deletes: [String]) throws {
        guard !upserts.isEmpty || !deletes.isEmpty else { return }
        try pool.write { db in
            let upsert = try db.cachedStatement(sql: Block.upsertSQL)
            for var block in upserts {
                block.pageID = pageID
                try upsert.execute(arguments: try block.arguments())
            }
            if !deletes.isEmpty {
                let remove = try db.cachedStatement(sql: "DELETE FROM blocks WHERE id = ? AND page_id = ?")
                for id in deletes { try remove.execute(arguments: [id, pageID]) }
            }
            try Self.touchPage(db, pageID)
        }
    }

    // MARK: Structured writes (MCP and AI pass a context so the change is logged)

    @discardableResult
    func insertBlocks(pageID: String, _ drafts: [Block], at position: InsertPosition = .end,
                      context: ChangeContext? = nil) throws -> [Block] {
        let inserted = try pool.write { db -> [Block] in
            guard try Self.fetchPage(db, pageID) != nil else { throw FlotionError.notFound("page \(pageID)") }
            let blocks = try Self.insert(db, pageID: pageID, drafts: drafts, at: position, context: context)
            try Self.touchPage(db, pageID)
            return blocks
        }
        notifyIfExternal(context)
        return inserted
    }

    /// Replaces one block with one or more blocks (the first keeps the original id and position).
    @discardableResult
    func replaceBlock(id: String, with drafts: [Block], context: ChangeContext? = nil) throws -> [Block] {
        guard let first = drafts.first else { throw FlotionError.invalid("Replacement content is empty.") }
        let result = try pool.write { db -> [Block] in
            guard let before = try Self.fetchBlock(db, id) else { throw FlotionError.notFound("block \(id)") }
            var head = first
            head.id = before.id; head.pageID = before.pageID; head.position = before.position
            head.depth = first.depth + before.depth
            head.updatedAt = Date()
            try db.execute(sql: Block.upsertSQL, arguments: try head.arguments())
            try Self.log(db, entity: "block", id: id, pageID: before.pageID, before: before, after: head, context)
            var out = [head]
            if drafts.count > 1 {
                let rest = drafts.dropFirst().map { d -> Block in var d = d; d.depth += before.depth; return d }
                out += try Self.insert(db, pageID: before.pageID, drafts: rest, at: .after(id), context: context)
            }
            try Self.touchPage(db, before.pageID)
            return out
        }
        notifyIfExternal(context)
        return result
    }

    @discardableResult
    func updateBlock(id: String, context: ChangeContext? = nil, _ mutate: (inout Block) -> Void) throws -> Block {
        let block = try pool.write { db -> Block in
            guard let before = try Self.fetchBlock(db, id) else { throw FlotionError.notFound("block \(id)") }
            var block = before
            mutate(&block)
            block.id = before.id; block.pageID = before.pageID
            block.updatedAt = Date()
            try db.execute(sql: Block.upsertSQL, arguments: try block.arguments())
            try Self.log(db, entity: "block", id: id, pageID: before.pageID, before: before, after: block, context)
            try Self.touchPage(db, before.pageID)
            return block
        }
        notifyIfExternal(context)
        return block
    }

    func deleteBlock(id: String, context: ChangeContext? = nil) throws {
        try pool.write { db in
            guard let before = try Self.fetchBlock(db, id) else { throw FlotionError.notFound("block \(id)") }
            try db.execute(sql: "DELETE FROM blocks WHERE id = ?", arguments: [id])
            try Self.log(db, entity: "block", id: id, pageID: before.pageID, before: before, after: nil as Block?, context)
            try Self.touchPage(db, before.pageID)
        }
        notifyIfExternal(context)
    }
}

// MARK: - Internals

extension Workspace {
    static func fetchBlocks(_ db: Database, _ pageID: String) throws -> [Block] {
        let rows = try Row.fetchCursor(db, sql: "SELECT \(Block.columns) FROM blocks WHERE page_id = ? ORDER BY position", arguments: [pageID])
        var out: [Block] = []
        while let row = try rows.next() { out.append(try Block(row: row)) }
        return out
    }

    static func fetchBlock(_ db: Database, _ id: String) throws -> Block? {
        try Row.fetchOne(db, sql: "SELECT \(Block.columns) FROM blocks WHERE id = ?", arguments: [id]).map { try Block(row: $0) }
    }

    /// Assigns ids and positions to `drafts` and writes them at `position`.
    static func insert(_ db: Database, pageID: String, drafts: [Block], at position: InsertPosition,
                       context: ChangeContext?) throws -> [Block] {
        guard !drafts.isEmpty else { return [] }
        var (prev, next) = try neighbours(db, pageID: pageID, at: position)
        if let n = next, (n - prev) / Double(drafts.count + 1) < 1e-6 {
            try renumber(db, pageID: pageID)
            (prev, next) = try neighbours(db, pageID: pageID, at: position)
        }
        let step = next.map { ($0 - prev) / Double(drafts.count + 1) } ?? 1024
        let upsert = try db.cachedStatement(sql: Block.upsertSQL)
        var out: [Block] = []
        out.reserveCapacity(drafts.count)
        let now = Date()
        for (i, draft) in drafts.enumerated() {
            var block = draft
            block.pageID = pageID
            block.position = prev + step * Double(i + 1)
            block.updatedAt = now
            try upsert.execute(arguments: try block.arguments())
            try log(db, entity: "block", id: block.id, pageID: pageID, before: nil as Block?, after: block, context)
            out.append(block)
        }
        return out
    }

    /// Positions of the blocks on either side of an insertion point.
    static func neighbours(_ db: Database, pageID: String, at position: InsertPosition) throws -> (Double, Double?) {
        switch position {
        case .start:
            let first = try Double.fetchOne(db, sql: "SELECT MIN(position) FROM blocks WHERE page_id = ?", arguments: [pageID])
            return (0, first)
        case .end:
            let last = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM blocks WHERE page_id = ?", arguments: [pageID])
            return (last ?? 0, nil)
        case .after(let id):
            guard let prev = try Double.fetchOne(db, sql: "SELECT position FROM blocks WHERE id = ? AND page_id = ?", arguments: [id, pageID]) else {
                throw FlotionError.notFound("block \(id) on page \(pageID)")
            }
            let next = try Double.fetchOne(db, sql: "SELECT MIN(position) FROM blocks WHERE page_id = ? AND position > ?", arguments: [pageID, prev])
            return (prev, next)
        }
    }

    static func renumber(_ db: Database, pageID: String) throws {
        let ids = try String.fetchAll(db, sql: "SELECT id FROM blocks WHERE page_id = ? ORDER BY position", arguments: [pageID])
        let update = try db.cachedStatement(sql: "UPDATE blocks SET position = ? WHERE id = ?")
        for (i, id) in ids.enumerated() { try update.execute(arguments: [Double(i + 1) * 1024, id]) }
    }
}
