import Foundation

public func newID() -> String { UUID().uuidString.lowercased() }

// MARK: - Pages

public struct Page: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var parentID: String?
    public var title: String
    public var icon: String?
    public var position: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(id: String = newID(), parentID: String? = nil, title: String = "", icon: String? = nil,
                position: Double = 0, createdAt: Date = Date(), updatedAt: Date = Date(), archivedAt: Date? = nil) {
        self.id = id; self.parentID = parentID; self.title = title; self.icon = icon
        self.position = position; self.createdAt = createdAt; self.updatedAt = updatedAt; self.archivedAt = archivedAt
    }
}

// MARK: - Blocks

public enum BlockType: String, Codable, Sendable, CaseIterable {
    case paragraph, heading1, heading2, heading3, bullet, numbered, todo, quote, code, divider, pageLink, diagram

    /// Blocks that carry editable inline text.
    public var hasText: Bool {
        switch self {
        case .divider, .pageLink, .diagram: false
        default: true
        }
    }
}

public struct Marks: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = Marks(rawValue: 1)
    public static let italic = Marks(rawValue: 2)
    public static let code = Marks(rawValue: 4)
    public static let strike = Marks(rawValue: 8)
}

/// A span of inline text with uniform formatting.
public struct TextRun: Codable, Sendable, Equatable {
    public var text: String
    public var marks: Marks
    public var link: String?

    public init(_ text: String, marks: Marks = [], link: String? = nil) {
        self.text = text; self.marks = marks; self.link = link
    }

    enum CodingKeys: String, CodingKey { case text = "t", marks = "m", link = "l" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        marks = Marks(rawValue: try c.decodeIfPresent(Int.self, forKey: .marks) ?? 0)
        link = try c.decodeIfPresent(String.self, forKey: .link)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        if !marks.isEmpty { try c.encode(marks.rawValue, forKey: .marks) }
        try c.encodeIfPresent(link, forKey: .link)
    }
}

public extension Array where Element == TextRun {
    var plainText: String { count == 1 ? self[0].text : map(\.text).joined() }

    var isPlain: Bool { allSatisfy { $0.marks.isEmpty && $0.link == nil } }

    /// Drops empty runs and merges neighbours with identical formatting.
    func normalized() -> [TextRun] {
        var out: [TextRun] = []
        for run in self where !run.text.isEmpty {
            if let last = out.last, last.marks == run.marks, last.link == run.link {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }
}

public struct BlockProps: Codable, Sendable, Equatable {
    public var checked: Bool?
    public var language: String?
    public var diagramID: String?
    public var targetPageID: String?

    public init(checked: Bool? = nil, language: String? = nil, diagramID: String? = nil, targetPageID: String? = nil) {
        self.checked = checked; self.language = language; self.diagramID = diagramID; self.targetPageID = targetPageID
    }

    public var isEmpty: Bool { checked == nil && language == nil && diagramID == nil && targetPageID == nil }
}

public struct Block: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var pageID: String
    public var type: BlockType
    public var depth: Int
    public var position: Double
    public var runs: [TextRun]
    public var props: BlockProps
    public var updatedAt: Date

    public init(id: String = newID(), pageID: String = "", type: BlockType = .paragraph, depth: Int = 0,
                position: Double = 0, runs: [TextRun] = [], props: BlockProps = BlockProps(), updatedAt: Date = Date()) {
        self.id = id; self.pageID = pageID; self.type = type; self.depth = depth
        self.position = position; self.runs = runs; self.props = props; self.updatedAt = updatedAt
    }

    public init(_ type: BlockType, _ text: String, depth: Int = 0, props: BlockProps = BlockProps()) {
        self.init(type: type, depth: depth, runs: text.isEmpty ? [] : [TextRun(text)], props: props)
    }

    public var plainText: String { runs.plainText }
}

// MARK: - Diagrams

public enum DiagramFormat: String, Codable, Sendable { case html, steps }

public struct DiagramStep: Codable, Sendable, Equatable {
    public var title: String?
    public var caption: String?
    public var svg: String?
    public var html: String?

    public init(title: String? = nil, caption: String? = nil, svg: String? = nil, html: String? = nil) {
        self.title = title; self.caption = caption; self.svg = svg; self.html = html
    }
}

public struct Diagram: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var format: DiagramFormat
    /// A full HTML document for `.html`; a JSON array of `DiagramStep` for `.steps`.
    public var source: String
    public var height: Double
    public var updatedAt: Date

    public init(id: String = newID(), title: String, format: DiagramFormat, source: String,
                height: Double = 360, updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.format = format; self.source = source
        self.height = height; self.updatedAt = updatedAt
    }
}

// MARK: - Change tracking and search

/// Who made a write. User edits pass `nil`; AI and MCP writes pass a context so they are logged and undoable.
public struct ChangeContext: Sendable, Equatable {
    public var actor: String
    public var turnID: String?

    public init(actor: String, turnID: String? = nil) {
        self.actor = actor; self.turnID = turnID
    }
}

public struct ChangeEntry: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var entity: String      // "block" | "page"
    public var entityID: String
    public var pageID: String
    public var before: String?     // JSON
    public var after: String?      // JSON
    public var actor: String
    public var turnID: String?
    public var at: Date
}

public struct SearchHit: Sendable, Equatable {
    public var pageID: String
    public var pageTitle: String
    public var blockID: String?
    public var snippet: String

    public init(pageID: String, pageTitle: String, blockID: String?, snippet: String) {
        self.pageID = pageID; self.pageTitle = pageTitle; self.blockID = blockID; self.snippet = snippet
    }
}

public enum InsertPosition: Sendable, Equatable {
    case start
    case end
    case after(String)
}

public enum FlotionError: Error, LocalizedError, Equatable {
    case notFound(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "Not found: \(what)"
        case .invalid(let why): why
        }
    }
}
