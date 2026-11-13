import Foundation
import GRDB

/// One Flotion workspace: a single SQLite file in WAL mode, shared by the app and the MCP server.
/// All methods are synchronous and thread-safe; callers keep them off the main thread.
public final class Workspace: Sendable {
    public let pool: DatabasePool
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        pool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    /// A throwaway workspace in the temporary directory, for tests and tools.
    public static func temporary() throws -> Workspace {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flotion-\(newID())", isDirectory: true)
        return try Workspace(url: dir.appendingPathComponent("flotion.sqlite"))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE pages (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                parent_id TEXT,
                title TEXT NOT NULL DEFAULT '',
                icon TEXT,
                position REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                archived_at REAL
            );
            CREATE INDEX pages_parent ON pages(parent_id, position);

            -- `text` holds JSON runs only when a block has formatting; plain blocks keep
            -- their content in `plain` alone, so loading a page rarely touches a JSON decoder.
            CREATE TABLE blocks (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                page_id TEXT NOT NULL,
                type TEXT NOT NULL,
                depth INTEGER NOT NULL DEFAULT 0,
                position REAL NOT NULL,
                plain TEXT NOT NULL DEFAULT '',
                text TEXT,
                props TEXT,
                updated_at REAL NOT NULL
            );
            CREATE INDEX blocks_page ON blocks(page_id, position);

            CREATE TABLE diagrams (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                format TEXT NOT NULL,
                source TEXT NOT NULL,
                height REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE change_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                entity TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                page_id TEXT NOT NULL,
                before TEXT,
                after TEXT,
                actor TEXT NOT NULL,
                turn_id TEXT,
                at REAL NOT NULL,
                undone INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX change_log_turn ON change_log(turn_id);

            CREATE VIRTUAL TABLE blocks_fts USING fts5(
                plain, content='blocks', content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2', prefix='2 3');
            CREATE TRIGGER blocks_fts_ai AFTER INSERT ON blocks BEGIN
                INSERT INTO blocks_fts(rowid, plain) VALUES (new.rowid, new.plain);
            END;
            CREATE TRIGGER blocks_fts_ad AFTER DELETE ON blocks BEGIN
                INSERT INTO blocks_fts(blocks_fts, rowid, plain) VALUES ('delete', old.rowid, old.plain);
            END;
            CREATE TRIGGER blocks_fts_au AFTER UPDATE OF plain ON blocks BEGIN
                INSERT INTO blocks_fts(blocks_fts, rowid, plain) VALUES ('delete', old.rowid, old.plain);
                INSERT INTO blocks_fts(rowid, plain) VALUES (new.rowid, new.plain);
            END;

            CREATE VIRTUAL TABLE pages_fts USING fts5(
                title, content='pages', content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2', prefix='2 3');
            CREATE TRIGGER pages_fts_ai AFTER INSERT ON pages BEGIN
                INSERT INTO pages_fts(rowid, title) VALUES (new.rowid, new.title);
            END;
            CREATE TRIGGER pages_fts_ad AFTER DELETE ON pages BEGIN
                INSERT INTO pages_fts(pages_fts, rowid, title) VALUES ('delete', old.rowid, old.title);
            END;
            CREATE TRIGGER pages_fts_au AFTER UPDATE OF title ON pages BEGIN
                INSERT INTO pages_fts(pages_fts, rowid, title) VALUES ('delete', old.rowid, old.title);
                INSERT INTO pages_fts(rowid, title) VALUES (new.rowid, new.title);
            END;
            """)
        }
        return m
    }
}

// MARK: - Row mapping shared by the stores

let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
}()

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try jsonEncoder.encode(value), as: UTF8.self)
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ string: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(string.utf8))
}

func ts(_ date: Date) -> Double { date.timeIntervalSince1970 }

extension Page {
    static let columns = "id, parent_id, title, icon, position, created_at, updated_at, archived_at"

    init(row: Row) {
        self.init(
            id: row[0], parentID: row[1], title: row[2], icon: row[3], position: row[4],
            createdAt: Date(timeIntervalSince1970: row[5]),
            updatedAt: Date(timeIntervalSince1970: row[6]),
            archivedAt: (row[7] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
}

extension Block {
    static let columns = "id, page_id, type, depth, position, plain, text, props, updated_at"

    init(row: Row) throws {
        let plain: String = row[5]
        let runsJSON: String? = row[6]
        let propsJSON: String? = row[7]
        let runs: [TextRun]
        if let runsJSON {
            runs = try decodeJSON([TextRun].self, runsJSON)
        } else {
            runs = plain.isEmpty ? [] : [TextRun(plain)]
        }
        self.init(
            id: row[0], pageID: row[1],
            type: BlockType(rawValue: row[2]) ?? .paragraph,
            depth: row[3], position: row[4], runs: runs,
            props: try propsJSON.map { try decodeJSON(BlockProps.self, $0) } ?? BlockProps(),
            updatedAt: Date(timeIntervalSince1970: row[8]))
    }

    /// Arguments for an upsert, in `columns` order.
    func arguments() throws -> StatementArguments {
        let runsJSON: String? = runs.isPlain && runs.count <= 1 ? nil : try encodeJSON(runs)
        let propsJSON: String? = props.isEmpty ? nil : try encodeJSON(props)
        return [id, pageID, type.rawValue, depth, position, plainText, runsJSON, propsJSON, ts(updatedAt)]
    }

    static let upsertSQL = """
        INSERT INTO blocks (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET page_id = excluded.page_id, type = excluded.type, depth = excluded.depth,
            position = excluded.position, plain = excluded.plain, text = excluded.text,
            props = excluded.props, updated_at = excluded.updated_at
        """
}
