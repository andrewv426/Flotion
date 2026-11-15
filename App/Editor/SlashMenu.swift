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

    static let width: CGFloat = 300
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 26
    static let footerHeight: CGFloat = 32
    static let listPadding: CGFloat = 4
    static let maxListHeight: CGFloat = 320
    /// Room around the menu inside the panel for its soft shadow, which the panel draws itself.
    static let shadowMargin: CGFloat = 40
    /// Gap between the line with the "/" and the menu.
    static let gap: CGFloat = 4

    init(session: SlashMenuSession, textView: BlockTextView, onChoose: @escaping (SlashCommand) -> Void) {
        model = SlashMenuModel(session: session)
        self.textView = textView
        panel = SlashMenuPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        // Appears and goes at once, like the text it belongs to.
        panel.animationBehavior = .none
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

    /// Sits just under the line with the "/", its left edge at the text's (or above the line when
    /// there is no room below), sized to its rows.
    func reposition() {
        guard let tv = textView, tv.window != nil else { return }
        let line = tv.firstRect(forCharacterRange: NSRange(location: session.anchor, length: 0), actualRange: nil)
        guard line.origin.x.isFinite, line.origin.y.isFinite else { return }
        let menu = NSSize(width: Self.width, height: Self.menuHeight(for: session))
        let m = Self.shadowMargin
        var origin = NSPoint(x: line.minX - Self.listPadding - 8 - m, y: line.minY - Self.gap - menu.height - m)
        if let screen = tv.window?.screen?.visibleFrame {
            if origin.y + m < screen.minY { origin.y = line.maxY + Self.gap - m }
            origin.x = min(max(origin.x, screen.minX + 4 - m), screen.maxX - menu.width - 4 - m)
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: menu.width + 2 * m, height: menu.height + 2 * m), display: true)
    }

    static func listHeight(for s: SlashMenuSession) -> CGFloat {
        if s.matches.isEmpty { return rowHeight + 2 * listPadding }
        let headers = CGFloat(SlashMenuView.sections(for: s).count)
        return min(CGFloat(s.matches.count) * rowHeight + headers * headerHeight + 2 * listPadding, maxListHeight)
    }

    static func menuHeight(for s: SlashMenuSession) -> CGFloat { listHeight(for: s) + 1 + footerHeight }

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
    @ObservationIgnored private var lastMouse: NSPoint?

    init(session: SlashMenuSession) { self.session = session }

    /// Follows the pointer only when it actually moves, so rows scrolling under a resting pointer
    /// do not steal the highlight from the keyboard.
    func hover(_ index: Int) {
        let mouse = NSEvent.mouseLocation
        guard mouse != lastMouse else { return }
        lastMouse = mouse
        session.select(index)
    }

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

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            list.frame(height: SlashMenuPresenter.listHeight(for: model.session))
            Rectangle().fill(Color(nsColor: Theme.divider)).frame(height: 1)
            footer
        }
        .frame(width: SlashMenuPresenter.width)
        .background(Self.shape.fill(Color(nsColor: Theme.menuBackground)))
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color(nsColor: Theme.divider), lineWidth: 1))
        // A close, crisp shadow and a wide, soft one, so the menu floats just off the page.
        .shadow(color: Color(nsColor: Theme.menuShadow).opacity(0.5), radius: 2, y: 1)
        .shadow(color: Color(nsColor: Theme.menuShadow), radius: 14, y: 6)
        .padding(SlashMenuPresenter.shadowMargin)
        .foregroundStyle(Color(nsColor: Theme.text))
    }

    private var list: some View {
        let session = model.session
        let sections = Self.sections(for: session)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if session.matches.isEmpty {
                        Text("No results")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(nsColor: Theme.secondary))
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: SlashMenuPresenter.rowHeight, alignment: .leading)
                    }
                    ForEach(Array(session.matches.enumerated()), id: \.element.id) { index, command in
                        if let section = sections.first(where: { $0.start == index }) {
                            Text(section.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color(nsColor: Theme.secondary))
                                .padding(.horizontal, 12)
                                .padding(.bottom, 5)
                                .frame(maxWidth: .infinity, minHeight: SlashMenuPresenter.headerHeight, alignment: .bottomLeading)
                        }
                        SlashMenuRow(command: command, isSelected: index == session.selected)
                            .id(command.id)
                            .contentShape(Rectangle())
                            .onContinuousHover { if case .active = $0 { model.hover(index) } }
                            .onTapGesture { model.choose(index) }
                    }
                }
                .padding(.vertical, SlashMenuPresenter.listPadding)
            }
            .scrollIndicators(.never)
            .onChange(of: session.selected) {
                if let command = model.session.selectedCommand { proxy.scrollTo(command.id) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Close menu")
            Spacer()
            Text("esc")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: Theme.secondary))
        .padding(.horizontal, 12)
        .frame(height: SlashMenuPresenter.footerHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.onDismiss?() }
    }
}

private struct SlashMenuRow: View {
    let command: SlashCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 20, height: 20)
            Text(command.title).font(.system(size: 14)).lineLimit(1)
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                Text(shortcut.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Theme.secondary))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SlashMenuPresenter.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: isSelected ? Theme.hover : .clear)))
        .padding(.horizontal, SlashMenuPresenter.listPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(command.title), \(command.detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch command.action {
        case .askAI:
            Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(Color(nsColor: Theme.accent))
        case .turnInto(let type):
            switch type {
            case .heading1: badge("H1")
            case .heading2: badge("H2")
            case .heading3: badge("H3")
            default: Image(systemName: Self.symbol(for: type)).font(.system(size: 14))
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold))
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
