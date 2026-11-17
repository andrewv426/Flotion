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

    var body: some View {
        VStack(spacing: 0) {
            header
            if let status = ai.status, !ai.isReady {
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
                        EmptyChat(workspaceTools: ai.provider.supportsWorkspaceTools, ask: send)
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
            Picker("Assistant model", selection: Binding(get: { ai.selectedModelID }, set: { ai.selectModel($0) })) {
                ForEach(ai.visibleModels) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 280, alignment: .leading)
            .disabled(ai.chat.isRunning)
            .help("The selected provider receives recent chat turns and the open page.")
            .accessibilityIdentifier("assistant-model")
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
                TextField(ai.provider.supportsWorkspaceTools ? "Ask, or say what to change…" : "Ask about this page…", text: $draft, axis: .vertical)
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
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ai.isReady)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: Theme.divider), lineWidth: 1))
        .padding(12)
        .onAppear { composerFocused = true }
    }

    private func send(_ text: String) {
        guard ai.isReady, !ai.chat.isRunning else { return }
        draft = ""
        Task { await model.sendChat(text) }
    }
}

private struct EmptyChat: View {
    let workspaceTools: Bool
    let ask: (String) -> Void

    private var suggestions: [String] {
        ["Summarise this page", "List the action items on this page"]
            + (workspaceTools ? ["Draw a step-by-step diagram of this page"] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workspaceTools ? "Ask about this page or the rest of your notes, or have them edited for you."
                     : "Ask about the open page or draft text to paste into your notes.")
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
                if let modelLabel = message.modelLabel {
                    Text(modelLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Theme.secondary))
                }
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

/// Shown when the selected provider needs setup.
struct ConnectCard: View {
    let status: AIProviderStatus
    let ai: AIController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let service = ai.selectedModel.service
            Text(status == .notInstalled ? "Install \(service == .claude ? "Claude Code" : "Cursor CLI")" : "Connect \(service.label)")
                .font(.system(size: 13, weight: .semibold))
            HStack {
                if status == .notInstalled, let url = service.installURL {
                    Link("Installation guide", destination: url)
                } else if service == .claude {
                    Button("Sign in…") { ai.openSignIn() }
                } else {
                    SettingsLink { Text("Add API key in Settings") }
                }
                if service.installURL != nil {
                    Button("Check again") { Task { await ai.refreshStatus() } }
                }
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
