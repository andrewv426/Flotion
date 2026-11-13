import Foundation
import Testing
import FlotionCore

/// What must survive a round trip: everything except ids, positions and timestamps.
private struct Shape: Equatable, CustomStringConvertible {
    var type: BlockType
    var depth: Int
    var runs: [TextRun]
    var props: BlockProps

    init(_ b: Block) {
        type = b.type; depth = b.depth; runs = b.runs.normalized(); props = b.props
        if type == .todo, props.checked == nil { props.checked = false }
    }

    var description: String { "\(type)@\(depth) \(runs.map { "\($0.text)|\($0.marks.rawValue)|\($0.link ?? "")" }) \(props)" }
}

private func roundTrip(_ blocks: [Block], sourceLocation: SourceLocation = #_sourceLocation) {
    let markdown = MarkdownCodec.render(blocks)
    let parsed = MarkdownCodec.parse(markdown)
    #expect(parsed.map(Shape.init) == blocks.map(Shape.init), "markdown was:\n\(markdown)", sourceLocation: sourceLocation)
}

@Suite struct MarkdownCodecTests {
    @Test func everyBlockTypeRoundTrips() {
        roundTrip([
            Block(.heading1, "Title"),
            Block(.heading2, "Section"),
            Block(.heading3, "Subsection"),
            Block(.paragraph, "A plain paragraph."),
            Block(.bullet, "first"),
            Block(.bullet, "nested", depth: 1),
            Block(.bullet, "deeper", depth: 2),
            Block(.bullet, "second"),
            Block(.numbered, "one"),
            Block(.numbered, "two"),
            Block(.numbered, "two point one", depth: 1),
            Block(.todo, "open task", props: BlockProps(checked: false)),
            Block(.todo, "done task", props: BlockProps(checked: true)),
            Block(.quote, "Quoted line."),
            Block(.code, "func f() {\n    return 1\n}", props: BlockProps(language: "swift")),
            Block(type: .divider),
            Block(type: .pageLink, runs: [TextRun("Networking notes")], props: BlockProps(targetPageID: "abc-123")),
            Block(type: .diagram, props: BlockProps(diagramID: "d1a9-77")),
            Block(.paragraph, "After everything."),
        ])
    }

    @Test func inlineMarksAndLinksRoundTrip() {
        roundTrip([
            Block(type: .paragraph, runs: [
                TextRun("Plain, "), TextRun("bold", marks: .bold), TextRun(", "), TextRun("italic", marks: .italic),
                TextRun(", "), TextRun("struck", marks: .strike), TextRun(", "), TextRun("code()", marks: .code),
                TextRun(" and a "), TextRun("link", link: "https://example.com/a?b=1"), TextRun("."),
            ]),
            Block(type: .bullet, runs: [TextRun("both", marks: [.bold, .italic]), TextRun(" then plain")]),
        ])
    }

    @Test func markdownSyntaxInPlainTextIsEscaped() {
        roundTrip([
            Block(.paragraph, "# not a heading"),
            Block(.paragraph, "- not a list"),
            Block(.paragraph, "1. not numbered"),
            Block(.paragraph, "> not a quote"),
            Block(.paragraph, "2 * 3 * 4 and snake_case_name and [brackets] and a <tag> and ~tilde~"),
            Block(.paragraph, "back\\slash and `tick`"),
            Block(.code, "```\nfence inside\n```"),
        ])
    }

    @Test func whitespaceAtRunEdgesMovesOutsideEmphasis() {
        // Markdown emphasis cannot end in a space, so the space leaves the bold run.
        // The text itself must be unchanged.
        let block = Block(type: .paragraph, runs: [TextRun("lead "), TextRun("bold with trailing space ", marks: .bold), TextRun("tail")])
        let parsed = MarkdownCodec.parse(MarkdownCodec.render([block]))
        #expect(parsed.count == 1)
        #expect(parsed[0].plainText == block.plainText)
        #expect(parsed[0].runs == [TextRun("lead "), TextRun("bold with trailing space", marks: .bold), TextRun(" tail")])
    }

    @Test func emptyDocumentAndEmptyBlocks() {
        #expect(MarkdownCodec.parse("").isEmpty)
        #expect(MarkdownCodec.render([]) == "")
        let parsed = MarkdownCodec.parse("- \n- item")
        #expect(parsed.map(\.type) == [.bullet, .bullet])
        #expect(parsed.map(\.plainText) == ["", "item"])
    }

    @Test func parsesTypicalLLMOutput() {
        let markdown = """
            # Plan

            Intro with **bold** and a [link](https://example.com).

            1. First step
            2. Second step
               - detail a
               - detail b

            - [ ] todo
            - [x] done

            > A quote

            ```python
            print("hi")
            ```

            ---

            | a | b |
            |---|---|
            | 1 | 2 |
            """
        let blocks = MarkdownCodec.parse(markdown)
        #expect(blocks.map(\.type) == [
            .heading1, .paragraph, .numbered, .numbered, .bullet, .bullet, .todo, .todo, .quote, .code, .divider, .paragraph,
        ])
        #expect(blocks[4].depth == 1)
        #expect(blocks[7].props.checked == true)
        #expect(blocks[9].props.language == "python")
        #expect(blocks[9].plainText == "print(\"hi\")")
        #expect(blocks[11].plainText.contains("|1|2|"), "tables degrade to plain text, not dropped")
    }

    @Test func unanchoredDepthDoesNotBecomeACodeBlock() {
        // A depth-1 paragraph with no list above it must not render as 4-space-indented code.
        let markdown = MarkdownCodec.render([Block(.paragraph, "orphan", depth: 1)])
        #expect(MarkdownCodec.parse(markdown).map(\.type) == [.paragraph])
    }
}
