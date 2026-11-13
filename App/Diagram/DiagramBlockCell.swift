import AppKit
import FlotionCore
import WebKit

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
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // let the page colour show through
        webView.allowsMagnification = false
        return webView
    }
}

/// A diagram block: a titled frame around a sandboxed web view.
/// Web views exist only for rows on screen, because the table reuses a handful of cells.
final class DiagramBlockCell: FlippedCell, WKNavigationDelegate {
    private let frameView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private(set) var webView: WKWebView?
    private var loadedKey = ""
    private var pendingHTML: String?
    private var depth = 0
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ block: Block, diagram: Diagram?) {
        depth = block.depth
        frameView.layer?.borderColor = Theme.divider.cgColor
        titleLabel.textColor = Theme.secondary
        titleLabel.stringValue = diagram?.title ?? "Diagram unavailable"
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
        // Layer-backed subviews of a non-flipped view: measure from the bottom.
        titleLabel.frame = NSRect(x: 12, y: frameView.bounds.height - 26, width: frameView.bounds.width - 24, height: 16)
        webView?.frame = NSRect(x: 1, y: 1, width: frameView.bounds.width - 2, height: frameView.bounds.height - 32)
    }

    static let chromeHeight: CGFloat = 44

    // Only the document we load ourselves may be shown; links and redirects go nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isOwnLoad = navigationAction.navigationType == .other && (navigationAction.request.url?.absoluteString ?? "") == "about:blank"
        decisionHandler(isOwnLoad ? .allow : .cancel)
    }
}
