import Foundation
import Testing
import FlotionCore
import FlotionEditor

@Suite struct SlashMenuTests {
    private func session(_ text: String = "/", anchor: Int = 0, ai: Bool = true) -> SlashMenuSession {
        var s = SlashMenuSession(blockID: "b", anchor: anchor, commands: SlashMenu.commands(includingAI: ai))
        _ = s.update(text: text, caret: (text as NSString).length)
        return s
    }

    @Test func slashOpensOnlyAtTheStartOfAWord() {
        #expect(SlashMenu.opens(in: "/", slashAt: 0))
        #expect(SlashMenu.opens(in: "some text /", slashAt: 10))
        #expect(!SlashMenu.opens(in: "and/or", slashAt: 3))
        #expect(!SlashMenu.opens(in: "1/2", slashAt: 1))
        #expect(!SlashMenu.opens(in: "abc", slashAt: 1), "the character there is not a slash")
        #expect(!SlashMenu.opens(in: "/", slashAt: 4), "out of range")
    }

    @Test func emptyQueryListsEveryCommandWithAIFirst() {
        let s = session()
        #expect(s.matches.first?.action == .askAI)
        #expect(s.matches.count == SlashMenu.blockCommands.count + 1)
        #expect(session(ai: false).matches.first?.title == "Text")
    }

    @Test func filterRanksTitlePrefixThenWordThenKeyword() {
        #expect(session("/head").matches.map(\.title) == ["Heading 1", "Heading 2", "Heading 3"])
        #expect(session("/heading 2").matches.map(\.title) == ["Heading 2"])
        #expect(session("/h2").matches.map(\.title) == ["Heading 2"], "keywords match")
        #expect(session("/list").matches.map(\.title) == ["Bulleted list", "Numbered list", "To-do list"], "a later word matches")
        #expect(session("/todo").matches.first?.title == "To-do list")
        #expect(session("/LIST").matches.count == 3, "case does not matter")
        #expect(session("/zzz").matches.isEmpty)
    }

    @Test func typedRangeCoversTheSlashAndQuery() {
        let s = session("Intro /quo", anchor: 6)
        #expect(s.query == "quo")
        #expect(s.typedRange == 6..<10)
        #expect(s.selectedCommand?.title == "Quote")
    }

    @Test func menuClosesWhenTheSlashOrCaretGoes() {
        var s = session("/he")
        var stays = s.update(text: "he", caret: 2)
        #expect(!stays, "slash deleted")
        s = session("/he")
        stays = s.update(text: "/he", caret: 0)
        #expect(!stays, "caret moved before the slash")
        s = session("/he")
        stays = s.update(text: "/he", caret: 4)
        #expect(!stays, "caret past the end of the text")
        s = session("/")
        stays = s.update(text: "/ ", caret: 2)
        #expect(!stays, "a slash followed by a space is just a slash")
        s = session("/zzz")
        stays = s.update(text: "/zzz", caret: 4)
        #expect(stays, "no matches yet keeps the menu open to show so")
        stays = s.update(text: "/zzz ", caret: 5)
        #expect(!stays, "a space after a query with no matches closes it")
        s = session("/")
        stays = s.update(text: "/to-do list", caret: 11)
        #expect(stays, "spaces inside a matching query are fine")
    }

    @Test func highlightWrapsAndResetsWhenTheQueryChanges() {
        var s = session("/head")
        s.move(1)
        #expect(s.selectedCommand?.title == "Heading 2")
        s.move(-2)
        #expect(s.selectedCommand?.title == "Heading 3", "wraps from the top to the bottom")
        s.move(1)
        #expect(s.selectedCommand?.title == "Heading 1", "wraps from the bottom to the top")
        s.move(1)
        _ = s.update(text: "/headi", caret: 6)
        #expect(s.selected == 0, "a new query starts at the best match")
        s.select(2)
        #expect(s.selectedCommand?.title == "Heading 3")
        s.select(10)
        #expect(s.selected == 2, "an index out of range is ignored")
    }
}
