import Foundation
import Testing
import FlotionCore

// Performance budgets for the data layer. Run in release: `swift test -c release --filter FlotionPerfTests`.
// The plan's budgets cover the whole user-visible operation; the figures asserted here are the
// share the data layer is allowed, leaving the rest for layout and drawing.

struct Timing: CustomStringConvertible {
    var median: Double
    var p95: Double
    var description: String { String(format: "median %.2f ms, p95 %.2f ms", median, p95) }
}

@discardableResult
func measure(_ name: String, runs: Int = 30, _ body: (Int) throws -> Void) rethrows -> Timing {
    var samples: [Double] = []
    let clock = ContinuousClock()
    try body(-1) // warm-up, not counted
    for i in 0..<runs {
        let start = clock.now
        try body(i)
        let d = clock.now - start
        samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
    samples.sort()
    let timing = Timing(median: samples[samples.count / 2], p95: samples[Int(Double(samples.count - 1) * 0.95)])
    print("PERF \(name): \(timing)")
    return timing
}

/// Fixtures are slow to build, so they are created once and cached under `.build/fixtures`.
enum PerfFixtures {
    static let directory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/fixtures", isDirectory: true)
    }()

    static func workspace(_ name: String, pages: Int, blocksPerPage: Int) throws -> Workspace {
        let url = directory.appendingPathComponent("\(name)-v1.sqlite")
        if FileManager.default.fileExists(atPath: url.path) {
            return try Workspace(url: url)
        }
        let building = directory.appendingPathComponent("\(name)-building-\(newID()).sqlite")
        let ws = try Workspace(url: building)
        try Fixtures.populate(ws, pages: pages, blocksPerPage: blocksPerPage)
        _ = try ws.pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        try ws.pool.close()
        try FileManager.default.moveItem(at: building, to: url)
        return try Workspace(url: url)
    }

    /// 10,000 pages × 50 blocks: the search and save fixture.
    static let large = Result { try workspace("large-10k", pages: 10_000, blocksPerPage: 50) }
    /// Two long pages: 500 and 5,000 blocks.
    static let longPages = Result { () -> (Workspace, String, String) in
        let ws = try Workspace.temporary()
        let a = try Fixtures.populate(ws, pages: 1, blocksPerPage: 500, seed: 1)[0]
        let page = try ws.createPage(title: "Five thousand")
        let drafts = try ws.blocks(pageID: a)
        for _ in 0..<10 {
            try ws.insertBlocks(pageID: page.id, drafts.map { Block(type: $0.type, runs: $0.runs) })
        }
        return (ws, a, page.id)
    }
}

@Suite(.serialized) struct DataLayerBudgets {
    @Test func loadPageOf500Blocks() throws {
        let (ws, page500, _) = try PerfFixtures.longPages.get()
        var count = 0
        let t = try measure("load 500-block page") { _ in count = try ws.blocks(pageID: page500).count }
        #expect(count == 500)
        #expect(t.p95 < 15, "data-layer share of the 50 ms page-open budget")
    }

    @Test func loadPageOf5000Blocks() throws {
        let (ws, _, page5000) = try PerfFixtures.longPages.get()
        var count = 0
        let t = try measure("load 5,000-block page") { _ in count = try ws.blocks(pageID: page5000).count }
        #expect(count == 5000)
        #expect(t.p95 < 60, "data-layer share of the 150 ms page-open budget")
    }

    @Test func searchAcrossTenThousandPages() throws {
        let ws = try PerfFixtures.large.get()
        // Typed incrementally, the way quick find issues queries.
        let queries = ["h", "ha", "handsh", "handshake", "handshake lat", "network handshake latency",
                       "roadmap", "roadmap dec", "walnut violin", "quartz", "meeting summary action", "zzzz"]
        let t = try measure("search 10,000 pages / 500,000 blocks", runs: 60) { i in
            _ = try ws.search(queries[abs(i) % queries.count])
        }
        #expect(t.p95 < 30)
    }

    @Test func editorSaveOnLargeWorkspace() throws {
        let ws = try PerfFixtures.large.get()
        let pageID = "page-005000"
        var block = try #require(try ws.blocks(pageID: pageID).first)
        let t = try measure("save one edited block", runs: 60) { i in
            block.runs = [TextRun("edited \(i) kettle harbour lantern")]
            try ws.saveEditorChanges(pageID: pageID, upserts: [block], deletes: [])
        }
        #expect(t.p95 < 5)
    }

    @Test func markdownExportAndImportOf500Blocks() throws {
        let (ws, page500, _) = try PerfFixtures.longPages.get()
        let blocks = try ws.blocks(pageID: page500)
        var markdown = ""
        let render = measure("render 500 blocks to Markdown") { _ in markdown = MarkdownCodec.render(blocks) }
        let parse = measure("parse 500 blocks from Markdown") { _ in _ = MarkdownCodec.parse(markdown) }
        #expect(render.p95 < 10)
        #expect(parse.p95 < 20)
    }

    @Test func openWorkspaceColdOnLargeDatabase() throws {
        let url = try PerfFixtures.large.get().url
        var pageCount = 0
        let t = try measure("open 10,000-page workspace + list pages", runs: 10) { _ in
            let ws = try Workspace(url: url)
            pageCount = try ws.pages().count
            try ws.pool.close()
        }
        #expect(pageCount == 10_000)
        #expect(t.p95 < 60, "data-layer share of the 400 ms launch budget")
    }
}

import FlotionTestSupport

/// Budgets for the real MCP server process (release build).
@Suite(.serialized) struct MCPServerBudgets {
    @Test func coldStartToFirstResponse() throws {
        let (ws, _, _) = try PerfFixtures.longPages.get()
        let t = try measure("flotion-mcp cold start to initialize response", runs: 12) { _ in
            let client = try MCPStdioClient(database: ws.url)
            try client.initialize()
            client.terminate()
        }
        #expect(t.p95 < 100)
    }

    @Test func toolCallsOnAWarmServer() throws {
        let (ws, page500, _) = try PerfFixtures.longPages.get()
        let client = try MCPStdioClient(database: ws.url)
        defer { client.terminate() }
        try client.initialize()

        let read = try measure("tools/call get_page (500 blocks)", runs: 40) { _ in
            _ = try client.callTool("get_page", ["page_id": page500])
        }
        let write = try measure("tools/call append_blocks", runs: 40) { i in
            _ = try client.callTool("append_blocks", ["page_id": page500, "markdown": "budget \(i)"])
        }
        #expect(read.p95 < 20)
        #expect(write.p95 < 20)

        let large = try PerfFixtures.large.get()
        let searchClient = try MCPStdioClient(database: large.url)
        defer { searchClient.terminate() }
        try searchClient.initialize()
        let search = try measure("tools/call search_pages (10,000 pages)", runs: 40) { _ in
            _ = try searchClient.callTool("search_pages", ["query": "handshake latency"])
        }
        #expect(search.p95 < 30)
    }
}
