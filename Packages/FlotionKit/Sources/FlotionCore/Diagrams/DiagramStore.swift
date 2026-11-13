import Foundation
import GRDB

/// Checks LLM-authored diagrams before they are stored. The web view sandbox is the
/// security boundary; this exists to give the author a clear error instead of a diagram
/// that silently renders broken because an external resource was blocked.
public enum DiagramValidator {
    public static let maxBytes = 400_000
    public static let maxSteps = 60

    public static func validate(format: DiagramFormat, source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlotionError.invalid("Diagram source is empty.")
        }
        guard source.utf8.count <= maxBytes else {
            throw FlotionError.invalid("Diagram source is \(source.utf8.count) bytes; the limit is \(maxBytes).")
        }
        switch format {
        case .html:
            try checkSelfContained(source)
        case .steps:
            let steps: [DiagramStep]
            do { steps = try decodeJSON([DiagramStep].self, source) } catch {
                throw FlotionError.invalid("Steps must be a JSON array of {title?, caption?, svg | html}.")
            }
            guard (1...maxSteps).contains(steps.count) else {
                throw FlotionError.invalid("A steps diagram needs between 1 and \(maxSteps) steps.")
            }
            for (i, step) in steps.enumerated() {
                let body = [step.svg, step.html].compactMap { $0 }.filter { !$0.isEmpty }
                guard body.count == 1 else {
                    throw FlotionError.invalid("Step \(i + 1) must have exactly one of `svg` or `html`.")
                }
                try checkSelfContained(body[0])
            }
        }
    }

    private static let externalReference = try! NSRegularExpression(
        pattern: #"(?:\b(?:src|href|action|poster)\s*=\s*["']?\s*(?:https?:)?//)|(?:url\(\s*["']?\s*(?:https?:)?//)|(?:@import\b)"#,
        options: [.caseInsensitive])

    static func checkSelfContained(_ source: String) throws {
        let range = NSRange(source.startIndex..., in: source)
        if let m = externalReference.firstMatch(in: source, range: range), let r = Range(m.range, in: source) {
            throw FlotionError.invalid(
                "Diagrams must be self-contained: found an external reference near `\(source[r])`. Inline all scripts, styles, fonts and images.")
        }
    }
}

public extension Workspace {
    func diagram(id: String) throws -> Diagram? {
        try pool.read { try Self.fetchDiagram($0, id) }
    }

    /// Validates and stores a diagram, then inserts a diagram block that points at it.
    @discardableResult
    func createDiagram(pageID: String, title: String, format: DiagramFormat, source: String, height: Double? = nil,
                       at position: InsertPosition = .end, context: ChangeContext? = nil) throws -> (diagram: Diagram, block: Block) {
        try DiagramValidator.validate(format: format, source: source)
        let diagram = Diagram(title: title, format: format, source: source, height: Self.clampHeight(height))
        let block = try pool.write { db -> Block in
            guard try Self.fetchPage(db, pageID) != nil else { throw FlotionError.notFound("page \(pageID)") }
            try Self.writeDiagram(db, diagram)
            let draft = Block(type: .diagram, props: BlockProps(diagramID: diagram.id))
            let block = try Self.insert(db, pageID: pageID, drafts: [draft], at: position, context: context)[0]
            try Self.touchPage(db, pageID)
            return block
        }
        notifyIfExternal(context)
        return (diagram, block)
    }

    @discardableResult
    func updateDiagram(id: String, title: String? = nil, format: DiagramFormat? = nil, source: String? = nil,
                       height: Double? = nil, notify: Bool = false) throws -> Diagram {
        let diagram = try pool.write { db -> Diagram in
            guard var diagram = try Self.fetchDiagram(db, id) else { throw FlotionError.notFound("diagram \(id)") }
            if let title { diagram.title = title }
            if let format { diagram.format = format }
            if let source { diagram.source = source }
            if let height { diagram.height = Self.clampHeight(height) }
            try DiagramValidator.validate(format: diagram.format, source: diagram.source)
            diagram.updatedAt = Date()
            try Self.writeDiagram(db, diagram)
            return diagram
        }
        if notify { ChangeNotifier.post() }
        return diagram
    }

    /// The diagram a block points at, when the block is a diagram block.
    func diagram(forBlock blockID: String) throws -> Diagram? {
        guard let block = try block(id: blockID), let id = block.props.diagramID else { return nil }
        return try diagram(id: id)
    }
}

extension Workspace {
    static func clampHeight(_ height: Double?) -> Double { min(1200, max(120, height ?? 360)) }

    static func fetchDiagram(_ db: Database, _ id: String) throws -> Diagram? {
        try Row.fetchOne(db, sql: "SELECT id, title, format, source, height, updated_at FROM diagrams WHERE id = ?", arguments: [id]).map { row in
            Diagram(id: row[0], title: row[1], format: DiagramFormat(rawValue: row[2]) ?? .html, source: row[3],
                    height: row[4], updatedAt: Date(timeIntervalSince1970: row[5]))
        }
    }

    static func writeDiagram(_ db: Database, _ d: Diagram) throws {
        try db.execute(sql: """
            INSERT INTO diagrams (id, title, format, source, height, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, format = excluded.format,
                source = excluded.source, height = excluded.height, updated_at = excluded.updated_at
            """, arguments: [d.id, d.title, d.format.rawValue, d.source, d.height, ts(d.updatedAt)])
    }
}
