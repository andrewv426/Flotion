import AppKit
import FlotionAI
import SwiftUI

/// The side chat. It knows the open page and selection, and reaches the rest of the
/// workspace through the same MCP tools external clients use.
struct AIPanelView: View {
    let model: AppModel
    let ai: AIController
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var isReady: Bool {
        if case .ready = ai.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let status = ai.status, !isReady {
                ConnectCard(status: status, ai: ai)
            }
            messages
            composer
        }
        .background(Color(nsColor: Theme.page))
        .task { await ai.refreshStatus() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Assistant").font(.system(size: 13, weight: .semibold))
            Spacer()
            IconButton(symbol: "square.and.pencil", help: "New chat") { ai.newChat() }
            IconButton(symbol: "xmark", help: "Close") { ai.isPanelOpen = false }
        }
        .foregroundStyle(Color(nsColor: Theme.text))
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if ai.chat.messages.isEmpty {
                        EmptyChat { send($0) }
                    }
                    ForEach(ai.chat.messages) { message in
                        MessageView(message: message) { Task { await ai.chat.undo(message.id) } }
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: ai.chat.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: ai.chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedPageID != nil {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text").font(.system(size: 10))
                    Text(model.title.isEmpty ? "Untitled" : model.title).lineLimit(1)
                    if let selection = model.selection {
                        Text("· \(selection.text.count) characters selected")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.secondary))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask, or say what to change…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        // Return sends (through onSubmit). Shift-Return breaks the line, the same as
                        // Option-Return: the field editor inserts it at the caret, so undo still works.
                        guard press.modifiers.contains(.shift),
                              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return .handled
                    }
                    .onSubmit { send(draft) }
                    .accessibilityIdentifier("ai-composer")
                if ai.chat.isRunning {
                    IconButton(symbol: "stop.circle.fill", help: "Stop") { ai.chat.stop() }
                } else {
                    IconButton(symbol: "arrow.up.circle.fill", help: "Send") { send(draft) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isReady)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: Theme.divider), lineWidth: 1))
        .padding(12)
        .onAppear { composerFocused = true }
    }

    private func send(_ text: String) {
        guard isReady, !ai.chat.isRunning else { return }
        draft = ""
        Task { await model.sendChat(text) }
    }
}

private struct EmptyChat: View {
    let ask: (String) -> Void
    private let suggestions = ["Summarise this page", "List the action items on this page", "Draw a step-by-step diagram of this page"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this page or the rest of your notes, or have them edited for you.")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Theme.secondary))
            ForEach(suggestions, id: \.self) { suggestion in
                Button { ask(suggestion) } label: {
                    Text(suggestion).font(.system(size: 13))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.hover)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: Theme.text))
            }
        }
    }
}

private struct MessageView: View {
    let message: ChatMessage
    let undo: () -> Void

    var body: some View {
        if message.role == .user {
            Text(message.text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Theme.hover)))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(Color(nsColor: Theme.text))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.tools) { tool in
                    HStack(spacing: 6) {
                        if tool.isDone {
                            Image(systemName: tool.isError ? "exclamationmark.triangle" : "checkmark").font(.system(size: 10, weight: .semibold))
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text(tool.label)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Theme.secondary))
                }
                if !message.text.isEmpty {
                    Text(Self.rendered(message.text))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .foregroundStyle(Color(nsColor: Theme.text))
                } else if message.isStreaming, message.tools.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if let notice = message.notice {
                    HStack(spacing: 8) {
                        Text(notice).font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.secondary))
                        if message.failure == .notSignedIn || message.failure == .notInstalled {
                            SettingsLink { Text("Open Settings").font(.system(size: 12)) }
                        }
                    }
                }
                if message.changeCount > 0, !message.isStreaming {
                    HStack(spacing: 8) {
                        Text(message.isUndone ? "Changes undone" : "\(message.changeCount) change\(message.changeCount == 1 ? "" : "s") to your notes")
                        if !message.isUndone {
                            Button("Undo", action: undo).buttonStyle(.link)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Theme.secondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Shown when Claude Code is missing or signed out.
struct ConnectCard: View {
    let status: AIProviderStatus
    let ai: AIController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status == .notInstalled ? "Claude Code is not installed" : "Claude is signed out")
                .font(.system(size: 13, weight: .semibold))
            Text(status == .notInstalled
                 ? "The assistant runs on your Claude subscription through Claude Code. Install it, then sign in."
                 : "The assistant runs on your Claude subscription. Sign in through Claude Code; Flotion never sees your password or token.")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Theme.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if status == .notInstalled {
                    Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                } else {
                    Button("Sign in…") { ai.openSignIn() }
                }
                Button("Check again") { Task { await ai.refreshStatus() } }
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Theme.hover)))
        .padding(.horizontal, 12)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: Theme.secondary))
        .help(help)
    }
}
