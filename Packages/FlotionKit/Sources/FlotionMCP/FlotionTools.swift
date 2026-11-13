import FlotionCore
import Foundation
import MCP

/// The Flotion tool surface. One implementation serves external MCP clients and the in-app AI.
public struct FlotionTools: Sendable {
    public let workspace: Workspace
    /// Recorded on every write so changes can be attributed and undone.
    public let actor: String

    public init(workspace: Workspace, actor: String = "mcp") {
        self.workspace = workspace
        self.actor = actor
    }

    private var context: ChangeContext { ChangeContext(actor: actor) }

    public static let instructions = """
        Flotion is the user's notes workspace: pages arranged in a tree, each page a list of blocks. \
        Find pages with search_pages or list_pages, read one with get_page (Markdown plus block ids), \
        then edit with append_blocks, update_block, delete_block. Page content is written as Markdown. \
        Use create_diagram for animated or step-by-step visuals. Nothing is permanently deleted: \
        archive_page moves a page to the Trash.
        """

    // MARK: Dispatch

    public func call(_ name: String, _ arguments: [String: Value]) -> CallTool.Result {
        let args = Args(arguments)
        do {
            let text: String
            switch name {
            case "search_pages": text = try searchPages(args)
            case "list_pages": text = try listPages(args)
            case "get_page": text = try getPage(args)
            case "create_page": text = try createPage(args)
            case "update_page": text = try updatePage(args)
            case "append_blocks": text = try appendBlocks(args)
            case "update_block": text = try updateBlock(args)
            case "delete_block": text = try deleteBlock(args)
            case "archive_page": text = try archivePage(args)
            case "create_diagram": text = try createDiagram(args)
            case "get_diagram": text = try getDiagram(args)
            case "update_diagram": text = try updateDiagram(args)
            default: throw FlotionError.invalid("Unknown tool: \(name)")
            }
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: Pages

    private func searchPages(_ a: Args) throws -> String {
        let hits = try workspace.search(try a.string("query"), limit: min(50, max(1, a.int("limit") ?? 10)))
        if hits.isEmpty { return "No pages match." }
        return json(.array(hits.map { hit in
            var o: [String: Value] = ["page_id": .string(hit.pageID), "title": .string(hit.pageTitle)]
            if !hit.snippet.isEmpty { o["snippet"] = .string(hit.snippet) }
            if let id = hit.blockID { o["block_id"] = .string(id) }
            return .object(o)
        }))
    }

    private func listPages(_ a: Args) throws -> String {
        let all = try workspace.pages()
        var childCount: [String: Int] = [:]
        for page in all { if let p = page.parentID { childCount[p, default: 0] += 1 } }
        let parent = a.optString("parent_id")
        let rows = all.filter { $0.parentID == parent }
        if rows.isEmpty { return parent == nil ? "The workspace has no pages yet." : "This page has no sub-pages." }
        return json(.array(rows.map { page in
            var o: [String: Value] = [
                "page_id": .string(page.id), "title": .string(page.title.isEmpty ? "Untitled" : page.title),
                "sub_pages": .int(childCount[page.id] ?? 0),
            ]
            if let icon = page.icon { o["icon"] = .string(icon) }
            return .object(o)
        }))
    }

    private func getPage(_ a: Args) throws -> String {
        let page = try workspace.requirePage(id: try a.string("page_id"))
        let blocks = try workspace.blocks(pageID: page.id)
        var out = "page_id: \(page.id)\ntitle: \(page.title.isEmpty ? "Untitled" : page.title)\n"
        if let parent = page.parentID { out += "parent_id: \(parent)\n" }
        if page.archivedAt != nil { out += "status: in Trash\n" }
        let children = try workspace.children(of: page.id)
        if !children.isEmpty {
            out += "sub_pages: " + children.map { "\($0.title.isEmpty ? "Untitled" : $0.title) (\($0.id))" }.joined(separator: ", ") + "\n"
        }
        out += "\n" + (blocks.isEmpty ? "(empty page)" : MarkdownCodec.render(blocks))
        if a.bool("include_block_ids") ?? true, !blocks.isEmpty {
            out += "\n\nBlock outline (block_id | type | text):\n"
            out += blocks.map { b in
                let preview = b.plainText.replacingOccurrences(of: "\n", with: " ")
                return "\(b.id) | \(b.type.rawValue) | \(preview.count > 60 ? preview.prefix(60) + "…" : preview)"
            }.joined(separator: "\n")
        }
        return out
    }

    private func createPage(_ a: Args) throws -> String {
        let blocks = a.optString("markdown").map(MarkdownCodec.parse) ?? []
        let page = try workspace.createPage(title: try a.string("title"), parentID: a.optString("parent_id"),
                                            icon: a.optString("icon"), blocks: blocks, context: context)
        return json(["page_id": .string(page.id), "title": .string(page.title), "blocks": .int(blocks.count)])
    }

    private func updatePage(_ a: Args) throws -> String {
        let id = try a.string("page_id")
        // An empty parent_id means "move to the top level".
        let parent: String?? = a.has("parent_id") ? .some(a.optString("parent_id")) : nil
        let icon: String?? = a.has("icon") ? .some(a.optString("icon")) : nil
        let page = try workspace.updatePage(id: id, title: a.optString("title", allowEmpty: true), icon: icon, parentID: parent, context: context)
        return json(["page_id": .string(page.id), "title": .string(page.title)])
    }

    private func archivePage(_ a: Args) throws -> String {
        let id = try a.string("page_id")
        try workspace.archivePage(id: id, context: context)
        return "Moved to Trash. The user can restore it from the Trash."
    }

    // MARK: Blocks

    private func appendBlocks(_ a: Args) throws -> String {
        let drafts = MarkdownCodec.parse(try a.string("markdown"))
        guard !drafts.isEmpty else { throw FlotionError.invalid("The markdown produced no blocks.") }
        let position: InsertPosition = a.optString("after_block_id").map { .after($0) } ?? (a.bool("at_start") == true ? .start : .end)
        let blocks = try workspace.insertBlocks(pageID: try a.string("page_id"), drafts, at: position, context: context)
        return json(["inserted_block_ids": .array(blocks.map { .string($0.id) })])
    }

    private func updateBlock(_ a: Args) throws -> String {
        let drafts = MarkdownCodec.parse(try a.string("markdown"))
        guard !drafts.isEmpty else { throw FlotionError.invalid("The markdown produced no blocks. Use delete_block to remove a block.") }
        let blocks = try workspace.replaceBlock(id: try a.string("block_id"), with: drafts, context: context)
        return json(["block_ids": .array(blocks.map { .string($0.id) })])
    }

    private func deleteBlock(_ a: Args) throws -> String {
        try workspace.deleteBlock(id: try a.string("block_id"), context: context)
        return "Deleted."
    }

    // MARK: Diagrams

    private func diagramSource(_ a: Args, format: DiagramFormat) throws -> String? {
        switch format {
        case .html: return a.optString("html")
        case .steps:
            guard let steps = a.raw["steps"] else { return nil }
            if let string = steps.stringValue { return string }
            return String(decoding: try JSONEncoder().encode(steps), as: UTF8.self)
        }
    }

    private func createDiagram(_ a: Args) throws -> String {
        guard let format = DiagramFormat(rawValue: try a.string("format")) else {
            throw FlotionError.invalid("format must be \"steps\" or \"html\".")
        }
        guard let source = try diagramSource(a, format: format) else {
            throw FlotionError.invalid(format == .steps ? "Provide `steps` for a steps diagram." : "Provide `html` for an html diagram.")
        }
        let position: InsertPosition = a.optString("after_block_id").map { .after($0) } ?? .end
        let (diagram, block) = try workspace.createDiagram(
            pageID: try a.string("page_id"), title: try a.string("title"), format: format, source: source,
            height: a.double("height"), at: position, context: context)
        return json(["block_id": .string(block.id), "diagram_id": .string(diagram.id), "height": .double(diagram.height)])
    }

    private func getDiagram(_ a: Args) throws -> String {
        let blockID = try a.string("block_id")
        guard let d = try workspace.diagram(forBlock: blockID) else { throw FlotionError.notFound("diagram for block \(blockID)") }
        return "title: \(d.title)\nformat: \(d.format.rawValue)\nheight: \(Int(d.height))\n\n\(d.source)"
    }

    private func updateDiagram(_ a: Args) throws -> String {
        let blockID = try a.string("block_id")
        guard let existing = try workspace.diagram(forBlock: blockID) else { throw FlotionError.notFound("diagram for block \(blockID)") }
        let format = try a.optString("format").map { raw -> DiagramFormat in
            guard let f = DiagramFormat(rawValue: raw) else { throw FlotionError.invalid("format must be \"steps\" or \"html\".") }
            return f
        }
        let source = try diagramSource(a, format: format ?? existing.format)
        if format != nil, format != existing.format, source == nil {
            throw FlotionError.invalid("Changing the format needs new content in the same call.")
        }
        let d = try workspace.updateDiagram(id: existing.id, title: a.optString("title"), format: format, source: source,
                                            height: a.double("height"), notify: true)
        return json(["block_id": .string(blockID), "diagram_id": .string(d.id), "height": .double(d.height)])
    }

    private func json(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Typed access to tool arguments with errors a model can act on.
struct Args {
    let raw: [String: Value]
    init(_ raw: [String: Value]) { self.raw = raw }

    func has(_ key: String) -> Bool { raw[key] != nil }

    func string(_ key: String) throws -> String {
        guard let value = raw[key]?.stringValue, !value.isEmpty else {
            throw FlotionError.invalid("Missing required argument `\(key)`.")
        }
        return value
    }

    func optString(_ key: String, allowEmpty: Bool = false) -> String? {
        guard let value = raw[key]?.stringValue else { return nil }
        return value.isEmpty && !allowEmpty ? nil : value
    }

    func int(_ key: String) -> Int? {
        raw[key]?.intValue ?? raw[key]?.doubleValue.map { Int($0) }
    }

    func double(_ key: String) -> Double? {
        raw[key]?.doubleValue ?? raw[key]?.intValue.map(Double.init)
    }

    func bool(_ key: String) -> Bool? { raw[key]?.boolValue }
}
