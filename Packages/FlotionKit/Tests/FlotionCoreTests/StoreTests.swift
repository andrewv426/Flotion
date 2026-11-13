import Foundation
import Testing
import FlotionCore

@Suite struct PageStoreTests {
    @Test func createNestAndList() throws {
        let ws = try Workspace.temporary()
        let a = try ws.createPage(title: "Alpha")
        let b = try ws.createPage(title: "Beta")
        let child = try ws.createPage(title: "Child", parentID: a.id)

        #expect(try ws.children(of: nil).map(\.title) == ["Alpha", "Beta"])
        #expect(try ws.children(of: a.id).map(\.id) == [child.id])
        #expect(try ws.pages().count == 3)
        #expect(b.position > a.position)
    }

    @Test func renameAndClearIcon() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "Draft", icon: "📝")
        let renamed = try ws.updatePage(id: page.id, title: "Final")
        #expect(renamed.title == "Final")
        #expect(renamed.icon == "📝")
        let cleared = try ws.updatePage(id: page.id, icon: .some(nil))
        #expect(cleared.icon == nil)
    }

    @Test func moveRejectsCycles() throws {
        let ws = try Workspace.temporary()
        let parent = try ws.createPage(title: "Parent")
        let child = try ws.createPage(title: "Child", parentID: parent.id)
        #expect(throws: FlotionError.self) {
            try ws.updatePage(id: parent.id, parentID: .some(child.id))
        }
        #expect(throws: FlotionError.self) {
            try ws.movePage(id: parent.id, toParent: child.id, after: nil)
        }
    }

    @Test func movePageReordersSiblings() throws {
        let ws = try Workspace.temporary()
        let a = try ws.createPage(title: "A")
        let b = try ws.createPage(title: "B")
        let c = try ws.createPage(title: "C")
        try ws.movePage(id: c.id, toParent: nil, after: a.id)
        #expect(try ws.children(of: nil).map(\.title) == ["A", "C", "B"])
        try ws.movePage(id: b.id, toParent: nil, after: nil)
        #expect(try ws.children(of: nil).map(\.title) == ["B", "A", "C"])
    }

    @Test func archiveTakesSubtreeAndRestoreBringsItBack() throws {
        let ws = try Workspace.temporary()
        let parent = try ws.createPage(title: "Parent")
        let child = try ws.createPage(title: "Child", parentID: parent.id)
        _ = try ws.createPage(title: "Other")

        try ws.archivePage(id: parent.id)
        #expect(try ws.pages().map(\.title) == ["Other"])
        #expect(try ws.archivedPages().map(\.id) == [parent.id])

        try ws.restorePage(id: parent.id)
        #expect(try ws.pages().count == 3)
        #expect(try ws.children(of: parent.id).map(\.id) == [child.id])
    }

    @Test func missingPageThrowsNotFound() throws {
        let ws = try Workspace.temporary()
        #expect(throws: FlotionError.notFound("page nope")) { try ws.requirePage(id: "nope") }
        #expect(throws: FlotionError.self) { try ws.createPage(title: "x", parentID: "nope") }
    }
}

@Suite struct BlockStoreTests {
    @Test func insertAtEndStartAndAfterKeepsOrder() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        let first = try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "one"), Block(.paragraph, "three")])
        try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "two")], at: .after(first[0].id))
        try ws.insertBlocks(pageID: page.id, [Block(.heading1, "zero")], at: .start)
        try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "four")])
        #expect(try ws.blocks(pageID: page.id).map(\.plainText) == ["zero", "one", "two", "three", "four"])
    }

    @Test func repeatedInsertionAtOneSpotRenumbers() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        let anchor = try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "a"), Block(.paragraph, "z")])[0]
        for i in 0..<80 {
            try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "n\(i)")], at: .after(anchor.id))
        }
        let blocks = try ws.blocks(pageID: page.id)
        #expect(blocks.count == 82)
        #expect(blocks.first?.plainText == "a")
        #expect(blocks[1].plainText == "n79")
        #expect(blocks.last?.plainText == "z")
        #expect(Set(blocks.map(\.position)).count == 82)
    }

    @Test func formattedRunsAndPropsRoundTrip() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        let runs = [TextRun("plain "), TextRun("bold", marks: .bold), TextRun(" link", marks: [.italic], link: "https://example.com")]
        let drafts = [
            Block(type: .paragraph, runs: runs),
            Block(type: .todo, runs: [TextRun("task")], props: BlockProps(checked: true)),
            Block(type: .code, runs: [TextRun("let x = 1")], props: BlockProps(language: "swift")),
        ]
        try ws.insertBlocks(pageID: page.id, drafts)
        let loaded = try ws.blocks(pageID: page.id)
        #expect(loaded[0].runs == runs)
        #expect(loaded[1].props.checked == true)
        #expect(loaded[2].props.language == "swift")
    }

    @Test func editorSaveUpsertsAndDeletes() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        var blocks = try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "keep"), Block(.paragraph, "drop")])
        blocks[0].runs = [TextRun("kept and edited")]
        let added = Block(id: newID(), type: .bullet, position: blocks[0].position + 1, runs: [TextRun("new")])
        try ws.saveEditorChanges(pageID: page.id, upserts: [blocks[0], added], deletes: [blocks[1].id])
        #expect(try ws.blocks(pageID: page.id).map(\.plainText) == ["kept and edited", "new"])
        #expect(try ws.latestChangeID() == 0, "user edits are not logged")
    }

    @Test func replaceBlockKeepsIdentityAndInsertsTheRest() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        let blocks = try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "old"), Block(.paragraph, "tail")])
        let out = try ws.replaceBlock(id: blocks[0].id, with: [Block(.heading2, "new"), Block(.bullet, "extra")])
        #expect(out[0].id == blocks[0].id)
        let loaded = try ws.blocks(pageID: page.id)
        #expect(loaded.map(\.plainText) == ["new", "extra", "tail"])
        #expect(loaded[0].type == .heading2)
    }
}

@Suite struct ChangeLogTests {
    let ai = ChangeContext(actor: "mcp", turnID: "turn-1")

    @Test func undoRevertsInsertUpdateAndDeleteOfOneTurn() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        let original = try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "one"), Block(.paragraph, "two"), Block(.paragraph, "three")])

        try ws.updateBlock(id: original[0].id, context: ai) { $0.runs = [TextRun("ONE")] }
        try ws.deleteBlock(id: original[1].id, context: ai)
        try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "four")], context: ai)
        #expect(try ws.blocks(pageID: page.id).map(\.plainText) == ["ONE", "three", "four"])
        #expect(try ws.changes(turnID: "turn-1").count == 3)

        let affected = try ws.undo(turnID: "turn-1")
        #expect(affected == [page.id])
        let restored = try ws.blocks(pageID: page.id)
        #expect(restored.map(\.plainText) == ["one", "two", "three"])
        #expect(restored.map(\.id) == original.map(\.id))
        #expect(try ws.changes(turnID: "turn-1").isEmpty, "undone changes are not offered again")
    }

    @Test func undoLeavesOtherTurnsAlone() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "first turn")], context: ChangeContext(actor: "mcp", turnID: "t1"))
        try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "second turn")], context: ChangeContext(actor: "mcp", turnID: "t2"))
        try ws.undo(turnID: "t2")
        #expect(try ws.blocks(pageID: page.id).map(\.plainText) == ["first turn"])
    }

    @Test func undoOfPageCreationAndArchive() throws {
        let ws = try Workspace.temporary()
        let created = try ws.createPage(title: "By AI", context: ai)
        try ws.undo(turnID: "turn-1")
        #expect(try ws.pages().isEmpty)
        #expect(try ws.archivedPages().map(\.id) == [created.id], "undoing a creation trashes, never deletes")

        let keep = try ws.createPage(title: "Keep")
        try ws.archivePage(id: keep.id, context: ChangeContext(actor: "mcp", turnID: "turn-2"))
        try ws.undo(turnID: "turn-2")
        #expect(try ws.pages().map(\.id) == [keep.id])
    }

    @Test func changesAfterReportsWhatAnotherProcessWrote() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        let mark = try ws.latestChangeID()
        try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "x")], context: ai)
        let changes = try ws.changes(after: mark)
        #expect(changes.count == 1)
        #expect(changes[0].pageID == page.id)
        #expect(changes[0].actor == "mcp")
    }
}

@Suite struct SearchTests {
    @Test func findsTitlesAndBodiesWithPrefixOnLastWord() throws {
        let ws = try Workspace.temporary()
        let net = try ws.createPage(title: "Networking notes")
        try ws.insertBlocks(pageID: net.id, [Block(.paragraph, "The TCP handshake uses three segments: SYN, SYN-ACK, ACK.")])
        let cook = try ws.createPage(title: "Recipes")
        try ws.insertBlocks(pageID: cook.id, [Block(.paragraph, "Shake the pan, then add the handful of basil.")])

        let byTitle = try ws.search("network")
        #expect(byTitle.first?.pageID == net.id)

        let byBody = try ws.search("tcp handsh")
        #expect(byBody.map(\.pageID) == [net.id])
        #expect(byBody[0].snippet.contains("handshake"))
        #expect(byBody[0].blockID != nil)

        #expect(try ws.search("basil").map(\.pageID) == [cook.id])
        #expect(try ws.search("   ").isEmpty)
        #expect(try ws.search("\"unbalanced AND (").isEmpty, "query syntax in user text must not throw")
    }

    @Test func staysInSyncWithEditsAndTrash() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        let block = try ws.insertBlocks(pageID: page.id, [Block(.paragraph, "walrus")])[0]
        #expect(try ws.search("walrus").count == 1)

        try ws.updateBlock(id: block.id) { $0.runs = [TextRun("penguin")] }
        #expect(try ws.search("walrus").isEmpty)
        #expect(try ws.search("penguin").count == 1)

        try ws.archivePage(id: page.id)
        #expect(try ws.search("penguin").isEmpty)
    }

    @Test func accentsAreFolded() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "Café menu")
        _ = page
        #expect(try ws.search("cafe").count == 1)
    }
}

@Suite struct DiagramTests {
    @Test func createStoresDiagramAndInsertsBlock() throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "P")
        let steps = #"[{"title":"SYN","svg":"<svg viewBox='0 0 10 10'></svg>"},{"caption":"done","html":"<p>ACK</p>"}]"#
        let (diagram, block) = try ws.createDiagram(pageID: page.id, title: "Handshake", format: .steps, source: steps, height: 5000)
        #expect(diagram.height == 1200, "height is clamped")
        #expect(block.type == .diagram)
        #expect(try ws.diagram(forBlock: block.id)?.title == "Handshake")
    }

    @Test(arguments: [
        #"<img src="https://example.com/a.png">"#,
        #"<script src='//cdn.example.com/x.js'></script>"#,
        "<style>@import 'theme.css';</style>",
        "<div style=\"background:url(https://example.com/bg.png)\"></div>",
    ])
    func rejectsExternalReferences(html: String) {
        #expect(throws: FlotionError.self) { try DiagramValidator.validate(format: .html, source: html) }
    }

    @Test func acceptsSelfContainedHTMLThatMerelyMentionsURLs() throws {
        let html = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40"><text x="4" y="20">GET https://example.com</text></svg>
            <script>const label = "fetch('/api')"; document.title = label;</script>
            """
        try DiagramValidator.validate(format: .html, source: html)
    }

    @Test func rejectsMalformedSteps() {
        #expect(throws: FlotionError.self) { try DiagramValidator.validate(format: .steps, source: "[]") }
        #expect(throws: FlotionError.self) { try DiagramValidator.validate(format: .steps, source: #"[{"title":"no body"}]"#) }
        #expect(throws: FlotionError.self) { try DiagramValidator.validate(format: .steps, source: #"[{"svg":"<svg/>","html":"<p/>"}]"#) }
        #expect(throws: FlotionError.self) { try DiagramValidator.validate(format: .steps, source: "not json") }
        #expect(throws: FlotionError.self) {
            try DiagramValidator.validate(format: .html, source: String(repeating: "x", count: DiagramValidator.maxBytes + 1))
        }
    }

    @Test func templateLocksDownEveryDocumentAndBuildsTheSlideshow() {
        let steps = #"[{"title":"A <b>","caption":"x & y","svg":"<svg id='one'/>"},{"html":"<p id='two'>hi</p>"}]"#
        let deck = DiagramTemplate.document(for: Diagram(title: "t", format: .steps, source: steps))
        #expect(deck.contains("Content-Security-Policy"))
        #expect(deck.contains("default-src 'none'"))
        #expect(deck.components(separatedBy: "<section class=\"step").count - 1 == 2)
        #expect(deck.contains("A &lt;b&gt;") && deck.contains("x &amp; y"), "titles and captions are escaped")
        #expect(deck.contains("<svg id='one'/>") && deck.contains("--fl-accent"))

        let fragment = DiagramTemplate.document(for: Diagram(title: "t", format: .html, source: "<div>hi</div>"))
        #expect(fragment.contains("Content-Security-Policy") && fragment.contains("<body><div>hi</div></body>"))

        let full = DiagramTemplate.document(for: Diagram(title: "t", format: .html, source: "<html><head><title>x</title></head><body>b</body></html>"))
        let policy = try! #require(full.range(of: "Content-Security-Policy"))
        let title = try! #require(full.range(of: "<title>"))
        #expect(policy.lowerBound < title.lowerBound, "the policy is placed before anything the document brings")
    }
}
