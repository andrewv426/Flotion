import FlotionAI
import Observation
import SwiftUI

/// One "Edit with AI" interaction: an instruction, a streamed preview, then accept or discard.
/// Nothing touches the page until the user accepts.
@MainActor @Observable
final class InlineEditModel {
    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(message: String, needsSignIn: Bool)
    }

    var phase: Phase = .idle
    var preview = ""
    private(set) var instruction = ""

    @ObservationIgnored let selection: String
    @ObservationIgnored let context: String
    @ObservationIgnored private let ai: AIController
    @ObservationIgnored private var task: Task<Void, Never>?

    init(ai: AIController, selection: String, context: String) {
        self.ai = ai
        self.selection = selection
        self.context = context
    }

    /// True when there is no selection: the request writes new content instead of rewriting.
    var isGenerating: Bool { selection.isEmpty }

    func prewarm() {
        ai.provider.prewarm(ai.inlineRequest(prompt: ""))
    }

    func run(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        self.instruction = trimmed
        preview = ""
        phase = .running
        let prompt = isGenerating
            ? "Write this for the user's page: \(trimmed)" + (context.isEmpty ? "" : "\n\nThe page so far, for context only:\n<<<\n\(context)\n>>>")
            : AIPrompts.inline(instruction: trimmed, selection: selection, context: context)
        let request = ai.inlineRequest(prompt: prompt)
        let provider = ai.provider
        task = Task { [weak self] in
            for await event in provider.run(request) {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .text(let piece):
                    self.preview += piece
                case .finished(let result):
                    if let failure = result.failure {
                        let message = switch failure {
                        case .notInstalled: "Claude Code is not installed."
                        case .notSignedIn: "Claude is signed out."
                        case .rateLimited: "You have reached your plan's usage limit for now."
                        case .other: result.message ?? "The request failed."
                        }
                        self.phase = .failed(message: message, needsSignIn: failure == .notSignedIn || failure == .notInstalled)
                    } else {
                        if self.preview.isEmpty { self.preview = result.text }
                        self.phase = .done
                    }
                default:
                    break
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .running { phase = preview.isEmpty ? .idle : .done }
    }
}

struct InlineEditView: View {
    let model: InlineEditModel
    let onAccept: (String) -> Void
    let onInsertBelow: (String) -> Void
    let onDiagram: () -> Void
    let onClose: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    private static let presets: [(String, String)] = [
        ("Improve writing", "Improve the writing: clearer and tighter, same meaning."),
        ("Fix spelling & grammar", "Fix spelling, grammar and punctuation. Change nothing else."),
        ("Make shorter", "Make it shorter while keeping the key points."),
        ("Make longer", "Expand it with more detail, in the same voice."),
        ("More professional", "Rewrite it in a professional tone."),
        ("Summarise", "Summarise it in two or three sentences."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .idle:
                prompt
                if !model.isGenerating { presets }
            case .running, .done:
                Text(model.instruction).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                ScrollView {
                    Text(MessagePreview.rendered(model.preview))
                        .font(.system(size: 14)).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .accessibilityIdentifier("inline-preview")
                actions
            case .failed(let message, let needsSignIn):
                Text(message).font(.system(size: 13))
                HStack {
                    if needsSignIn { SettingsLink { Text("Open Settings") } }
                    Button("Try again") { model.run(model.instruction) }
                    Button("Close", action: onClose)
                }
            }
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
        .onAppear {
            focused = true
            model.prewarm()
        }
        .onDisappear { model.cancel() }
    }

    private var prompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            TextField(model.isGenerating ? "What should Claude write?" : "How should Claude change this?", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { model.run(draft) }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(Self.presets[(row * 3)..<(row * 3 + 3)], id: \.0) { preset in
                        Button(preset.0) { model.run(preset.1) }
                    }
                }
            }
            Button("Turn into a diagram", action: onDiagram)
        }
        .controlSize(.small)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.phase == .running {
                ProgressView().controlSize(.small)
                Button("Stop") { model.cancel() }
            } else {
                Button(model.isGenerating ? "Insert" : "Replace") { onAccept(model.preview) }
                    .keyboardShortcut(.defaultAction)
                if !model.isGenerating {
                    Button("Insert below") { onInsertBelow(model.preview) }
                }
                Button("Try again") { model.run(model.instruction) }
            }
            Spacer()
            Button("Discard", action: onClose).keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
    }
}

enum MessagePreview {
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
