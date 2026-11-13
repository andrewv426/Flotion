import AppKit
import FlotionAI
import FlotionCore
import FlotionEditor
import Observation
import os

let signposter = OSSignposter(subsystem: "app.flotion.Flotion", category: "Performance")

/// App-wide state: the workspace, the page tree and the open page's editor.
/// Database work happens off the main actor; this type only ever holds value snapshots.
@MainActor @Observable
final class AppModel {
    let workspace: Workspace?
    var startupError: String?

    var pages: [Page] = []
    var trash: [Page] = []
    var selectedPageID: String?
    var title: String = ""
    var expanded: Set<String> = []
    var showQuickFind = false
    /// Text selected in the editor; the AI panel and "Edit with AI" act on it.
    var selection: EditorSelection?
    @ObservationIgnored private(set) var ai: AIController?

    /// Not observed: the AppKit editor listens to it directly.
    @ObservationIgnored private(set) var editor: EditorState?
    /// Bumped whenever `editor` is replaced, so the editor view knows to rebind.
    var editorGeneration = 0
    /// Diagrams used by the open page, and a counter bumped when any of them changes.
    @ObservationIgnored private(set) var diagrams: [String: Diagram] = [:]
    var diagramGeneration = 0

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var titleTask: Task<Void, Never>?
    @ObservationIgnored private var changeToken: ChangeNotifier.ObservationToken?

    init() {
        let url = ProcessInfo.processInfo.environment["FLOTION_DB"].map { URL(fileURLWithPath: $0) } ?? Flotion.defaultDatabaseURL
        do {
            workspace = try Workspace(url: url)
        } catch {
            workspace = nil
            startupError = "Flotion could not open its database at \(url.path): \(error.localizedDescription)"
        }
        ai = workspace.map { AIController(workspace: $0) }
    }

    // MARK: Navigation and export

    /// Opens a page and expands its ancestors so it is visible in the sidebar.
    func reveal(_ pageID: String) async {
        var cursor = pages.first { $0.id == pageID }?.parentID
        while let id = cursor {
            expanded.insert(id)
            cursor = pages.first { $0.id == id }?.parentID
        }
        await open(pageID)
    }

    func exportMarkdown() {
        guard let editor else { return }
        let name = title.isEmpty ? "Untitled" : title
        let markdown = "# \(name)\n\n" + MarkdownCodec.render(editor.blocks) + "\n"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Assistant

    /// What the assistant is told about the user's current view.
    func pageContext() -> PageContext? {
        guard let editor, let pageID = selectedPageID else { return nil }
        return PageContext(pageID: pageID, title: title, markdown: MarkdownCodec.render(editor.blocks), selection: selection?.text)
    }

    /// Sends a chat message. Pending edits are saved first, so the model reads what the user sees.
    func sendChat(_ text: String) async {
        guard let ai else { return }
        await flush()
        ai.chat.send(text, context: pageContext())
    }

    /// Opens the panel and sends (used by "Turn into a diagram").
    func askChat(_ text: String) {
        ai?.isPanelOpen = true
        Task { await sendChat(text) }
    }

    func start() async {
        guard let workspace, pages.isEmpty else { return }
        let state = signposter.beginInterval("launch")
        await reloadPages()
        if pages.isEmpty {
            _ = try? await Task.detached { try Self.createWelcome(in: workspace) }.value
            await reloadPages()
        }
        let last = UserDefaults.standard.string(forKey: "lastPageID")
        let target = pages.first { $0.id == last } ?? pages.first { $0.parentID == nil }
        if let target { await open(target.id) }
        signposter.endInterval("launch", state)

        changeToken = ChangeNotifier.observe { [weak self] in
            Task { @MainActor in await self?.refreshFromDisk() }
        }
    }

    // MARK: Page tree

    func children(of parentID: String?) -> [Page] {
        pages.filter { $0.parentID == parentID }.sorted { $0.position < $1.position }
    }

    func title(of pageID: String) -> String {
        let t = pages.first { $0.id == pageID }?.title ?? ""
        return t.isEmpty ? "Untitled" : t
    }

    func reloadPages() async {
        guard let workspace else { return }
        let result = try? await Task.detached { (try workspace.pages(), try workspace.archivedPages()) }.value
        if let result {
            pages = result.0
            trash = result.1
        }
    }

    func open(_ pageID: String) async {
        guard let workspace, pageID != selectedPageID || editor == nil else { return }
        let state = signposter.beginInterval("openPage")
        await flush()
        guard let blocks = try? await Task.detached(operation: { try workspace.blocks(pageID: pageID) }).value else { return }
        diagrams = await loadDiagrams(for: blocks)
        let editor = EditorState(pageID: pageID, blocks: blocks)
        editor.onDirty = { [weak self] in self?.scheduleSave() }
        self.editor = editor
        selectedPageID = pageID
        title = pages.first { $0.id == pageID }?.title ?? ""
        editorGeneration += 1
        UserDefaults.standard.set(pageID, forKey: "lastPageID")
        if editor.hasPendingChanges { scheduleSave() }
        signposter.endInterval("openPage", state)
    }

    func newPage(under parentID: String? = nil) async {
        guard let workspace else { return }
        guard let page = try? await Task.detached(operation: { try workspace.createPage(title: "", parentID: parentID) }).value else { return }
        if let parentID { expanded.insert(parentID) }
        await reloadPages()
        await open(page.id)
    }

    func setTitle(_ newTitle: String) {
        guard let workspace, let id = selectedPageID, newTitle != title else { return }
        title = newTitle
        if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].title = newTitle }
        titleTask?.cancel()
        titleTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            _ = try? await Task.detached { try workspace.updatePage(id: id, title: newTitle) }.value
        }
    }

    func archive(_ pageID: String) async {
        guard let workspace else { return }
        if pageID == selectedPageID { await flush() }
        _ = try? await Task.detached { try workspace.archivePage(id: pageID) }.value
        await reloadPages()
        if !pages.contains(where: { $0.id == selectedPageID }) {
            editor = nil
            selectedPageID = nil
            editorGeneration += 1
            if let next = pages.first(where: { $0.parentID == nil }) { await open(next.id) }
        }
    }

    func restore(_ pageID: String) async {
        guard let workspace else { return }
        _ = try? await Task.detached { try workspace.restorePage(id: pageID) }.value
        await reloadPages()
        await open(pageID)
    }

    func deleteForever(_ pageID: String) async {
        guard let workspace else { return }
        _ = try? await Task.detached { try workspace.deletePagePermanently(id: pageID) }.value
        await reloadPages()
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    /// Writes everything pending for the open page. Safe to call at any time.
    func flush() async {
        guard let workspace, let editor, editor.hasPendingChanges else { return }
        let (upserts, deletes) = editor.takePendingChanges()
        let pageID = editor.pageID
        let state = signposter.beginInterval("save")
        _ = try? await Task.detached { try workspace.saveEditorChanges(pageID: pageID, upserts: upserts, deletes: deletes) }.value
        signposter.endInterval("save", state)
    }

    /// Synchronous flush for app termination, when there is no time to await.
    func flushNow() {
        guard let workspace, let editor, editor.hasPendingChanges else { return }
        let (upserts, deletes) = editor.takePendingChanges()
        try? workspace.saveEditorChanges(pageID: editor.pageID, upserts: upserts, deletes: deletes)
    }

    // MARK: Changes made by another process (MCP clients, the in-app AI)

    func refreshFromDisk() async {
        guard let workspace else { return }
        await reloadPages()
        guard let editor, let pageID = selectedPageID else { return }
        guard pages.contains(where: { $0.id == pageID }) else {
            self.editor = nil
            selectedPageID = nil
            editorGeneration += 1
            return
        }
        title = pages.first { $0.id == pageID }?.title ?? title
        if let fresh = try? await Task.detached(operation: { try workspace.blocks(pageID: pageID) }).value {
            let updated = await loadDiagrams(for: fresh)
            let diagramsChanged = updated != diagrams
            diagrams = updated
            editor.applyRemote(fresh)
            if diagramsChanged { diagramGeneration += 1 }
        }
    }

    private func loadDiagrams(for blocks: [Block]) async -> [String: Diagram] {
        guard let workspace else { return [:] }
        let ids = blocks.compactMap { $0.type == .diagram ? $0.props.diagramID : nil }
        guard !ids.isEmpty else { return [:] }
        return await Task.detached {
            var out: [String: Diagram] = [:]
            for id in ids { if let d = try? workspace.diagram(id: id) { out[id] = d } }
            return out
        }.value
    }

    // MARK: First run

    nonisolated static func createWelcome(in workspace: Workspace) throws {
        let markdown = """
            Flotion is a quiet place for notes. A few things to try:

            - Type `/` on an empty line to pick a block type
            - Or use Markdown: `#` for a heading, `-` for a list, `[]` for a to-do, `>` for a quote
            - **Tab** and **Shift-Tab** indent and outdent list items
            - Drag a block by the space to its left to reorder it

            ## Connect an AI

            - [ ] Open Settings and connect Claude
            - [ ] Ask it to add a step-by-step diagram to a page

            ---

            Everything is saved as you type.
            """
        try workspace.createPage(title: "Getting Started", icon: "👋", blocks: MarkdownCodec.parse(markdown))
    }
}
