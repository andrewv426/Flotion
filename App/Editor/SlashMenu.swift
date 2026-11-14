import AppKit
import FlotionCore
import FlotionEditor
import Observation
import SwiftUI

/// The "/" menu. Unlike an `NSMenu`, which runs its own modal tracking loop and takes the
/// keyboard away from the editor, this is a floating panel that never becomes key: the caret
/// stays in the text view, so typing after the "/" filters the list, and the editor forwards
/// ↑ ↓ Return Tab and Esc to it (see `EditorController.textView(_:doCommandBy:)`).
@MainActor
final class SlashMenuPresenter {
    let model: SlashMenuModel
    private let panel: SlashMenuPanel
    private weak var textView: BlockTextView?
    private var observers: [NSObjectProtocol] = []

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 46
    static let headerHeight: CGFloat = 28
    static let maxHeight: CGFloat = 360

    init(session: SlashMenuSession, textView: BlockTextView, onChoose: @escaping (SlashCommand) -> Void) {
        model = SlashMenuModel(session: session)
        self.textView = textView
        panel = SlashMenuPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = FirstClickHostingView(rootView: SlashMenuView(model: model))
        panel.setAccessibilityIdentifier("slash-menu")
        model.onChoose = onChoose
    }

    var session: SlashMenuSession { model.session }

    /// The panel window, for the self-test's snapshot.
    var window: NSWindow { panel }

    func show() {
        guard let parent = textView?.window else { return }
        reposition()
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        // Leaving the window (another app, another window) closes the menu, as a real menu would.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.onDismiss?() }
        })
    }

    func update(_ session: SlashMenuSession) {
        model.session = session
        reposition()
    }

    /// Sits under the "/" (or above it when there is no room below), sized to its rows.
    func reposition() {
        guard let tv = textView, tv.window != nil else { return }
        let caret = tv.firstRect(forCharacterRange: NSRange(location: session.anchor, length: 0), actualRange: nil)
        guard caret.origin.x.isFinite, caret.origin.y.isFinite else { return }
        let height = contentHeight
        var origin = NSPoint(x: caret.minX - 8, y: caret.minY - 6 - height)
        if let screen = tv.window?.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = caret.maxY + 6 }
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - Self.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
    }

    private var contentHeight: CGFloat {
        let s = session
        if s.matches.isEmpty { return 44 }
        let headers = SlashMenuView.sections(for: s).count
        let rows = CGFloat(s.matches.count) * Self.rowHeight + CGFloat(headers) * Self.headerHeight + 12
        return min(rows, Self.maxHeight)
    }

    func close() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

@MainActor @Observable
final class SlashMenuModel {
    var session: SlashMenuSession
    @ObservationIgnored var onChoose: ((SlashCommand) -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?

    init(session: SlashMenuSession) { self.session = session }

    func hover(_ index: Int) { session.select(index) }

    func choose(_ index: Int) {
        session.select(index)
        if let command = session.selectedCommand { onChoose?(command) }
    }
}

/// Never takes the keyboard, so typing keeps going to the editor.
private final class SlashMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a row should choose it at once, not first activate the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SlashMenuView: View {
    let model: SlashMenuModel

    /// Section titles and the index of each section's first row. Only shown before filtering.
    static func sections(for session: SlashMenuSession) -> [(title: String, start: Int)] {
        guard session.query.isEmpty else { return [] }
        let blocksStart = session.matches.firstIndex { $0.action != .askAI } ?? session.matches.count
        var result: [(String, Int)] = []
        if blocksStart > 0 { result.append(("AI", 0)) }
        if blocksStart < session.matches.count { result.append(("Basic blocks", blocksStart)) }
        return result
    }

    var body: some View {
        let session = model.session
        let sections = Self.sections(for: session)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if session.matches.isEmpty {
                        Text("No results")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(nsColor: Theme.secondary))
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    }
                    ForEach(Array(session.matches.enumerated()), id: \.element.id) { index, command in
                        if let section = sections.first(where: { $0.start == index }) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(nsColor: Theme.secondary))
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: SlashMenuPresenter.headerHeight, alignment: .bottomLeading)
                                .padding(.bottom, 2)
                        }
                        SlashMenuRow(command: command, isSelected: index == session.selected)
                            .id(command.id)
                            .contentShape(Rectangle())
                            .onHover { if $0 { model.hover(index) } }
                            .onTapGesture { model.choose(index) }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .onChange(of: session.selected) {
                if let command = model.session.selectedCommand { proxy.scrollTo(command.id) }
            }
        }
        .foregroundStyle(Color(nsColor: Theme.text))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Theme.page)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: Theme.divider), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct SlashMenuRow: View {
    let command: SlashCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.page)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Theme.divider), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(.system(size: 14))
                Text(command.detail).font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.secondary))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: SlashMenuPresenter.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: isSelected ? Theme.hover : .clear)))
    }

    @ViewBuilder private var icon: some View {
        switch command.action {
        case .askAI:
            Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(Color(nsColor: Theme.accent))
        case .turnInto(let type):
            switch type {
            case .heading1: badge("H1")
            case .heading2: badge("H2")
            case .heading3: badge("H3")
            case .paragraph: badge("Aa")
            default: Image(systemName: Self.symbol(for: type)).font(.system(size: 14))
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold))
    }

    private static func symbol(for type: BlockType) -> String {
        switch type {
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .todo: "checkmark.square"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .divider: "minus"
        default: "textformat"
        }
    }
}
