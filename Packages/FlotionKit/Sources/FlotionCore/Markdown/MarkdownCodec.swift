import Foundation
import Markdown

/// Converts between Flotion blocks and Markdown, the format LLMs read and write.
///
/// Flotion-specific blocks use two conventions:
///   sub-page link   a paragraph holding only `[Title](flotion://page/<id>)`
///   diagram         an HTML comment `<!-- flotion:diagram id=<id> -->`
public enum MarkdownCodec {
    public static let pageLinkPrefix = "flotion://page/"

    // MARK: Markdown → blocks

    public static func parse(_ markdown: String) -> [Block] {
        var out: [Block] = []
        for child in Document(parsing: markdown).children {
            appendBlock(child, depth: 0, into: &out)
        }
        return out
    }

    private static func appendBlock(_ node: any Markup, depth: Int, into out: inout [Block]) {
        switch node {
        case let heading as Heading:
            let type: BlockType = heading.level <= 1 ? .heading1 : heading.level == 2 ? .heading2 : .heading3
            out.append(Block(type: type, depth: depth, runs: runs(of: heading)))
        case let paragraph as Paragraph:
            if paragraph.childCount == 1, let link = paragraph.child(at: 0) as? Markdown.Link,
               let dest = link.destination, dest.hasPrefix(pageLinkPrefix) {
                out.append(Block(type: .pageLink, depth: depth, runs: runs(of: link),
                                 props: BlockProps(targetPageID: String(dest.dropFirst(pageLinkPrefix.count)))))
            } else {
                out.append(Block(type: .paragraph, depth: depth, runs: runs(of: paragraph)))
            }
        case let list as UnorderedList:
            for item in list.listItems { appendItem(item, type: .bullet, depth: depth, into: &out) }
        case let list as OrderedList:
            for item in list.listItems { appendItem(item, type: .numbered, depth: depth, into: &out) }
        case let quote as BlockQuote:
            for child in quote.children {
                if let paragraph = child as? Paragraph {
                    out.append(Block(type: .quote, depth: depth, runs: runs(of: paragraph)))
                } else {
                    appendBlock(child, depth: depth, into: &out)
                }
            }
        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            out.append(Block(type: .code, depth: depth, runs: text.isEmpty ? [] : [TextRun(text)],
                             props: BlockProps(language: code.language.flatMap { $0.isEmpty ? nil : $0 })))
        case is ThematicBreak:
            out.append(Block(type: .divider, depth: depth))
        case let html as HTMLBlock:
            if let id = diagramID(in: html.rawHTML) {
                out.append(Block(type: .diagram, depth: depth, props: BlockProps(diagramID: id)))
            } else {
                let text = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(Block(.paragraph, text, depth: depth))
            }
        default:
            // Tables and anything else outside the v1 block set are kept as plain text.
            let text = node.format().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(Block(.paragraph, text, depth: depth)) }
        }
    }

    private static func appendItem(_ item: ListItem, type: BlockType, depth: Int, into out: inout [Block]) {
        var isFirst = true
        for child in item.children {
            if isFirst, let paragraph = child as? Paragraph {
                if let box = item.checkbox {
                    out.append(Block(type: .todo, depth: depth, runs: runs(of: paragraph),
                                     props: BlockProps(checked: box == .checked)))
                } else {
                    out.append(Block(type: type, depth: depth, runs: runs(of: paragraph)))
                }
            } else {
                if isFirst { out.append(Block(type: type, depth: depth)) }
                appendBlock(child, depth: depth + 1, into: &out)
            }
            isFirst = false
        }
        if isFirst { out.append(Block(type: item.checkbox != nil ? .todo : type, depth: depth)) }
    }

    private static func runs(of node: any Markup) -> [TextRun] {
        var out: [TextRun] = []
        collect(node, marks: [], link: nil, into: &out)
        return out.normalized()
    }

    private static func collect(_ node: any Markup, marks: Marks, link: String?, into out: inout [TextRun]) {
        for child in node.children {
            switch child {
            case let text as Markdown.Text:
                out.append(TextRun(text.string, marks: marks, link: link))
            case let strong as Strong:
                collect(strong, marks: marks.union(.bold), link: link, into: &out)
            case let emphasis as Emphasis:
                collect(emphasis, marks: marks.union(.italic), link: link, into: &out)
            case let strike as Strikethrough:
                collect(strike, marks: marks.union(.strike), link: link, into: &out)
            case let code as InlineCode:
                out.append(TextRun(code.code, marks: marks.union(.code), link: link))
            case let l as Markdown.Link:
                collect(l, marks: marks, link: l.destination ?? link, into: &out)
            case is SoftBreak:
                out.append(TextRun(" ", marks: marks, link: link))
            case is LineBreak:
                out.append(TextRun("\n", marks: marks, link: link))
            case let html as InlineHTML:
                out.append(TextRun(html.rawHTML, marks: marks, link: link))
            default:
                if let plain = child as? any PlainTextConvertibleMarkup {
                    out.append(TextRun(plain.plainText, marks: marks, link: link))
                }
            }
        }
    }

    private static func diagramID(in html: String) -> String? {
        let marker = "flotion:diagram id="
        guard let r = html.range(of: marker) else { return nil }
        let id = html[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return id.isEmpty ? nil : String(id)
    }

    // MARK: Blocks → Markdown

    public static func render(_ blocks: [Block]) -> String {
        var out = ""
        var previous: Block?
        var lastListDepth = -1
        var counters: [Int: Int] = [:]

        for block in blocks {
            let isList = block.type == .bullet || block.type == .numbered || block.type == .todo
            // A block can only be nested one level below the nearest list item above it.
            let depth = min(block.depth, lastListDepth + 1)
            let indent = String(repeating: "    ", count: depth)

            if let previous {
                let prevIsList = previous.type == .bullet || previous.type == .numbered || previous.type == .todo
                out += (isList && prevIsList) ? "\n" : "\n\n"
            }

            if block.type == .numbered {
                counters[depth, default: 0] += 1
                counters = counters.filter { $0.key <= depth }
            } else {
                counters = counters.filter { $0.key < depth }
            }

            let text = inline(block.runs, indent: indent)
            switch block.type {
            case .paragraph: out += indent + escapeLineStart(text)
            case .heading1: out += indent + "# " + text
            case .heading2: out += indent + "## " + text
            case .heading3: out += indent + "### " + text
            case .bullet: out += indent + "- " + text
            case .numbered: out += indent + "\(counters[depth] ?? 1). " + text
            case .todo: out += indent + (block.props.checked == true ? "- [x] " : "- [ ] ") + text
            case .quote: out += indent + "> " + text
            case .code:
                let body = block.plainText
                let fence = body.contains("```") ? "````" : "```"
                let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { indent + $0 }
                out += indent + fence + (block.props.language ?? "") + "\n" + lines.joined(separator: "\n") + "\n" + indent + fence
            case .divider: out += indent + "---"
            case .pageLink:
                out += indent + "[\(escape(block.plainText.isEmpty ? "Untitled" : block.plainText))](\(pageLinkPrefix)\(block.props.targetPageID ?? ""))"
            case .diagram:
                out += indent + "<!-- flotion:diagram id=\(block.props.diagramID ?? "") -->"
            }

            if isList { lastListDepth = depth } else if depth == 0 { lastListDepth = -1 }
            previous = block
        }
        return out
    }

    private static func inline(_ runs: [TextRun], indent: String) -> String {
        var out = ""
        for run in runs {
            if run.marks.contains(.code) {
                let tick = run.text.contains("`") ? "``" : "`"
                let pad = run.text.hasPrefix("`") || run.text.hasSuffix("`") ? " " : ""
                var piece = tick + pad + run.text + pad + tick
                if let link = run.link { piece = "[\(piece)](\(link))" }
                out += piece
                continue
            }
            // Emphasis markers must hug non-space text, so whitespace moves outside them.
            let lead = String(run.text.prefix { $0 == " " || $0 == "\n" })
            let trail = lead.count == run.text.count ? "" : String(run.text.reversed().prefix { $0 == " " || $0 == "\n" }.reversed())
            let core = String(run.text.dropFirst(lead.count).dropLast(trail.count))
            var piece = escape(core).replacingOccurrences(of: "\n", with: "\\\n" + indent)
            if !core.isEmpty {
                if run.marks.contains(.strike) { piece = "~~\(piece)~~" }
                if run.marks.contains(.italic) { piece = "*\(piece)*" }
                if run.marks.contains(.bold) { piece = "**\(piece)**" }
                if let link = run.link { piece = "[\(piece)](\(link))" }
            }
            out += hardBreaks(lead, indent) + piece + hardBreaks(trail, indent)
        }
        return out
    }

    private static func hardBreaks(_ s: String, _ indent: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\\n" + indent)
    }

    private static let specials: Set<Character> = ["\\", "*", "_", "`", "[", "]", "<", "~"]

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if specials.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Stops ordinary paragraph text from being read as a heading, list, quote or rule.
    private static func escapeLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if first == "#" || first == ">" || first == "+" { return "\\" + text }
        if first == "-" || first == "=" { return "\\" + text }
        if first.isNumber {
            let digits = text.prefix { $0.isNumber }
            let rest = text.dropFirst(digits.count)
            if let mark = rest.first, mark == "." || mark == ")" {
                return digits + "\\" + rest
            }
        }
        return text
    }
}
