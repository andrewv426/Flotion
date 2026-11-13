import Foundation
import GRDB
import notify

public extension Workspace {
    /// Highest change id so far; the app remembers this to ask "what changed since".
    func latestChangeID() throws -> Int64 {
        try pool.read { try Int64.fetchOne($0, sql: "SELECT MAX(id) FROM change_log") ?? 0 }
    }

    func changes(after id: Int64) throws -> [ChangeEntry] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.changeColumns) FROM change_log WHERE id > ? ORDER BY id", arguments: [id])
                .map(Self.changeEntry)
        }
    }

    func changes(turnID: String) throws -> [ChangeEntry] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.changeColumns) FROM change_log WHERE turn_id = ? AND undone = 0 ORDER BY id", arguments: [turnID])
                .map(Self.changeEntry)
        }
    }

    /// Labels the changes an actor made since `mark` as one turn, so they can be shown and
    /// undone together. The MCP server process cannot know which chat turn it is serving,
    /// so the app stamps the turn afterwards. Returns how many changes the turn made.
    @discardableResult
    func assignTurn(_ turnID: String, actor: String, after mark: Int64) throws -> Int {
        try pool.write { db in
            try db.execute(sql: "UPDATE change_log SET turn_id = ? WHERE actor = ? AND id > ? AND turn_id IS NULL",
                           arguments: [turnID, actor, mark])
            return db.changesCount
        }
    }

    /// Reverts every logged change of one AI turn, newest first. Returns the pages affected.
    @discardableResult
    func undo(turnID: String) throws -> Set<String> {
        let pages = try pool.write { db -> Set<String> in
            let entries = try Row.fetchAll(db, sql: "SELECT \(Self.changeColumns) FROM change_log WHERE turn_id = ? AND undone = 0 ORDER BY id DESC", arguments: [turnID])
                .map(Self.changeEntry)
            var pages = Set<String>()
            for entry in entries {
                try Self.revert(db, entry)
                pages.insert(entry.pageID)
            }
            try db.execute(sql: "UPDATE change_log SET undone = 1 WHERE turn_id = ?", arguments: [turnID])
            for id in pages { try Self.touchPage(db, id) }
            return pages
        }
        ChangeNotifier.post()
        return pages
    }
}

extension Workspace {
    static let changeColumns = "id, entity, entity_id, page_id, before, after, actor, turn_id, at"

    static func changeEntry(_ row: Row) -> ChangeEntry {
        ChangeEntry(id: row[0], entity: row[1], entityID: row[2], pageID: row[3], before: row[4], after: row[5],
                    actor: row[6], turnID: row[7], at: Date(timeIntervalSince1970: row[8]))
    }

    /// Records a change when it came from an AI or MCP client; user edits pass a nil context.
    static func log<T: Encodable>(_ db: Database, entity: String, id: String, pageID: String,
                                  before: T?, after: T?, _ context: ChangeContext?) throws {
        guard let context else { return }
        try db.execute(sql: """
            INSERT INTO change_log (entity, entity_id, page_id, before, after, actor, turn_id, at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [entity, id, pageID, try before.map(encodeJSON), try after.map(encodeJSON),
                             context.actor, context.turnID, ts(Date())])
    }

    static func revert(_ db: Database, _ entry: ChangeEntry) throws {
        switch entry.entity {
        case "block":
            if let before = entry.before {
                let block = try decodeJSON(Block.self, before)
                try db.execute(sql: Block.upsertSQL, arguments: try block.arguments())
            } else {
                try db.execute(sql: "DELETE FROM blocks WHERE id = ?", arguments: [entry.entityID])
            }
        case "page":
            if let before = entry.before {
                let page = try decodeJSON(Page.self, before)
                if page.archivedAt == nil { try restore(db, page.id) }
                try writePage(db, page)
            } else {
                // The page was created by this turn: undo moves it to the Trash, never deletes it.
                try db.execute(sql: "UPDATE pages SET archived_at = ? WHERE id = ? AND archived_at IS NULL",
                               arguments: [ts(Date()), entry.entityID])
            }
        default:
            break
        }
    }

    func notifyIfExternal(_ context: ChangeContext?) {
        if context != nil { ChangeNotifier.post() }
    }
}

/// Cross-process "the workspace changed" ping, carried by Darwin notifications.
/// The payload-free ping is paired with `changes(after:)` to learn what changed.
public enum ChangeNotifier {
    public static let name = "app.flotion.workspace.changed"

    public static func post() {
        notify_post(name)
    }

    /// Calls `handler` on `queue` whenever any process posts a change. Keep the token to cancel.
    public static func observe(on queue: DispatchQueue = .main, _ handler: @escaping @Sendable () -> Void) -> ObservationToken {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, queue) { _ in handler() }
        return ObservationToken(token: token)
    }

    public final class ObservationToken: Sendable {
        let token: Int32
        init(token: Int32) { self.token = token }
        deinit { notify_cancel(token) }
    }
}
