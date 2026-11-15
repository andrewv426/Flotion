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

    /// The new content a call carries, if any: Flow `source`, or an `html` document.
    private func diagramContent(_ a: Args) throws -> (format: DiagramFormat, source: String)? {
        if a.has("steps") || a.optString("format") == "steps" {
            throw FlotionError.invalid("The steps format is no longer created. Write the diagram as Flow in `source`.")
        }
        switch (a.optString("source"), a.optString("html")) {
        case (.some, .some): throw FlotionError.invalid("Provide either `source` or `html`, not both.")
        case (let source?, nil): return (.flow, source)
        case (nil, let html?): return (.html, html)
        case (nil, nil): return nil
        }
    }

    /// What the caller gets back: enough to see the diagram came out the size and shape it meant.
    private func diagramResult(blockID: String, _ diagram: Diagram) -> String {
        var out: [String: Value] = ["block_id": .string(blockID), "diagram_id": .string(diagram.id), "format": .string(diagram.format.rawValue)]
        if diagram.format == .flow, let scene = try? FlowScene(source: diagram.source) {
            out["nodes"] = .int(scene.nodes.count)
            out["edges"] = .int(scene.edges.count)
            out["steps"] = .int(scene.stepped ? scene.steps.count : 0)
            out["size"] = .string("\(Int(scene.w))x\(Int(scene.h))")
        } else {
            out["height"] = .double(diagram.height)
        }
        return json(.object(out))
    }

    private func createDiagram(_ a: Args) throws -> String {
        guard let content = try diagramContent(a) else {
            throw FlotionError.invalid("Provide the diagram as Flow in `source`.")
        }
        let position: InsertPosition = a.optString("after_block_id").map { .after($0) } ?? .end
        let (diagram, block) = try workspace.createDiagram(
            pageID: try a.string("page_id"), title: try a.string("title"), format: content.format, source: content.source,
            height: a.double("height"), at: position, context: context)
        return diagramResult(blockID: block.id, diagram)
    }

    private func getDiagram(_ a: Args) throws -> String {
        let blockID = try a.string("block_id")
        guard let d = try workspace.diagram(forBlock: blockID) else { throw FlotionError.notFound("diagram for block \(blockID)") }
        let height = d.format == .flow ? "" : "\nheight: \(Int(d.height))"
        return "title: \(d.title)\nformat: \(d.format.rawValue)\(height)\n\n\(d.source)"
    }

    private func updateDiagram(_ a: Args) throws -> String {
        let blockID = try a.string("block_id")
        guard let existing = try workspace.diagram(forBlock: blockID) else { throw FlotionError.notFound("diagram for block \(blockID)") }
        var content = try diagramContent(a)
        if let edits = a.raw["edits"]?.arrayValue {
            guard content == nil else { throw FlotionError.invalid("Provide `edits` or a whole new `source`, not both.") }
            guard existing.format == .flow else {
                throw FlotionError.invalid("`edits` only work on Flow diagrams; this one is \(existing.format.rawValue). Send a whole new `source` instead.")
            }
            content = (.flow, try Self.apply(edits, to: existing.source))
        }
        let d = try workspace.updateDiagram(id: existing.id, title: a.optString("title"), format: content?.format, source: content?.source,
                                            height: a.double("height"), notify: true)
        return diagramResult(blockID: blockID, d)
    }

    /// Replaces each `old` with its `new`, in order. An `old` must match exactly once, so an edit can never land somewhere unintended.
    private static func apply(_ edits: [Value], to source: String) throws -> String {
        var text = source
        for (i, edit) in edits.enumerated() {
            guard let old = edit.objectValue?["old"]?.stringValue, !old.isEmpty, let new = edit.objectValue?["new"]?.stringValue else {
                throw FlotionError.invalid("Edit \(i + 1) needs `old` (the exact text to find) and `new` (its replacement).")
            }
            let matches = text.components(separatedBy: old).count - 1
            guard matches == 1 else {
                throw FlotionError.invalid(matches == 0
                    ? "Edit \(i + 1): `old` was not found. Read the source with get_diagram and copy the text exactly."
                    : "Edit \(i + 1): `old` appears \(matches) times. Include more of the line so it matches once.")
            }
            text = text.replacingOccurrences(of: old, with: new)
        }
        return text
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
