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
    weak var editor: EditorController?
    private var lastWidth: CGFloat = 0
    private weak var diagramMouseTarget: NSView?

    override func mouseDown(with event: NSEvent) {
        diagramMouseTarget = nil
        let point = convert(event.locationInWindow, from: nil)
        // AppKit may give a diagram click to the table for row selection.
        guard let (cell, target) = diagramHit(at: point, event: event) else {
            super.mouseDown(with: event)
            return
        }
        if let webView = cell.webView, target === webView || target.isDescendant(of: webView) {
            diagramMouseTarget = webView
            window?.makeFirstResponder(webView)
            webView.mouseDown(with: event)
        } else {
            target.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let target = diagramMouseTarget {
            target.mouseDragged(with: event)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let target = diagramMouseTarget {
            diagramMouseTarget = nil
            target.mouseUp(with: event)
        } else {
            super.mouseUp(with: event)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            onWidthChange?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return diagramHit(at: convert(point, from: superview), event: NSApp.currentEvent)?.target ?? hit
    }

    private func diagramHit(at point: NSPoint, event: NSEvent?) -> (cell: DiagramBlockCell, target: NSView)? {
        let index = row(at: point)
        guard index > 0,
              let cell = view(atColumn: 0, row: index, makeIfNecessary: false) as? DiagramBlockCell else { return nil }
        let localPoint = cell.convert(point, from: self)
        guard cell.containsBlock(at: localPoint) else { return nil }
        if !cell.actionsButton.isHidden, cell.actionsButton.frame.contains(localPoint) {
            return (cell, cell.actionsButton)
        }
        let modifiers = event?.modifierFlags ?? []
        if modifiers.contains([.command, .shift]) || modifiers.contains(.control) || event?.type == .rightMouseDown {
            return (cell, cell)
        }
        guard let target = cell.interactiveHit(at: localPoint) else { return (cell, cell) }
        // Keep both scrolling and momentum on AppKit's native responder chain.
        return (cell, event?.type == .scrollWheel ? self : target)
    }

    override func keyDown(with event: NSEvent) {
        if editor?.handleDiagramKey(event) != true { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        editor?.clearDiagramSelection()
        return true
    }
}

@MainActor
final class EditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let table = EditorTableView()
    private(set) var state: EditorState?
    private(set) var selectedDiagramID: String?
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

    /// Measured heights, by block. A row is measured when the table asks for its height, so the
    /// table never has to be corrected about a row it is showing (see `tableView(_:heightOfRow:)`).
    private var heights: [String: CGFloat] = [:]
    private var staleRows = IndexSet()
    private var flushScheduled = false
    /// Whether the next flush keeps the rows on screen where they are (see `noteHeights`).
    private var holdPositionOnFlush = false
    /// Rows the table was given an estimate for, because measuring them all at once would stall
    /// the page. They are measured a few at a time afterwards (see `settlePendingRows`).
    private var pendingRows = IndexSet()
    private var settleScheduled = false
    /// The rows on screen and about a screenful either side, as of the last scroll. These are
    /// always measured, whatever the time already spent.
    private var nearRows = 0..<0
    private var resolveAheadScheduled = false
    private static let lookaheadRows = 60
    private var measureWindowStart = 0.0
    private var measureSpent = 0.0
    /// Until this time only `nearRows` are measured and settling waits: a page is opening, or the
    /// width is changing (on every frame, while a window is dragged wider).
    private var busyUntil = 0.0
    /// Measuring time allowed in any `measureWindow`, both in seconds: half a 120 Hz frame.
    private static let measureSlice = 0.004
    private static let measureWindow = 0.008
    private var widthChangeScheduled = false
    private static let dragType = NSPasteboard.PasteboardType("app.flotion.block-row")
    /// Cells from earlier pages, detached and kept for the next page's rows (see `dequeue`), and
    /// how many cells have been built; the self-test reads the count.
    private var spareCells: [NSUserInterfaceItemIdentifier: [NSTableCellView]] = [:]
    private static let maxSpareCellsPerKind = 40
    private(set) var cellsCreated = 0

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
        table.editor = self
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.onWidthChange = { [weak self] in self?.widthChanged() }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.page
        // The slash menu is its own window, so it follows the "/" when the page scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.slashMenu?.reposition()
                self?.refreshNearRows()
                self?.scheduleResolveAhead()
            }
        }
        // The space after the last block follows the window's height.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportChanged() }
        }
    }

    // MARK: Space after the last block

    /// The row after the last block: empty space that can be scrolled into view and clicked to type.
    var endRow: Int { (state?.blocks.count ?? 0) + 1 }
    private var lastEndSpace: CGFloat = 0

    /// Half the visible height, so the last line can sit mid-window while typing, as in Notion.
    /// (A scroll-view content inset would do the same, but AppKit replaces it with its own
    /// automatic insets under the toolbar, so the space is a real row instead.)
    var endSpaceHeight: CGFloat { max(Theme.minimumEndSpace, (scrollView.contentView.bounds.height / 2).rounded()) }

    private func viewportChanged() {
        let height = endSpaceHeight
        guard abs(height - lastEndSpace) > 0.5, state != nil else { return }
        lastEndSpace = height
        staleRows.insert(endRow)
        flushHeights()
    }

    /// Clicked below the last block.
    func focusEnd() {
        clearSelection()
        state?.focusEnd()
    }

    // MARK: Binding

    func show(_ state: EditorState, title: String) {
        let interval = signposter.beginInterval("showPage")
        closeSlashMenu()
        clearDiagramSelection()
        self.state?.onChange = nil
        self.state = state
        self.title = title
        heights.removeAll(keepingCapacity: true)
        pendingRows.removeAll()
        // The page opens at its top. Its first screenful is measured before it is drawn (no row is
        // shorter than 30 points); the rest of what the table asks about waits until it is on screen.
        nearRows = 0..<max(30, Int(scrollView.contentView.bounds.height / 30) + 2)
        busyUntil = CACurrentMediaTime() + 0.05
        state.onChange = { [weak self] change in self?.apply(change) }
        collectCellsForReuse()
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
            if let id = selectedDiagramID, !isDiagramBlock(id) { clearDiagramSelection() }
            // Row numbers change, and the table asks again for every height it needs.
            pendingRows.removeAll()
            table.reloadData()
        case .rows(let indexes):
            if let id = selectedDiagramID, !isDiagramBlock(id) { clearDiagramSelection() }
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

    // MARK: Diagram selection

    private func isDiagramBlock(_ id: String) -> Bool {
        guard let state, let i = state.index(of: id) else { return false }
        return state.blocks[i].type == .diagram
    }

    private func setDiagramSelection(_ id: String?) {
        let previous = selectedDiagramID
        guard id != previous else { return }
        selectedDiagramID = id
        for blockID in [previous, id].compactMap({ $0 }) {
            guard let i = state?.index(of: blockID),
                  let cell = table.view(atColumn: 0, row: i + 1, makeIfNecessary: false) as? DiagramBlockCell else { continue }
            cell.isBlockSelected = blockID == id
        }
    }

    func selectDiagram(_ id: String) -> Bool {
        guard let state, isDiagramBlock(id),
              table.window?.makeFirstResponder(table) == true else { return false }
        clearSelection()
        closeSlashMenu()
        state.focus = nil
        setDiagramSelection(id)
        return true
    }

    func clearDiagramSelection() { setDiagramSelection(nil) }

    func diagramMenu(for id: String) -> NSMenu? {
        guard selectDiagram(id) else { return nil }
        let menu = NSMenu()
        let delete = NSMenuItem(title: "Delete Diagram", action: #selector(deleteDiagramFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = id
        menu.addItem(delete)
        return menu
    }

    @objc private func deleteDiagramFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        deleteDiagram(id)
    }

    private func deleteDiagram(_ id: String) {
        guard isDiagramBlock(id) else { return }
        clearDiagramSelection()
        state?.delete(id)
    }

    func handleDiagramKey(_ event: NSEvent) -> Bool {
        guard let id = selectedDiagramID, let state,
              event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty else { return false }
        switch event.specialKey {
        case .backspace, .delete, .deleteForward:
            deleteDiagram(id)
        case .upArrow:
            moveFromBlock(id, direction: -1)
        case .downArrow:
            moveFromBlock(id, direction: 1)
        case _ where event.charactersIgnoringModifiers == "\u{1B}":
            clearDiagramSelection()
            if let next = state.neighbour(of: id, direction: -1) {
                focusBlock(next, direction: -1)
            } else if let next = state.neighbour(of: id, direction: 1) {
                focusBlock(next, direction: 1)
            } else {
                focusTitle()
            }
        default:
            return false
        }
        return true
    }

    @discardableResult
    private func moveFromBlock(_ id: String, direction: Int) -> Bool {
        if let next = state?.neighbour(of: id, direction: direction, where: { $0.hasText || $0 == .diagram }) {
            focusBlock(next, direction: direction)
        } else if direction < 0 {
            focusTitle()
        } else {
            return false
        }
        return true
    }

    private func focusBlock(_ id: String, direction: Int) {
        guard let state, let i = state.index(of: id) else { return }
        if state.blocks[i].type == .diagram {
            if selectDiagram(id) { table.scrollRowToVisible(i + 1) }
        } else {
            state.focus = Focus(blockID: id, offset: direction < 0 ? state.blocks[i].runs.utf16Count : 0)
            applyFocus()
        }
    }

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
        case .diagram: DiagramBlockCell.rowHeight(for: block.props.diagramID.flatMap(diagram),
                                                  width: Theme.contentColumn(in: table.bounds.width).width - CGFloat(block.depth) * Theme.indentStep)
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

    /// Measures a block and remembers the result, counting the time against `measureSlice`.
    private func measuredHeight(_ block: Block) -> CGFloat {
        let start = CACurrentMediaTime()
        let exact = exactHeight(block)
        measureSpent += CACurrentMediaTime() - start
        heights[block.id] = exact
        return exact
    }

    /// Whether there is time left to measure a row away from the screen. When the table asks for
    /// hundreds of heights in one go (a page opening, the width changing), the rest get an estimate.
    private func canMeasureFarRow() -> Bool {
        let now = CACurrentMediaTime()
        guard now >= busyUntil else { return false }
        if now - measureWindowStart > Self.measureWindow {
            measureWindowStart = now
            measureSpent = 0
        }
        return measureSpent < Self.measureSlice
    }

    private func refreshNearRows() {
        let visible = table.rows(in: table.visibleRect)
        let margin = max(visible.length, 20)
        nearRows = max(0, visible.location - margin)..<(visible.location + visible.length + margin)
    }

    /// Measures the rows that were given an estimate, nearest the screen first, a slice at a time,
    /// so every row has its real height well before it can be scrolled into view.
    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        let wait = max(0, busyUntil - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.settlePendingRows() }
    }

    private func settlePendingRows() {
        settleScheduled = false
        guard let state, !pendingRows.isEmpty else { return }
        guard CACurrentMediaTime() >= busyUntil else { return scheduleSettle() }
        let visible = table.rows(in: table.visibleRect)
        let centre = visible.location + visible.length / 2
        let start = CACurrentMediaTime()
        var changed = IndexSet()
        while CACurrentMediaTime() - start < Self.measureSlice {
            let below = pendingRows.integerGreaterThanOrEqualTo(centre), above = pendingRows.integerLessThan(centre)
            guard let row = [below, above].compactMap({ $0 }).min(by: { abs($0 - centre) < abs($1 - centre) }) else { break }
            pendingRows.remove(row)
            guard state.blocks.indices.contains(row - 1) else { continue }
            let block = state.blocks[row - 1]
            guard heights[block.id] == nil else { continue }
            if abs(measuredHeight(block) - estimatedHeight(block)) > 0.5 { changed.insert(row) }
        }
        noteHeights(changed, holdingPosition: true)
        if !pendingRows.isEmpty { scheduleSettle() }
    }

    /// A row that is about to be shown with an estimate still standing (it came on screen before
    /// `settlePendingRows` reached it): measures it and corrects the table after this pass.
    private func settleHeight(_ block: Block, row: Int) {
        guard heights[block.id] == nil else { return }
        pendingRows.remove(row)
        if abs(measuredHeight(block) - estimatedHeight(block)) > 0.5 {
            staleRows.insert(row)
            holdPositionOnFlush = true
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.async { [weak self] in self?.flushHeights() }
        }
    }

    private func flushHeights() {
        flushScheduled = false
        let hold = holdPositionOnFlush
        holdPositionOnFlush = false
        guard !staleRows.isEmpty else { return }
        let rows = staleRows.filteredIndexSet { $0 < table.numberOfRows }
        staleRows.removeAll()
        noteHeights(rows, holdingPosition: hold)
    }

    /// Tells the table that these rows' heights changed, optionally `holdingPosition`.
    /// Not held for typing, where the edited row itself is the one that should stay put.
    private func noteHeights(_ rows: IndexSet, holdingPosition hold: Bool) {
        guard !rows.isEmpty else { return }
        let note = {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            self.table.noteHeightOfRows(withIndexesChanged: rows)
            NSAnimationContext.endGrouping()
        }
        if hold { holdingPosition(changing: rows, note) } else { note() }
    }

    /// Runs `change`, which alters the heights of rows, and keeps what is being read where it is.
    /// The table keeps its scroll offset when a row changes height, so a change above the screen
    /// would move everything on it; here the offset moves by the same amount instead.
    private func holdingPosition(changing rows: IndexSet = [], _ change: () -> Void) {
        let clip = scrollView.contentView
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return change() }
        // The row nearest the middle of the screen that is not itself changing; if they all are, the top one.
        let middle = visible.location + visible.length / 2
        let row = (visible.location..<visible.location + visible.length).filter { !rows.contains($0) }
            .min { abs($0 - middle) < abs($1 - middle) } ?? visible.location
        let offset = table.rect(ofRow: row).minY - clip.bounds.minY
        change()
        let shift = table.rect(ofRow: row).minY - clip.bounds.minY - offset
        guard abs(shift) > 0.5 else { return }
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: shift)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The table works out row positions a block of about a hundred rows at a time, and only when
    /// the screen reaches a block. Done at that moment, the rows just scrolled into view land where
    /// its guess put them, a jump of up to a few lines. So after each scroll the blocks a little
    /// beyond the screen are worked out early, while nothing in them shows.
    private func scheduleResolveAhead() {
        guard !resolveAheadScheduled else { return }
        resolveAheadScheduled = true
        DispatchQueue.main.async { [weak self] in self?.resolveAhead() }
    }

    private func resolveAhead() {
        resolveAheadScheduled = false
        let visible = table.rows(in: table.visibleRect)
        guard state != nil, visible.length > 0 else { return }
        let last = table.numberOfRows - 1
        holdingPosition {
            _ = table.rect(ofRow: max(0, visible.location - Self.lookaheadRows))
            _ = table.rect(ofRow: min(last, visible.location + visible.length + Self.lookaheadRows))
        }
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
            // Every height is out of date. A window being dragged wider changes width on every
            // frame, so only the rows on screen are measured now; the rest get estimates and are
            // measured once the width has stopped changing.
            heights.removeAll(keepingCapacity: true)
            pendingRows.removeAll()
            let visible = table.rows(in: table.visibleRect)
            nearRows = max(0, visible.location - 4)..<(visible.location + visible.length + 4)
            busyUntil = CACurrentMediaTime() + 0.15
            noteHeights(IndexSet(integersIn: 0..<table.numberOfRows), holdingPosition: true)
        }
    }

    // MARK: Table data source and delegate

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        clearDiagramSelection()
        return true
    }

    /// The title, the blocks, then the space after the last block.
    func numberOfRows(in tableView: NSTableView) -> Int { state.map { $0.blocks.count + 2 } ?? 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let state else { return 24 }
        if row == 0 { return titleHeight }
        if row == endRow {
            lastEndSpace = endSpaceHeight
            return lastEndSpace
        }
        let block = state.blocks[row - 1]
        if let known = heights[block.id] { return known }
        // Measured here, the height is right before the row is ever laid out, so there is nothing to
        // correct once it shows.
        if !block.type.hasText || nearRows.contains(row) || canMeasureFarRow() { return measuredHeight(block) }
        pendingRows.insert(row)
        scheduleSettle()
        return estimatedHeight(block)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let state else { return nil }
        if row == 0 {
            let cell: TitleCell = dequeue("title")
            cell.configure(title: title, controller: self)
            return cell
        }
        if row == endRow {
            let cell: EndSpaceCell = dequeue("end")
            cell.controller = self
            return cell
        }
        let block = state.blocks[row - 1]
        settleHeight(block, row: row)
        let cell: NSView = block.type.hasText ? dequeue("text") as TextBlockCell
            : block.type == .diagram ? dequeue("diagram") as DiagramBlockCell : dequeue("static") as StaticBlockCell
        configure(cell, for: block, index: row - 1)
        return cell
    }

    /// Just before a page switch reloads the table: keeps the cells on screen for later pages' rows.
    /// `makeView(withIdentifier:)` gets none of them back after `reloadData`, so without this every
    /// page switch built its visible rows from scratch (about 20 ms, whatever the page's size).
    ///
    /// Only here, never while scrolling: a row view the table takes off screen can come back with
    /// its cell still expected inside, so the table alone decides when those cells are free.
    /// Each cell is detached as it is collected, so the table cannot recycle it as well: the pool
    /// only ever holds cells the table no longer has. Nothing draws before the reload refills the rows.
    /// Leftovers stay for later switches (pages need different kinds of cells, a diagram's being
    /// the costliest), up to a cap per kind.
    private func collectCellsForReuse() {
        let rows = table.rows(in: table.visibleRect)
        for row in rows.lowerBound..<rows.upperBound {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let id = cell.identifier, spareCells[id, default: []].count < Self.maxSpareCellsPerKind else { continue }
            cell.removeFromSuperview()
            spareCells[id, default: []].append(cell)
        }
    }

    /// The previous page's cells first, then the table's own recycling (scrolling), then a new cell.
    private func dequeue<Cell: NSTableCellView>(_ name: String) -> Cell {
        let id = NSUserInterfaceItemIdentifier(name)
        if let cell = spareCells[id]?.popLast() as? Cell { return cell }
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
        cellsCreated += 1
        let cell = Cell(frame: NSRect(x: 0, y: 0, width: table.bounds.width, height: 30))
        cell.identifier = id
        return cell
    }

    private func configure(_ view: NSView, for block: Block, index: Int) {
        if let cell = view as? TextBlockCell {
            cell.configure(block, number: block.type == .numbered ? (state?.listNumber(at: index) ?? 1) : 0, controller: self)
        } else if let cell = view as? DiagramBlockCell {
            cell.configure(block, diagram: block.props.diagramID.flatMap(diagram), controller: self)
        } else if let cell = view as? StaticBlockCell {
            cell.configure(block, title: block.type == .pageLink ? titleOfPage(block.props.targetPageID ?? "") : "", controller: self)
        }
    }

    // Drag a row by the margin beside it to reorder.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row > 0, row < endRow else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Dropping above the end space moves the block to the end of the page.
        dropOperation == .above && (1...endRow).contains(row) ? .move : []
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
            if selector == #selector(NSResponder.moveDown(_:)),
               let first = state.blocks.first(where: { $0.type.hasText || $0.type == .diagram }) {
                focusBlock(first.id, direction: 1)
                return true
            }
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
            return moveFromBlock(id, direction: -1)
        case #selector(NSResponder.moveDown(_:)):
            guard tv.caretIsOnEdgeLine(first: false) else { return false }
            return moveFromBlock(id, direction: 1)
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
