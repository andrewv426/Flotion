import Foundation
import GRDB

public extension Workspace {
    // MARK: Reads

    func page(id: String) throws -> Page? {
        try pool.read { try Self.fetchPage($0, id) }
    }

    func requirePage(id: String) throws -> Page {
        guard let page = try page(id: id) else { throw FlotionError.notFound("page \(id)") }
        return page
    }

    /// Every live page, ordered so siblings are adjacent and in sidebar order.
    func pages() throws -> [Page] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Page.columns) FROM pages WHERE archived_at IS NULL ORDER BY parent_id, position")
                .map(Page.init(row:))
        }
    }

    func children(of parentID: String?) throws -> [Page] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Page.columns) FROM pages
                WHERE archived_at IS NULL AND parent_id IS ? ORDER BY position
                """, arguments: [parentID]).map(Page.init(row:))
        }
    }

    /// Pages in the Trash. Only the roots of each archived subtree are returned.
    func archivedPages() throws -> [Page] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Page.columns) FROM pages p WHERE archived_at IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM pages q WHERE q.id = p.parent_id AND q.archived_at = p.archived_at)
                ORDER BY archived_at DESC
                """).map(Page.init(row:))
        }
    }

    // MARK: Writes

    @discardableResult
    func createPage(title: String, parentID: String? = nil, icon: String? = nil,
                    blocks: [Block] = [], context: ChangeContext? = nil) throws -> Page {
        let page = try pool.write { db -> Page in
            if let parentID, try Self.fetchPage(db, parentID) == nil {
                throw FlotionError.notFound("parent page \(parentID)")
            }
            let last = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM pages WHERE parent_id IS ?", arguments: [parentID]) ?? 0
            let page = Page(parentID: parentID, title: title, icon: icon, position: last + 1024)
            try Self.writePage(db, page)
            try Self.log(db, entity: "page", id: page.id, pageID: page.id, before: nil as Page?, after: page, context)
            if !blocks.isEmpty {
                _ = try Self.insert(db, pageID: page.id, drafts: blocks, at: .end, context: nil)
            }
            return page
        }
        notifyIfExternal(context)
        return page
    }

    /// Double optionals distinguish "leave unchanged" (nil) from "clear" (.some(nil)).
    @discardableResult
    func updatePage(id: String, title: String? = nil, icon: String?? = nil, parentID: String?? = nil,
                    context: ChangeContext? = nil) throws -> Page {
        let page = try pool.write { db -> Page in
            guard let before = try Self.fetchPage(db, id) else { throw FlotionError.notFound("page \(id)") }
            var page = before
            if let title { page.title = title }
            if let icon { page.icon = icon }
            if let parentID, parentID != before.parentID {
                try Self.checkNoCycle(db, moving: id, under: parentID)
                page.parentID = parentID
                let last = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM pages WHERE parent_id IS ?", arguments: [parentID]) ?? 0
                page.position = last + 1024
            }
            page.updatedAt = Date()
            try Self.writePage(db, page)
            try Self.log(db, entity: "page", id: id, pageID: id, before: before, after: page, context)
            return page
        }
        notifyIfExternal(context)
        return page
    }

    /// Sidebar drag: place `id` under `parentID`, directly after `sibling` (or first when nil).
    func movePage(id: String, toParent parentID: String?, after sibling: String?) throws {
        try pool.write { db in
            guard var page = try Self.fetchPage(db, id) else { throw FlotionError.notFound("page \(id)") }
            try Self.checkNoCycle(db, moving: id, under: parentID)
            let siblings = try Row.fetchAll(db, sql: """
                SELECT id, position FROM pages WHERE archived_at IS NULL AND parent_id IS ? AND id != ? ORDER BY position
                """, arguments: [parentID, id])
            var prev = 0.0
            var next: Double?
            if let sibling, let i = siblings.firstIndex(where: { ($0[0] as String) == sibling }) {
                prev = siblings[i][1]
                next = i + 1 < siblings.count ? siblings[i + 1][1] as Double : nil
            } else {
                next = siblings.first.map { $0[1] as Double }
            }
            page.parentID = parentID
            page.position = next.map { (prev + $0) / 2 } ?? prev + 1024
            page.updatedAt = Date()
            try Self.writePage(db, page)
        }
    }

    /// Moves a page and its subpages to the Trash.
    func archivePage(id: String, context: ChangeContext? = nil) throws {
        try pool.write { db in
            guard let before = try Self.fetchPage(db, id) else { throw FlotionError.notFound("page \(id)") }
            let now = ts(Date())
            try db.execute(sql: """
                WITH RECURSIVE tree(id) AS (
                    SELECT ? UNION ALL SELECT p.id FROM pages p JOIN tree ON p.parent_id = tree.id
                )
                UPDATE pages SET archived_at = ? WHERE id IN (SELECT id FROM tree) AND archived_at IS NULL
                """, arguments: [id, now])
            let after = try Self.fetchPage(db, id)
            try Self.log(db, entity: "page", id: id, pageID: id, before: before, after: after, context)
        }
        notifyIfExternal(context)
    }

    func restorePage(id: String) throws {
        try pool.write { db in try Self.restore(db, id) }
    }

    func deletePagePermanently(id: String) throws {
        try pool.write { db in
            let ids = try String.fetchAll(db, sql: """
                WITH RECURSIVE tree(id) AS (
                    SELECT ? UNION ALL SELECT p.id FROM pages p JOIN tree ON p.parent_id = tree.id
                ) SELECT id FROM tree
                """, arguments: [id])
            for pid in ids {
                try db.execute(sql: "DELETE FROM blocks WHERE page_id = ?", arguments: [pid])
                try db.execute(sql: "DELETE FROM pages WHERE id = ?", arguments: [pid])
            }
        }
    }
}

// MARK: - Internals

extension Workspace {
    static func fetchPage(_ db: Database, _ id: String) throws -> Page? {
        try Row.fetchOne(db, sql: "SELECT \(Page.columns) FROM pages WHERE id = ?", arguments: [id]).map(Page.init(row:))
    }

    static func writePage(_ db: Database, _ p: Page) throws {
        try db.execute(sql: """
            INSERT INTO pages (\(Page.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id, title = excluded.title, icon = excluded.icon,
                position = excluded.position, updated_at = excluded.updated_at, archived_at = excluded.archived_at
            """, arguments: [p.id, p.parentID, p.title, p.icon, p.position, ts(p.createdAt), ts(p.updatedAt), p.archivedAt.map(ts)])
    }

    static func restore(_ db: Database, _ id: String) throws {
        guard let page = try fetchPage(db, id), let stamp = page.archivedAt else { return }
        try db.execute(sql: """
            WITH RECURSIVE tree(id) AS (
                SELECT ? UNION ALL SELECT p.id FROM pages p JOIN tree ON p.parent_id = tree.id
            )
            UPDATE pages SET archived_at = NULL WHERE id IN (SELECT id FROM tree) AND archived_at = ?
            """, arguments: [id, ts(stamp)])
        // A restored page whose parent is still in the Trash becomes top-level.
        try db.execute(sql: """
            UPDATE pages SET parent_id = NULL WHERE id = ?
            AND parent_id IN (SELECT id FROM pages WHERE archived_at IS NOT NULL)
            """, arguments: [id])
    }

    static func checkNoCycle(_ db: Database, moving id: String, under parentID: String?) throws {
        guard let parentID else { return }
        var cursor: String? = parentID
        while let current = cursor {
            if current == id { throw FlotionError.invalid("A page cannot be moved inside itself.") }
            cursor = try String.fetchOne(db, sql: "SELECT parent_id FROM pages WHERE id = ?", arguments: [current])
        }
    }

    static func touchPage(_ db: Database, _ id: String) throws {
        try db.execute(sql: "UPDATE pages SET updated_at = ? WHERE id = ?", arguments: [ts(Date()), id])
    }
}
