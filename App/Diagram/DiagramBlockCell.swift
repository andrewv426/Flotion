import AppKit
import FlotionCore
import WebKit

private final class DiagramWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Scroll the editor even when the pointer is over an interactive diagram.
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Builds the locked-down web views that render diagrams.
///
/// Two independent layers keep LLM-authored content offline: the document's
/// Content-Security-Policy (`DiagramTemplate`) and a WebKit content rule that blocks
/// every network request. Storage is non-persistent and navigation is refused.
@MainActor
enum DiagramSandbox {
    private static var ruleList: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static var compiling = false

    static func prepare(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let ruleList { done(ruleList); return }
        waiting.append(done)
        guard !compiling else { return }
        compiling = true
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "flotion.block-network", encodedContentRuleList: rules) { list, _ in
            Task { @MainActor in
                ruleList = list
                compiling = false
                let callbacks = waiting
                waiting = []
                callbacks.forEach { $0(list) }
            }
        }
    }

    static func makeWebView(rules: WKContentRuleList?) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if let rules { config.userContentController.add(rules) }
        let webView = DiagramWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // let the page colour show through
        webView.allowsMagnification = false
        return webView
    }
}

/// Laid-out Flow diagrams, kept so that asking a row for its height does not lay the diagram out again.
@MainActor
enum FlowScenes {
    private static var cache: [String: (stamp: Date, scene: FlowScene?)] = [:]

    static func scene(for diagram: Diagram) -> FlowScene? {
        if let hit = cache[diagram.id], hit.stamp == diagram.updatedAt { return hit.scene }
        let scene = try? FlowScene(source: diagram.source)
        if cache.count > 200 { cache.removeAll() }
        cache[diagram.id] = (diagram.updatedAt, scene)
        return scene
    }
}

/// A diagram block: a sandboxed web view. A Flow diagram sits straight on the page at its own size;
/// the older html and steps formats keep a titled frame at the height their author gave.
/// Web views exist only for rows on screen, because the table reuses a handful of cells.
final class DiagramBlockCell: FlippedCell, WKNavigationDelegate {
    private let frameView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    let actionsButton = NSButton()
    private var blockID = ""
    private weak var controller: EditorController?
    private var hasInteractiveContent = false
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    var isBlockSelected = false {
        didSet { updateBlockAppearance() }
    }
    private(set) var webView: WKWebView?
    private var loadedKey = ""
    private var pendingHTML: String?
    private var depth = 0
    private var frameless = false
    private var initialLoad: WKNavigation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = 6
        frameView.layer?.borderWidth = 1
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(frameView)
        frameView.addSubview(titleLabel)
        actionsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        actionsButton.imagePosition = .imageOnly
        actionsButton.isBordered = false
        actionsButton.contentTintColor = Theme.text
        actionsButton.toolTip = "Diagram actions"
        actionsButton.setAccessibilityLabel("Diagram actions")
        actionsButton.wantsLayer = true
        actionsButton.layer?.cornerRadius = 5
        actionsButton.layer?.backgroundColor = Theme.hover.cgColor
        actionsButton.target = self
        actionsButton.action = #selector(showActions)
        actionsButton.isHidden = true
        addSubview(actionsButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ block: Block, diagram: Diagram?, controller: EditorController) {
        blockID = block.id
        self.controller = controller
        depth = block.depth
        frameless = diagram?.format == .flow
        hasInteractiveContent = diagram.map { diagram in
            diagram.format != .flow || FlowScenes.scene(for: diagram)?.stepped == true
        } ?? false
        titleLabel.isHidden = frameless
        titleLabel.textColor = Theme.secondary
        titleLabel.stringValue = diagram?.title ?? "Diagram unavailable"
        isBlockSelected = controller.selectedDiagramID == block.id
        needsLayout = true
        guard let diagram else { return }
        // Reload only when the content actually changed, so scrolling does not restart animations.
        let key = "\(diagram.id)|\(diagram.updatedAt.timeIntervalSince1970)"
        guard key != loadedKey else { return }
        loadedKey = key
        let html = DiagramTemplate.document(for: diagram)
        if let webView {
            initialLoad = webView.loadHTMLString(html, baseURL: nil)
        } else {
            pendingHTML = html
            DiagramSandbox.prepare { [weak self] rules in self?.attachWebView(rules) }
        }
    }

    private func attachWebView(_ rules: WKContentRuleList?) {
        guard webView == nil else { return }
        let webView = DiagramSandbox.makeWebView(rules: rules)
        webView.navigationDelegate = self
        frameView.addSubview(webView)
        self.webView = webView
        needsLayout = true
        if let html = pendingHTML {
            pendingHTML = nil
            initialLoad = webView.loadHTMLString(html, baseURL: nil)
        }
    }

    override func layout() {
        super.layout()
        let column = Theme.contentColumn(in: bounds.width)
        let x = column.x + CGFloat(depth) * Theme.indentStep
        frameView.frame = NSRect(x: x, y: 6, width: column.width - (x - column.x), height: bounds.height - 12)
        actionsButton.frame = NSRect(x: x - 30, y: 6, width: 24, height: 22)
        // Layer-backed subviews of a non-flipped view: measure from the bottom.
        titleLabel.frame = NSRect(x: 12, y: frameView.bounds.height - 26, width: frameView.bounds.width - 24, height: 16)
        webView?.frame = frameless ? frameView.bounds
            : NSRect(x: 1, y: 1, width: frameView.bounds.width - 2, height: frameView.bounds.height - 32)
    }

    func containsBlock(at point: NSPoint) -> Bool {
        frameView.frame.union(actionsButton.frame).contains(point)
    }

    /// Interactive diagrams get normal WebKit mouse handling inside their drawing.
    func interactiveHit(at point: NSPoint) -> NSView? {
        guard hasInteractiveContent, let webView else { return nil }
        return webView.hitTest(frameView.convert(point, from: self))
    }

    override func mouseDown(with event: NSEvent) {
        if controller?.selectDiagram(blockID) != true { super.mouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.diagramMenu(for: blockID)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        isHovered = window.map { visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateBlockAppearance()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBlockAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBlockAppearance()
    }

    private func updateBlockAppearance() {
        frameView.layer?.borderWidth = isBlockSelected ? 2 : (frameless ? 0 : 1)
        frameView.layer?.borderColor = (isBlockSelected ? Theme.accent : Theme.divider).cgColor
        frameView.layer?.backgroundColor = isBlockSelected ? Theme.accent.withAlphaComponent(0.10).cgColor : nil
        actionsButton.isHidden = !isHovered && !isBlockSelected
    }

    @objc private func showActions() {
        guard let menu = controller?.diagramMenu(for: blockID) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionsButton.bounds.height), in: actionsButton)
    }

    /// The row's margin above and below the diagram.
    private static let margin: CGFloat = 12
    /// The title bar and border of a framed (html or steps) diagram.
    private static let frameChrome: CGFloat = 32

    /// A Flow diagram is as tall as its drawing at this width; it shrinks to fit a narrow column and never grows.
    static func rowHeight(for diagram: Diagram?, width: CGFloat) -> CGFloat {
        guard let diagram else { return 120 + margin + frameChrome }
        if diagram.format == .flow, let scene = FlowScenes.scene(for: diagram) {
            return scene.displayHeight(forWidth: width) + margin
        }
        return diagram.height + margin + frameChrome
    }

    // Only the document we load ourselves may be shown; links and redirects go nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isOwnLoad = navigationAction.navigationType == .other && (navigationAction.request.url?.absoluteString ?? "") == "about:blank"
        decisionHandler(isOwnLoad ? .allow : .cancel)
    }
}
