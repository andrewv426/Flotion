import FlotionCore
import Foundation

/// What choosing a slash-menu entry does.
public enum SlashAction: Equatable, Sendable {
    /// Open the inline AI prompt at the slash.
    case askAI
    /// Turn the block into this type (or, for a divider in a line that has text, add one below).
    case turnInto(BlockType)
}

public struct SlashCommand: Equatable, Sendable, Identifiable {
    public let title: String
    public let detail: String
    /// Extra words the filter matches, such as "h1" or "todo".
    public let keywords: [String]
    public let action: SlashAction

    public var id: String { title }

    public init(title: String, detail: String, keywords: [String] = [], action: SlashAction) {
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.action = action
    }
}

public enum SlashMenu {
    public static let askAI = SlashCommand(title: "Ask AI to write", detail: "Draft new text here with Claude",
                                           keywords: ["ai", "claude", "write", "generate"], action: .askAI)

    public static let blockCommands: [SlashCommand] = [
        SlashCommand(title: "Text", detail: "Plain paragraph", keywords: ["paragraph", "plain"], action: .turnInto(.paragraph)),
        SlashCommand(title: "Heading 1", detail: "Large section heading", keywords: ["h1", "title"], action: .turnInto(.heading1)),
        SlashCommand(title: "Heading 2", detail: "Medium section heading", keywords: ["h2", "subtitle"], action: .turnInto(.heading2)),
        SlashCommand(title: "Heading 3", detail: "Small section heading", keywords: ["h3"], action: .turnInto(.heading3)),
        SlashCommand(title: "Bulleted list", detail: "List with bullet points", keywords: ["bullet", "ul", "unordered"], action: .turnInto(.bullet)),
        SlashCommand(title: "Numbered list", detail: "List with numbers", keywords: ["ol", "ordered", "number"], action: .turnInto(.numbered)),
        SlashCommand(title: "To-do list", detail: "Checklist of tasks", keywords: ["todo", "task", "checkbox", "check"], action: .turnInto(.todo)),
        SlashCommand(title: "Quote", detail: "Quoted passage", keywords: ["blockquote", "citation"], action: .turnInto(.quote)),
        SlashCommand(title: "Code", detail: "Monospaced code snippet", keywords: ["snippet", "pre"], action: .turnInto(.code)),
        SlashCommand(title: "Divider", detail: "Line between blocks", keywords: ["hr", "rule", "separator", "line"], action: .turnInto(.divider)),
    ]

    /// The entries offered, with "Ask AI" first when an assistant is available.
    public static func commands(includingAI: Bool) -> [SlashCommand] {
        includingAI ? [askAI] + blockCommands : blockCommands
    }

    /// True when a "/" just typed at `location` (UTF-16) should open the menu: it must start
    /// a word, so "and/or", dates and URLs stay plain text.
    public static func opens(in text: String, slashAt location: Int) -> Bool {
        let ns = text as NSString
        guard location >= 0, location < ns.length, ns.character(at: location) == 0x2F else { return false }
        guard location > 0 else { return true }
        guard let previous = UnicodeScalar(ns.character(at: location - 1)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(previous)
    }

    /// The commands matching what was typed after the slash, best match first. An empty query
    /// matches everything in its original order.
    public static func filter(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        func rank(_ c: SlashCommand) -> Int? {
            let title = c.title.lowercased()
            if title.hasPrefix(q) { return 0 }
            let words = title.split(whereSeparator: { $0 == " " || $0 == "-" })
            if words.contains(where: { $0.hasPrefix(q) }) { return 1 }
            if c.keywords.contains(where: { $0.hasPrefix(q) }) { return 2 }
            if title.contains(q) { return 3 }
            return nil
        }
        return commands.enumerated()
            .compactMap { offset, c in rank(c).map { (rank: $0, offset: offset, command: c) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.command)
    }
}

/// One open slash menu: where its "/" is, what has been typed after it, and which entry is
/// highlighted. The view feeds it every edit and caret move; it says when the menu should close.
public struct SlashMenuSession: Equatable, Sendable {
    public let blockID: String
    /// UTF-16 offset of the "/" in the block.
    public let anchor: Int
    public let commands: [SlashCommand]
    public private(set) var query = ""
    public private(set) var matches: [SlashCommand]
    public private(set) var selected = 0

    public init(blockID: String, anchor: Int, commands: [SlashCommand]) {
        self.blockID = blockID
        self.anchor = anchor
        self.commands = commands
        matches = commands
    }

    /// The "/" and the query, which choosing an entry removes from the block.
    public var typedRange: Range<Int> { anchor..<(anchor + 1 + query.utf16.count) }

    public var selectedCommand: SlashCommand? { matches.indices.contains(selected) ? matches[selected] : nil }

    /// Re-reads the query after an edit or a caret move. Returns false when the menu should close:
    /// the slash was deleted, the caret left the query, the query starts with a space ("a / b"),
    /// spans a line break, or ends in a space with nothing matching.
    public mutating func update(text: String, caret: Int) -> Bool {
        let ns = text as NSString
        guard anchor < ns.length, ns.character(at: anchor) == 0x2F, caret > anchor, caret <= ns.length else { return false }
        let typed = ns.substring(with: NSRange(location: anchor + 1, length: caret - anchor - 1))
        if typed.hasPrefix(" ") || typed.contains("\n") { return false }
        let found = SlashMenu.filter(commands, query: typed)
        if found.isEmpty, typed.hasSuffix(" ") { return false }
        if typed != query { selected = 0 }
        query = typed
        matches = found
        return true
    }

    /// Moves the highlight, wrapping at either end.
    public mutating func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = ((selected + delta) % matches.count + matches.count) % matches.count
    }

    public mutating func select(_ index: Int) {
        if matches.indices.contains(index) { selected = index }
    }
}
