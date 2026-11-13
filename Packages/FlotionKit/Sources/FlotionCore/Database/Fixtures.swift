import Foundation
import GRDB

/// Deterministic workspaces for performance tests and manual stress runs.
public enum Fixtures {
    static let vocabulary: [String] = """
        note page block diagram network handshake latency budget editor cursor sidebar search index query \
        token stream agent model prompt context memory cache thread actor render layout frame scroll glyph \
        paragraph heading bullet quote divider link project roadmap meeting summary decision action owner \
        deadline review design system colour font spacing margin release version migrate schema table column \
        protocol packet server client request response retry timeout queue worker signal metric trace sample \
        garden kettle harbour lantern meadow orchard pebble quartz ribbon saddle thimble umbrella violin walnut
        """.split(separator: " ").map(String.init)

    /// A small linear-congruential generator so fixtures are identical on every run.
    struct Generator {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        mutating func words(_ count: Int) -> String {
            var out = ""
            for i in 0..<count {
                if i > 0 { out += " " }
                out += Fixtures.vocabulary[next() % Fixtures.vocabulary.count]
            }
            return out
        }
    }

    /// Fills `workspace` with `pages` pages of `blocksPerPage` blocks each.
    /// Returns the page ids in creation order.
    @discardableResult
    public static func populate(_ workspace: Workspace, pages: Int, blocksPerPage: Int, seed: UInt64 = 42) throws -> [String] {
        var gen = Generator(state: seed)
        var ids: [String] = []
        ids.reserveCapacity(pages)
        let now = ts(Date())
        try workspace.pool.write { db in
            let insertPage = try db.cachedStatement(sql: "INSERT INTO pages (\(Page.columns)) VALUES (?, NULL, ?, NULL, ?, ?, ?, NULL)")
            let insertBlock = try db.cachedStatement(sql: "INSERT INTO blocks (id, page_id, type, depth, position, plain, text, props, updated_at) VALUES (?, ?, ?, 0, ?, ?, NULL, NULL, ?)")
            for p in 0..<pages {
                let pageID = String(format: "page-%06d", p)
                ids.append(pageID)
                try insertPage.execute(arguments: [pageID, gen.words(3).capitalized, Double(p + 1) * 1024, now, now])
                for b in 0..<blocksPerPage {
                    let type: BlockType = b % 12 == 0 ? .heading2 : b % 5 == 0 ? .bullet : .paragraph
                    let text = gen.words(type == .heading2 ? 4 : 8 + gen.next() % 40)
                    try insertBlock.execute(arguments: [
                        String(format: "b-%06d-%05d", p, b), pageID, type.rawValue, Double(b + 1) * 1024, text, now,
                    ])
                }
            }
        }
        return ids
    }
}
