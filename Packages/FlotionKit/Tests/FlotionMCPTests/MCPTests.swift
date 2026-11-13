import Foundation
import Testing
import FlotionCore
import FlotionMCP
import FlotionTestSupport
import MCP

private func text(_ result: CallTool.Result) -> String {
    result.content.compactMap { content -> String? in
        if case .text(let text, _, _) = content { return text }
        return nil
    }.joined(separator: "\n")
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@Suite struct ToolDispatchTests {
    let ws: Workspace
    let tools: FlotionTools

    init() throws {
        ws = try Workspace.temporary()
        tools = FlotionTools(workspace: ws, actor: "mcp")
    }

    @Test func toolSurfaceIsTheContract() {
        // Changing this list changes what every connected LLM client sees: do it on purpose.
        #expect(FlotionTools.definitions.map(\.name) == [
            "search_pages", "list_pages", "get_page", "create_page", "update_page", "append_blocks",
            "update_block", "delete_block", "archive_page", "create_diagram", "get_diagram", "update_diagram",
        ])
        for tool in FlotionTools.definitions {
            #expect(!(tool.description ?? "").isEmpty, "\(tool.name) needs a description")
            #expect(tool.inputSchema.objectValue?["type"]?.stringValue == "object")
        }
    }

    @Test func createReadEditAndSearchAPage() throws {
        let created = tools.call("create_page", ["title": "Networking", "markdown": "# TCP\n\nThe handshake has three steps.\n\n- SYN\n- ACK"])
        #expect(created.isError == false)
        let pageID = try #require(try object(text(created))["page_id"] as? String)

        let read = text(tools.call("get_page", ["page_id": .string(pageID)]))
        #expect(read.contains("title: Networking"))
        #expect(read.contains("# TCP"))
        #expect(read.contains("- SYN"))
        #expect(read.contains("Block outline"))

        let blocks = try ws.blocks(pageID: pageID)
        #expect(blocks.map(\.type) == [.heading1, .paragraph, .bullet, .bullet])

        let inserted = tools.call("append_blocks", ["page_id": .string(pageID), "markdown": "- SYN-ACK", "after_block_id": .string(blocks[2].id)])
        #expect(inserted.isError == false)
        #expect(try ws.blocks(pageID: pageID).map(\.plainText).suffix(3) == ["SYN", "SYN-ACK", "ACK"])

        let updated = tools.call("update_block", ["block_id": .string(blocks[1].id), "markdown": "The handshake has **three** segments."])
        #expect(updated.isError == false)
        let paragraph = try #require(try ws.block(id: blocks[1].id))
        #expect(paragraph.plainText == "The handshake has three segments.")
        #expect(paragraph.runs.contains { $0.marks.contains(.bold) && $0.text == "three" })

        #expect(tools.call("delete_block", ["block_id": .string(blocks[0].id)]).isError == false)
        #expect(try ws.blocks(pageID: pageID).first?.type == .paragraph)

        let found = text(tools.call("search_pages", ["query": "handshake segm"]))
        #expect(found.contains(pageID))
        #expect(text(tools.call("search_pages", ["query": "zebra"])) == "No pages match.")
    }

    @Test func pagesCanBeListedMovedAndArchived() throws {
        let parent = try ws.createPage(title: "Parent")
        let child = try ws.createPage(title: "Child")

        #expect(tools.call("update_page", ["page_id": .string(child.id), "parent_id": .string(parent.id), "title": "Renamed"]).isError == false)
        let top = text(tools.call("list_pages", [:]))
        #expect(top.contains("\"sub_pages\":1"))
        #expect(!top.contains("Renamed"))
        #expect(text(tools.call("list_pages", ["parent_id": .string(parent.id)])).contains("Renamed"))

        #expect(tools.call("update_page", ["page_id": .string(child.id), "parent_id": ""]).isError == false)
        #expect(try ws.requirePage(id: child.id).parentID == nil, "an empty parent_id moves the page to the top level")

        #expect(tools.call("archive_page", ["page_id": .string(parent.id)]).isError == false)
        #expect(try ws.pages().map(\.id) == [child.id])
        #expect(try ws.archivedPages().map(\.id) == [parent.id])
    }

    @Test func everyWriteIsLoggedWithTheActor() throws {
        let page = try ws.createPage(title: "P")
        let mark = try ws.latestChangeID()
        _ = tools.call("append_blocks", ["page_id": .string(page.id), "markdown": "one\n\ntwo"])
        let changes = try ws.changes(after: mark)
        #expect(changes.count == 2)
        #expect(changes.allSatisfy { $0.actor == "mcp" })
    }

    @Test func errorsComeBackAsToolErrorsNotCrashes() {
        let missingArg = tools.call("get_page", [:])
        #expect(missingArg.isError == true)
        #expect(text(missingArg).contains("page_id"))

        #expect(tools.call("get_page", ["page_id": "nope"]).isError == true)
        #expect(tools.call("update_block", ["block_id": "nope", "markdown": "x"]).isError == true)
        #expect(tools.call("no_such_tool", [:]).isError == true)
    }

    @Test func diagramsCanBeCreatedReadAndRevised() throws {
        let page = try ws.createPage(title: "P")
        let steps: Value = [
            ["title": "SYN", "svg": "<svg viewBox='0 0 100 40'><circle cx='10' cy='20' r='4'/></svg>"],
            ["title": "ACK", "caption": "Connection open", "svg": "<svg viewBox='0 0 100 40'><circle cx='90' cy='20' r='4'/></svg>"],
        ]
        let created = tools.call("create_diagram", ["page_id": .string(page.id), "title": "Handshake", "format": "steps", "steps": steps])
        #expect(created.isError == false, "\(text(created))")
        let blockID = try #require(try object(text(created))["block_id"] as? String)
        #expect(try ws.blocks(pageID: page.id).map(\.type) == [.diagram])

        let read = text(tools.call("get_diagram", ["block_id": .string(blockID)]))
        #expect(read.contains("format: steps"))
        #expect(read.contains("Connection open"))

        let external = tools.call("update_diagram", ["block_id": .string(blockID), "format": "html", "html": "<img src=\"https://example.com/x.png\">"])
        #expect(external.isError == true)
        #expect(text(external).contains("self-contained"))
        #expect(try ws.diagram(forBlock: blockID)?.format == .steps, "a rejected update leaves the diagram untouched")

        let revised = tools.call("update_diagram", ["block_id": .string(blockID), "format": "html", "html": "<div style='color:var(--fl-text)'>hi</div>", "height": 200])
        #expect(revised.isError == false)
        #expect(try ws.diagram(forBlock: blockID)?.height == 200)

        #expect(tools.call("create_diagram", ["page_id": .string(page.id), "title": "x", "format": "steps"]).isError == true)
    }
}

/// These tests run the real binary, so they cover the transport, process start-up and
/// two processes sharing one database.
@Suite struct StdioContractTests {
    @Test func handshakeListAndCallOverStdio() throws {
        let ws = try Workspace.temporary()
        let client = try MCPStdioClient(database: ws.url)
        defer { client.terminate() }

        let info = try client.initialize()
        #expect((info["serverInfo"] as? [String: Any])?["name"] as? String == "flotion")
        #expect((info["instructions"] as? String)?.contains("Flotion") == true)

        let tools = try client.listTools()
        #expect(tools.count == FlotionTools.definitions.count)
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })

        let created = try client.callTool("create_page", ["title": "From another process", "markdown": "hello"])
        #expect(!created.isError)
        // The page written by the server process is visible to this process straight away.
        #expect(try ws.pages().map(\.title) == ["From another process"])

        // And the other direction: a page written here is readable through the server.
        let local = try ws.createPage(title: "Written by the app", blocks: [Block(.paragraph, "local text")])
        let read = try client.callTool("get_page", ["page_id": local.id])
        #expect(read.text.contains("local text"))

        let bad = try client.callTool("get_page", ["page_id": "nope"])
        #expect(bad.isError)
    }

    @Test func appAndServerWriteTheSameDatabaseConcurrently() async throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "Shared")
        let client = try MCPStdioClient(database: ws.url)
        defer { client.terminate() }
        try client.initialize()

        async let server: Void = Task.detached {
            for i in 0..<40 {
                let r = try client.callTool("append_blocks", ["page_id": page.id, "markdown": "server \(i)"])
                #expect(!r.isError, "\(r.text)")
            }
        }.value
        async let app: Void = Task.detached {
            for i in 0..<200 {
                try ws.saveEditorChanges(pageID: page.id, upserts: [Block(id: "app-\(i)", type: .paragraph, position: -Double(i + 1), runs: [TextRun("app \(i)")])], deletes: [])
            }
        }.value
        _ = try await (server, app)

        let blocks = try ws.blocks(pageID: page.id)
        #expect(blocks.count == 240)
        #expect(blocks.filter { $0.plainText.hasPrefix("server") }.count == 40)
    }

    @Test func serverWritesPingTheAppProcess() async throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "Watched")
        let mark = try ws.latestChangeID()
        let client = try MCPStdioClient(database: ws.url, actor: "chat:test")
        defer { client.terminate() }
        try client.initialize()

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let token = ChangeNotifier.observe(on: .global()) { continuation.yield() }
        defer { _ = token }

        _ = try client.callTool("append_blocks", ["page_id": page.id, "markdown": "ping"])

        let pinged = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(pinged, "the app must hear about writes made by the server process")
        let changes = try ws.changes(after: mark)
        #expect(changes.map(\.actor) == ["chat:test"])
        #expect(changes.map(\.pageID) == [page.id])
    }
}
