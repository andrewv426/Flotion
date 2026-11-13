import Foundation
import Testing
import FlotionCore
import FlotionEditor

@MainActor
private func editor(_ blocks: [Block]) -> EditorState {
    var position = 0.0
    return EditorState(pageID: "p", blocks: blocks.map { b in
        var b = b
        position += 1024
        b.position = position
        b.pageID = "p"
        return b
    })
}

@MainActor
private func texts(_ e: EditorState) -> [String] { e.blocks.map(\.plainText) }

@MainActor @Suite struct EditorStateTests {
    @Test func emptyPageStartsWithOneParagraphThatGetsSaved() {
        let e = EditorState(pageID: "p", blocks: [])
        #expect(e.blocks.map(\.type) == [.paragraph])
        #expect(e.takePendingChanges().upserts.count == 1)
        #expect(!e.hasPendingChanges)
    }

    @Test func returnSplitsTextAndMovesCaretToTheNewBlock() {
        let e = editor([Block(.paragraph, "HelloWorld")])
        e.split(e.blocks[0].id, at: 5)
        #expect(texts(e) == ["Hello", "World"])
        #expect(e.focus == Focus(blockID: e.blocks[1].id, offset: 0))
        #expect(e.blocks[1].position > e.blocks[0].position)
    }

    @Test func returnKeepsFormattingOnBothSides() {
        let runs = [TextRun("ab"), TextRun("cdef", marks: .bold)]
        let e = editor([Block(type: .paragraph, runs: runs)])
        e.split(e.blocks[0].id, at: 4)
        #expect(e.blocks[0].runs == [TextRun("ab"), TextRun("cd", marks: .bold)])
        #expect(e.blocks[1].runs == [TextRun("ef", marks: .bold)])
    }

    @Test func returnContinuesListsButNotHeadings() {
        let e = editor([Block(.bullet, "item"), Block(.heading1, "Title"), Block(.todo, "task", props: BlockProps(checked: true))])
        e.split(e.blocks[0].id, at: 4)
        #expect(e.blocks[1].type == .bullet)
        e.split(e.blocks[2].id, at: 5)
        #expect(e.blocks[3].type == .paragraph)
        e.split(e.blocks[4].id, at: 4)
        #expect(e.blocks[5].type == .todo)
        #expect(e.blocks[5].props.checked == false, "a new to-do starts unchecked")
    }

    @Test func returnOnEmptyListItemLeavesTheList() {
        let e = editor([Block(.bullet, "item"), Block(.bullet, "", depth: 1)])
        let id = e.blocks[1].id
        e.split(id, at: 0)
        #expect(e.blocks.count == 2)
        #expect(e.blocks[1].depth == 0, "first Return outdents")
        e.split(id, at: 0)
        #expect(e.blocks[1].type == .paragraph, "second Return ends the list")
    }

    @Test func backspaceAtStartFirstResetsTypeThenMerges() {
        let e = editor([Block(.paragraph, "one"), Block(.heading2, "two")])
        let id = e.blocks[1].id
        e.deleteBackwardAtStart(id)
        #expect(e.blocks[1].type == .paragraph)
        #expect(e.blocks.count == 2)
        e.deleteBackwardAtStart(id)
        #expect(texts(e) == ["onetwo"])
        #expect(e.focus == Focus(blockID: e.blocks[0].id, offset: 3), "caret sits at the join")
    }

    @Test func backspaceIntoADividerRemovesTheDivider() {
        let e = editor([Block(type: .divider), Block(.paragraph, "keep")])
        e.deleteBackwardAtStart(e.blocks[1].id)
        #expect(e.blocks.map(\.type) == [.paragraph])
        #expect(texts(e) == ["keep"])
    }

    @Test func indentIsLimitedToOneLevelBelowThePreviousBlock() {
        let e = editor([Block(.bullet, "a"), Block(.bullet, "b")])
        let b = e.blocks[1].id
        e.indent(e.blocks[0].id)
        #expect(e.blocks[0].depth == 0, "the first block cannot be indented")
        e.indent(b); e.indent(b)
        #expect(e.blocks[1].depth == 1)
        e.outdent(b); e.outdent(b)
        #expect(e.blocks[1].depth == 0)
    }

    @Test(arguments: [
        ("# Title", BlockType.heading1, "Title"), ("## Sub", .heading2, "Sub"), ("### Small", .heading3, "Small"),
        ("- item", .bullet, "item"), ("* item", .bullet, "item"), ("1. first", .numbered, "first"),
        ("[] task", .todo, "task"), ("> quote", .quote, "quote"), ("```", .code, ""),
    ])
    func markdownShortcutsConvertParagraphs(typed: String, type: BlockType, remaining: String) {
        let e = editor([Block(.paragraph, "")])
        let converted = e.setRuns([TextRun(typed)], for: e.blocks[0].id, caret: typed.utf16.count)
        #expect(converted)
        #expect(e.blocks[0].type == type)
        #expect(e.blocks[0].plainText == remaining)
    }

    @Test func threeDashesBecomeADividerFollowedByAParagraph() {
        let e = editor([Block(.paragraph, "")])
        e.setRuns([TextRun("---")], for: e.blocks[0].id, caret: 3)
        #expect(e.blocks.map(\.type) == [.divider, .paragraph])
        #expect(e.focus?.blockID == e.blocks[1].id)
    }

    @Test func shortcutsDoNotFireInsideOtherBlockTypes() {
        let e = editor([Block(.heading1, "")])
        #expect(!e.setRuns([TextRun("- x")], for: e.blocks[0].id, caret: 3))
        #expect(e.blocks[0].type == .heading1)
    }

    @Test func numberedListsCountPerRunAndDepth() {
        let e = editor([
            Block(.numbered, "a"), Block(.numbered, "b"), Block(.numbered, "b1", depth: 1), Block(.numbered, "b2", depth: 1),
            Block(.numbered, "c"), Block(.paragraph, "break"), Block(.numbered, "restart"),
        ])
        #expect((0..<7).map { e.blocks[$0].type == .numbered ? e.listNumber(at: $0) : 0 } == [1, 2, 1, 2, 3, 0, 1])
    }

    @Test func moveReordersAndKeepsPositionsSorted() {
        let e = editor([Block(.paragraph, "a"), Block(.paragraph, "b"), Block(.paragraph, "c"), Block(.paragraph, "d")])
        e.move(from: 3, to: 1)
        #expect(texts(e) == ["a", "d", "b", "c"])
        e.move(from: 0, to: 4)
        #expect(texts(e) == ["d", "b", "c", "a"])
        #expect(e.blocks.map(\.position) == e.blocks.map(\.position).sorted())
        #expect(Set(e.blocks.map(\.position)).count == 4)
    }

    @Test func undoAndRedoRestoreContentFocusAndPendingSaves() {
        let e = editor([Block(.paragraph, "HelloWorld")])
        _ = e.takePendingChanges()
        let original = e.blocks[0].id
        e.split(original, at: 5)
        let created = e.blocks[1].id
        _ = e.takePendingChanges()

        e.undo()
        #expect(texts(e) == ["HelloWorld"])
        let pending = e.takePendingChanges()
        #expect(pending.deletes == [created], "undo must delete the block it un-creates")
        #expect(pending.upserts.map(\.id) == [original])

        e.redo()
        #expect(texts(e) == ["Hello", "World"])
        #expect(e.takePendingChanges().upserts.count == 2)
    }

    @Test func typingCollapsesIntoOneUndoStep() {
        let e = editor([Block(.paragraph, "")])
        let id = e.blocks[0].id
        for text in ["h", "he", "hel", "hell", "hello"] {
            e.setRuns([TextRun(text)], for: id, caret: text.count)
        }
        e.undo()
        #expect(texts(e) == [""])
        #expect(!e.canUndo)
    }

    @Test func deletingTheLastBlockLeavesAnEmptyParagraph() {
        let e = editor([Block(.paragraph, "only")])
        e.delete(e.blocks[0].id)
        #expect(e.blocks.count == 1)
        #expect(e.blocks[0].plainText == "")
    }

    @Test func remoteChangesMergeButLocalUnsavedEditsWin() {
        let e = editor([Block(.paragraph, "one"), Block(.paragraph, "two"), Block(.paragraph, "three")])
        _ = e.takePendingChanges()
        var fresh = e.blocks

        // The user is typing in block 0 (unsaved) while the AI rewrites blocks 0 and 1,
        // deletes block 2 and appends a new one.
        e.setRuns([TextRun("one, edited locally")], for: e.blocks[0].id, caret: 3)
        fresh[0].runs = [TextRun("ONE by AI")]
        fresh[1].runs = [TextRun("TWO by AI")]
        fresh.remove(at: 2)
        fresh.append(Block(id: "ai-new", pageID: "p", type: .bullet, position: 9999, runs: [TextRun("added by AI")]))

        let conflicts = e.applyRemote(fresh)
        #expect(texts(e) == ["one, edited locally", "TWO by AI", "added by AI"])
        #expect(conflicts == [e.blocks[0].id])
        #expect(e.takePendingChanges().upserts.map(\.plainText) == ["one, edited locally"], "only the local edit is still pending")
    }

    @Test func remoteMergeKeepsBlocksCreatedLocallyButNotYetSaved() {
        let e = editor([Block(.paragraph, "saved")])
        _ = e.takePendingChanges()
        let fresh = e.blocks
        e.split(e.blocks[0].id, at: 5)
        e.applyRemote(fresh)
        #expect(e.blocks.count == 2)
    }

    @Test func arrowKeysSkipBlocksWithoutText() {
        let e = editor([Block(.paragraph, "a"), Block(type: .divider), Block(.paragraph, "b")])
        #expect(e.neighbour(of: e.blocks[0].id, direction: 1) == e.blocks[2].id)
        #expect(e.neighbour(of: e.blocks[2].id, direction: -1) == e.blocks[0].id)
        #expect(e.neighbour(of: e.blocks[0].id, direction: -1) == nil)
    }

    @Test func splittingRunsCountsUTF16NotCharacters() {
        let runs = [TextRun("a👍b")]
        #expect(runs.utf16Count == 4)
        let (head, tail) = runs.splitUTF16(at: 3)
        #expect(head.plainText == "a👍")
        #expect(tail.plainText == "b")
    }

    @Test func acceptedAIEditReplacesOnlyTheSelectedRange() {
        let e = editor([Block(type: .paragraph, runs: [TextRun("Keep this. "), TextRun("Rewrite this part", marks: .italic), TextRun(". And keep this.")])])
        let id = e.blocks[0].id
        e.replaceText(in: id, range: 11..<28, with: MarkdownCodec.parse("**Better** wording"))
        #expect(e.blocks.count == 1)
        #expect(e.blocks[0].plainText == "Keep this. Better wording. And keep this.")
        #expect(e.blocks[0].runs.contains { $0.text == "Better" && $0.marks.contains(.bold) })
        e.undo()
        #expect(e.blocks[0].plainText == "Keep this. Rewrite this part. And keep this.")
    }

    @Test func multiBlockAIResultBecomesFollowingBlocksAndKeepsTheTail() {
        let e = editor([Block(.paragraph, "Intro: LIST HERE end."), Block(.paragraph, "after")])
        let id = e.blocks[0].id
        e.replaceText(in: id, range: 7..<16, with: MarkdownCodec.parse("three things\n\n- one\n- two"))
        #expect(texts(e) == ["Intro: three things", "one", "two end.", "after"])
        #expect(e.blocks.map(\.type) == [.paragraph, .bullet, .bullet, .paragraph])
        #expect(e.blocks.map(\.position) == e.blocks.map(\.position).sorted())
        #expect(e.takePendingChanges().upserts.count == 3)
        e.undo()
        #expect(texts(e) == ["Intro: LIST HERE end.", "after"])
    }

    @Test func replacingAWholeBlockMayChangeItsType() {
        let e = editor([Block(.paragraph, "make me a heading")])
        e.replaceText(in: e.blocks[0].id, range: 0..<17, with: MarkdownCodec.parse("## A heading"))
        #expect(e.blocks[0].type == .heading2)
        #expect(e.blocks[0].plainText == "A heading")
    }

    @Test func insertBelowAddsBlocksAsOneUndoStep() {
        let e = editor([Block(.bullet, "item", depth: 1), Block(.paragraph, "after")])
        e.insertBlocks(MarkdownCodec.parse("first\n\nsecond"), after: e.blocks[0].id)
        #expect(texts(e) == ["item", "first", "second", "after"])
        #expect(e.blocks[1].depth == 1, "inserted blocks sit at the anchor's depth")
        e.undo()
        #expect(texts(e) == ["item", "after"])
    }
}
