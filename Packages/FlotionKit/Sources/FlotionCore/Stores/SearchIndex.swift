import Foundation
import GRDB

public extension Workspace {
    /// Full-text search over page titles and block text. Title matches come first.
    /// The last word is matched as a prefix so results update while typing.
    func search(_ query: String, limit: Int = 20) throws -> [SearchHit] {
        let words = Self.searchWords(query)
        guard let match = Self.ftsQuery(words) else { return [] }
        return try pool.read { db in
            var hits: [SearchHit] = []
            var indexByPage: [String: Int] = [:]

            let titles = try Row.fetchAll(db, sql: """
                SELECT p.id, p.title FROM pages_fts
                JOIN pages p ON p.rowid = pages_fts.rowid
                WHERE pages_fts MATCH ? AND p.archived_at IS NULL
                ORDER BY rank LIMIT ?
                """, arguments: [match, limit])
            for row in titles {
                let id: String = row[0]
                indexByPage[id] = hits.count
                hits.append(SearchHit(pageID: id, pageTitle: row[1], blockID: nil, snippet: ""))
            }

            // Rank only a bounded candidate set: ordering every match of a common word
            // by bm25 is what makes full-text queries slow on large workspaces.
            let bodies = try Row.fetchAll(db, sql: """
                SELECT b.id, b.page_id, p.title, b.plain
                FROM (SELECT rowid, rank FROM blocks_fts WHERE blocks_fts MATCH ? LIMIT 500) m
                JOIN blocks b ON b.rowid = m.rowid
                JOIN pages p ON p.id = b.page_id
                WHERE p.archived_at IS NULL
                ORDER BY m.rank LIMIT ?
                """, arguments: [match, limit * 3])
            for row in bodies {
                let pageID: String = row[1]
                let snippet = Self.snippet(of: row[3], around: words)
                if let i = indexByPage[pageID] {
                    if hits[i].blockID == nil {
                        hits[i].blockID = row[0]
                        hits[i].snippet = snippet
                    }
                } else if hits.count < limit {
                    indexByPage[pageID] = hits.count
                    hits.append(SearchHit(pageID: pageID, pageTitle: row[2], blockID: row[0], snippet: snippet))
                }
            }
            return hits
        }
    }

    static func searchWords(_ raw: String) -> [String] {
        raw.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// A safe FTS5 expression: each word quoted, the last one a prefix match.
    static func ftsQuery(_ words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, word in
            i == words.count - 1 ? "\"\(word)\"*" : "\"\(word)\""
        }.joined(separator: " ")
    }

    /// About 120 characters of `text` centred on the first matching word.
    static func snippet(of text: String, around words: [String], width: Int = 120) -> String {
        guard text.count > width else { return text }
        var start = text.startIndex
        for word in words {
            if let r = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                start = text.index(r.lowerBound, offsetBy: -min(width / 3, text.distance(from: text.startIndex, to: r.lowerBound)))
                break
            }
        }
        let end = text.index(start, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}
