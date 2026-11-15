import AppKit
import FlotionCore
import FlotionEditor
import SwiftUI

/// Hosts the AppKit editor: an NSTableView with one reused row per block.
/// (Spike result: this holds 120 Hz at 5,000 blocks with sub-millisecond keystrokes.)
struct EditorView: NSViewRepresentable {
    let model: AppModel
    /// Changes whenever the model swaps in a different page's editor.
    let generation: Int
    /// Changes whenever a diagram on the open page is edited elsewhere.
    let diagramGeneration: Int

    func makeCoordinator() -> EditorController { EditorController() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let controller = context.coordinator
        controller.onTitleChange = { [model] in model.setTitle($0) }
        controller.onOpenPage = { [model] id in Task { await model.open(id) } }
        controller.titleOfPage = { [model] in model.title(of: $0) }
        controller.diagram = { [model] id in model.diagrams[id] }
        controller.ai = model.ai
        controller.onSelectionChange = { [model] in model.selection = $0 }
        controller.onAskChat = { [model] in model.askChat($0) }
        if controller.generation != generation, let editor = model.editor {
            controller.generation = generation
            controller.diagramGeneration = diagramGeneration
            controller.show(editor, title: model.title)
        } else {
            controller.setTitle(model.title)
            if controller.diagramGeneration != diagramGeneration {
                controller.diagramGeneration = diagramGeneration
                controller.reloadDiagrams()
            }
        }
    }
}

final class EditorTableView: NSTableView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            onWidthChange?()
        }
    }
}

@MainActor
final class EditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let table = EditorTableView()
    private(set) var state: EditorState?
    private var title = ""
    var generation = -1

    var onTitleChange: ((String) -> Void)?
    var onOpenPage: ((String) -> Void)?
    var titleOfPage: (String) -> String = { _ in "Untitled" }
    var diagram: (String) -> Diagram? = { _ in nil }
    var diagramGeneration = 0

    // Inline AI (see EditorController+AI.swift)
    var ai: AIController?
    var onSelectionChange: ((EditorSelection?) -> Void)?
    var onAskChat: ((String) -> Void)?
    var currentSelection: EditorSelection?
    let aiButton = NSButton()
    var inlinePopover: NSPopover?
    var inlineModel: InlineEditModel?

    /// The open "/" menu, if any (see SlashMenu.swift).
    private(set) var slashMenu: SlashMenuPresenter?
    /// Where a "/" is about to be typed, recorded before the edit so the menu opens only for a typed slash.
    private var typedSlashAt: Int?

    /// Exact heights of rows that have been laid out; other rows use an estimate
    /// so a long page paints without measuring every block first.
    private var heights: [String: CGFloat] = [:]
    private var staleRows = IndexSet()
    private var flushScheduled = false
    private var widthChangeScheduled = false
    private static let dragType = NSPasteboard.PasteboardType("app.flotion.block-row")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("block"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.backgroundColor = Theme.page
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.onWidthChange = { [weak self] in self?.widthChanged() }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.page
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 160, right: 0)
        // The slash menu is its own window, so it follows the "/" when the page scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.slashMenu?.reposition() }
        }
    }

    // MARK: Binding

    func show(_ state: EditorState, title: String) {
        let interval = signposter.beginInterval("showPage")
        closeSlashMenu()
        self.state?.onChange = nil
        self.state = state
        self.title = title
        heights.removeAll(keepingCapacity: true)
        state.onChange = { [weak self] change in self?.apply(change) }
        table.reloadData()
        table.scrollRowToVisible(0)
        if title.isEmpty, state.blocks.count == 1, state.blocks[0].runs.isEmpty {
            focusTitle()
        }
        signposter.endInterval("showPage", interval)
    }

    func setTitle(_ newTitle: String) {
        guard newTitle != title else { return }
        title = newTitle
        if let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TitleCell, cell.textView.string != newTitle {
            cell.configure(title: newTitle, controller: self)
        }
    }

    private func apply(_ change: EditorChange) {
        guard let state else { return }
        switch change {
        case .structure:
            clearSelection()
            closeSlashMenu()
            table.reloadData()
        case .rows(let indexes):
            for i in indexes where state.blocks.indices.contains(i) {
                let row = i + 1
                heights[state.blocks[i].id] = nil
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
                    configure(cell, for: state.blocks[i], index: i)
                }
                staleRows.insert(row)
                // Numbers of the list items below may have changed too.
                var j = i + 1
                while j < state.blocks.count, state.blocks[j].type == .numbered {
                    if let cell = table.view(atColumn: 0, row: j + 1, makeIfNecessary: false) { configure(cell, for: state.blocks[j], index: j) }
                    j += 1
                }
            }
            flushHeights()
        }
        applyFocus()
    }

    private func applyFocus() {
        guard let state, let focus = state.focus, let i = state.index(of: focus.blockID) else { return }
        let row = i + 1
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TextBlockCell else { return }
        let tv = cell.blockTextView
        if table.window?.firstResponder !== tv { table.window?.makeFirstResponder(tv) }
        let location = min(focus.offset, (tv.string as NSString).length)
        if tv.selectedRange() != NSRange(location: location, length: 0) {
            tv.setSelectedRange(NSRange(location: location, length: 0))
        }
    }

    private func focusTitle() {
        guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TitleCell else { return }
        DispatchQueue.main.async { [weak table] in table?.window?.makeFirstResponder(cell.textView) }
    }

    func toggleChecked(_ id: String) { state?.toggleChecked(id) }

    /// A diagram's content or height changed: refresh its rows in place.
    func reloadDiagrams() {
        guard let state else { return }
        for (i, block) in state.blocks.enumerated() where block.type == .diagram {
            heights[block.id] = nil
            staleRows.insert(i + 1)
            if let cell = table.view(atColumn: 0, row: i + 1, makeIfNecessary: false) { configure(cell, for: block, index: i) }
        }
        flushHeights()
    }

    // MARK: Heights

    private func textWidth(for block: Block) -> CGFloat {
        Theme.contentColumn(in: table.bounds.width).width - Theme.textInset(for: block) - (block.type == .code ? 16 : 0)
    }

    private func exactHeight(_ block: Block) -> CGFloat {
        let style = Theme.style(for: block.type)
        guard block.type.hasText else { return staticHeight(block) }
        return style.top + RichText.height(of: RichText.attributed(block), width: textWidth(for: block), lineHeight: style.lineHeight) + style.bottom
    }

    private func staticHeight(_ block: Block) -> CGFloat {
        switch block.type {
        case .divider: 25
        case .diagram: (block.props.diagramID.flatMap(diagram)?.height ?? 120) + DiagramBlockCell.chromeHeight
        default: 36
        }
    }

    private func estimatedHeight(_ block: Block) -> CGFloat {
        let style = Theme.style(for: block.type)
        guard block.type.hasText else { return staticHeight(block) }
        let perLine = max(12, textWidth(for: block) / (style.font.pointSize * 0.52))
        let text = block.plainText
        var lines = max(1, ceil(CGFloat(text.utf16.count) / perLine))
        if block.type == .code { lines = max(lines, CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count)) }
        return style.top + lines * style.lineHeight + style.bottom
    }

    private var titleHeight: CGFloat {
        let style = Theme.titleStyle
        let text = NSAttributedString(string: title, attributes: RichText.attributes(style: style))
        let width = Theme.contentColumn(in: table.bounds.width).width
        return style.top + RichText.height(of: text, width: width, lineHeight: style.lineHeight) + style.bottom
    }

    /// Measures a row that is about to be shown; if the estimate was off, corrects it after this pass.
    private func settleHeight(_ block: Block, row: Int) {
        guard heights[block.id] == nil else { return }
        let exact = exactHeight(block)
        heights[block.id] = exact
        if abs(exact - estimatedHeight(block)) > 0.5 {
            staleRows.insert(row)
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.async { [weak self] in self?.flushHeights() }
        }
    }

    private func flushHeights() {
        flushScheduled = false
        guard !staleRows.isEmpty else { return }
        let rows = staleRows.filteredIndexSet { $0 < table.numberOfRows }
        staleRows.removeAll()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.noteHeightOfRows(withIndexesChanged: rows)
        NSAnimationContext.endGrouping()
    }

    /// The table reports width changes from inside its own layout pass, where calling
    /// back into it is not allowed, so the re-measure runs on the next turn of the run loop.
    private func widthChanged() {
        guard !widthChangeScheduled else { return }
        widthChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            widthChangeScheduled = false
            slashMenu?.reposition()
            guard state != nil, table.numberOfRows > 0 else { return }
            heights.removeAll(keepingCapacity: true)
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
            NSAnimationContext.endGrouping()
        }
    }

    // MARK: Table data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { (state?.blocks.count ?? 0) + (state == nil ? 0 : 1) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let state else { return 24 }
        if row == 0 { return titleHeight }
        let block = state.blocks[row - 1]
        return heights[block.id] ?? estimatedHeight(block)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let state else { return nil }
        if row == 0 {
            let cell: TitleCell = dequeue("title")
            cell.configure(title: title, controller: self)
            return cell
        }
        let block = state.blocks[row - 1]
        settleHeight(block, row: row)
        let cell: NSView = block.type.hasText ? dequeue("text") as TextBlockCell
            : block.type == .diagram ? dequeue("diagram") as DiagramBlockCell : dequeue("static") as StaticBlockCell
        configure(cell, for: block, index: row - 1)
        return cell
    }

    private func dequeue<Cell: NSTableCellView>(_ name: String) -> Cell {
        let id = NSUserInterfaceItemIdentifier(name)
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
        let cell = Cell(frame: NSRect(x: 0, y: 0, width: table.bounds.width, height: 30))
        cell.identifier = id
        return cell
    }

    private func configure(_ view: NSView, for block: Block, index: Int) {
        if let cell = view as? TextBlockCell {
            cell.configure(block, number: block.type == .numbered ? (state?.listNumber(at: index) ?? 1) : 0, controller: self)
        } else if let cell = view as? DiagramBlockCell {
            cell.configure(block, diagram: block.props.diagramID.flatMap(diagram))
        } else if let cell = view as? StaticBlockCell {
            cell.configure(block, title: block.type == .pageLink ? titleOfPage(block.props.targetPageID ?? "") : "", controller: self)
        }
    }

    // Drag a row by the margin beside it to reorder.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row > 0 else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above && row >= 1 ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let source = info.draggingPasteboard.string(forType: Self.dragType).flatMap(Int.init) else { return false }
        state?.move(from: source - 1, to: row - 1)
        return true
    }

    // MARK: Text view delegate

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        typedSlashAt = replacementString == "/" ? range.location : nil
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? BlockTextView, !tv.hasMarkedText() else { return }
        let typedSlash = typedSlashAt
        typedSlashAt = nil
        if tv.isTitle {
            title = tv.string
            onTitleChange?(tv.string)
            staleRows.insert(0)
            flushHeights()
            return
        }
        guard let state, state.index(of: tv.blockID) != nil else { return }
        let caret = tv.selectedRange().location
        // A Markdown shortcut may restyle the row; `apply(.rows)` has then already refreshed it.
        let converted = state.setRuns(RichText.runs(from: tv.attributedString()), for: tv.blockID, caret: caret)
        if !converted, let j = state.index(of: tv.blockID) {
            let exact = exactHeight(state.blocks[j])
            if heights[tv.blockID] != exact {
                heights[tv.blockID] = exact
                staleRows.insert(j + 1)
                flushHeights()
            }
        }
        if slashMenu != nil {
            refreshSlashMenu(in: tv)
        } else if let at = typedSlash, caret == at + 1, let j = state.index(of: tv.blockID),
                  state.blocks[j].type.hasText, state.blocks[j].type != .code, SlashMenu.opens(in: tv.string, slashAt: at) {
            openSlashMenu(in: tv, anchor: at)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? BlockTextView else { return }
        selectionChanged(in: tv)
        if slashMenu != nil { refreshSlashMenu(in: tv) }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let tv = textView as? BlockTextView, let state else { return false }
        let range = tv.selectedRange()

        if tv.isTitle {
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.insertTab(_:)) {
                if let first = state.blocks.first(where: { $0.type.hasText }) {
                    state.focus = Focus(blockID: first.id, offset: 0)
                    applyFocus()
                } else {
                    state.insertBlock(Block(type: .paragraph), after: nil)
                }
                return true
            }
            return false
        }

        if slashMenu?.session.blockID == tv.blockID, let handled = slashMenuKey(selector) { return handled }

        let id = tv.blockID
        let isCode = state.index(of: id).map { state.blocks[$0].type == .code } ?? false
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if isCode { return false }
            if range.length > 0 { tv.insertText("", replacementRange: range) }
            state.split(id, at: tv.selectedRange().location)
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard range.location == 0, range.length == 0 else { return false }
            state.deleteBackwardAtStart(id)
            return true
        case #selector(NSResponder.insertTab(_:)):
            if isCode { tv.insertText("    ", replacementRange: range); return true }
            state.indent(id)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            state.outdent(id)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard tv.caretIsOnEdgeLine(first: true) else { return false }
            if let previous = state.neighbour(of: id, direction: -1), let i = state.index(of: previous) {
                state.focus = Focus(blockID: previous, offset: state.blocks[i].runs.utf16Count)
                applyFocus()
            } else {
                focusTitle()
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard tv.caretIsOnEdgeLine(first: false), let next = state.neighbour(of: id, direction: 1) else { return false }
            state.focus = Focus(blockID: next, offset: 0)
            applyFocus()
            return true
        default:
            return false
        }
    }

    // MARK: Slash menu

    private func openSlashMenu(in tv: BlockTextView, anchor: Int) {
        var session = SlashMenuSession(blockID: tv.blockID, anchor: anchor, commands: SlashMenu.commands(includingAI: ai != nil))
        guard session.update(text: tv.string, caret: tv.selectedRange().location) else { return }
        let menu = SlashMenuPresenter(session: session, textView: tv) { [weak self, weak tv] command in
            guard let self, let tv else { return }
            chooseSlashCommand(command, in: tv)
        }
        menu.model.onDismiss = { [weak self] in self?.closeSlashMenu() }
        slashMenu = menu
        menu.show()
    }

    /// Follows an edit or caret move in the menu's block; closes the menu when the "/" query ends.
    private func refreshSlashMenu(in tv: BlockTextView) {
        guard let menu = slashMenu, menu.session.blockID == tv.blockID else { return }
        var session = menu.session
        let selection = tv.selectedRange()
        guard selection.length == 0, session.update(text: tv.string, caret: selection.location) else {
            closeSlashMenu()
            return
        }
        if session != menu.session { menu.update(session) }
    }

    func closeSlashMenu() {
        slashMenu?.close()
        slashMenu = nil
    }

    /// Keys the menu takes while it is open; nil lets the editor handle the key as usual.
    private func slashMenuKey(_ selector: Selector) -> Bool? {
        guard let menu = slashMenu else { return nil }
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            var session = menu.session
            session.move(selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1)
            menu.update(session)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // With nothing matching, Return closes the menu and does what it normally does.
            guard let command = menu.session.selectedCommand else {
                closeSlashMenu()
                return nil
            }
            menu.model.onChoose?(command)
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            closeSlashMenu()
            return true
        default:
            return nil
        }
    }

    /// Removes the typed "/query", then turns the block into the chosen type or opens the AI prompt.
    func chooseSlashCommand(_ command: SlashCommand, in tv: BlockTextView) {
        guard let menu = slashMenu, let state else { return }
        let typed = menu.session.typedRange
        closeSlashMenu()
        let id = tv.blockID
        let length = (tv.string as NSString).length
        guard typed.lowerBound < length else { return }
        tv.insertText("", replacementRange: NSRange(location: typed.lowerBound, length: min(typed.count, length - typed.lowerBound)))
        guard let i = state.index(of: id) else { return }
        switch command.action {
        case .askAI:
            beginInlineEdit(blockID: id, range: NSRange(location: typed.lowerBound, length: 0), text: "")
        case .turnInto(let type):
            if type == .divider, !state.blocks[i].runs.isEmpty {
                // A line with text keeps it; the divider goes below.
                state.insertBlock(Block(type: .divider), after: id)
                state.focus = Focus(blockID: id, offset: typed.lowerBound)
                applyFocus()
            } else if type == state.blocks[i].type {
                apply(.rows([i]))
            } else {
                state.setType(type, for: id)
            }
        }
    }
}
