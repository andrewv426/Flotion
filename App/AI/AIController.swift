import AppKit
import FlotionAI
import FlotionCore
import Observation

/// The text the user has selected in the editor, kept so the AI can act on it.
struct EditorSelection: Equatable {
    var blockID: String
    var range: NSRange
    var text: String
}

/// App-level AI state: the provider, its sign-in status, and the chat conversation.
@MainActor @Observable
final class AIController {
    @ObservationIgnored let provider: any AIProvider
    @ObservationIgnored let workspace: Workspace
    /// The MCP server shipped inside the app bundle; the in-app AI uses the same one external clients do.
    @ObservationIgnored let serverURL: URL

    var status: AIProviderStatus?
    private(set) var chat: ChatSession
    var isPanelOpen: Bool = AppDefaults.store.bool(forKey: "aiPanelOpen") {
        didSet {
            AppDefaults.store.set(isPanelOpen, forKey: "aiPanelOpen")
            if isPanelOpen, case .ready = status { chat.prewarm() }
        }
    }
    /// A Claude Code model alias, or empty for the account's default.
    var modelChoice: String = AppDefaults.store.string(forKey: "aiModel") ?? "" {
        didSet {
            AppDefaults.store.set(modelChoice, forKey: "aiModel")
            chat.model = modelChoice.isEmpty ? nil : modelChoice
        }
    }

    static let modelChoices: [(label: String, alias: String)] = [
        ("Account default", ""), ("Fable", "fable"), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku"),
    ]

    init(workspace: Workspace) {
        self.workspace = workspace
        serverURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/flotion-mcp")
        let scratch = workspace.url.deletingLastPathComponent().appendingPathComponent("ai-workdir", isDirectory: true)
        #if DEBUG || SELFTEST
        if ProcessInfo.processInfo.environment["FLOTION_FAKE_AI"] == "1" {
            provider = Self.fakeProvider(workspace: workspace)
        } else {
            provider = ClaudeCodeProvider(workingDirectory: scratch)
        }
        #else
        provider = ClaudeCodeProvider(workingDirectory: scratch)
        #endif
        chat = ChatSession(provider: provider, workspace: workspace, server: serverURL)
        chat.model = modelChoice.isEmpty ? nil : modelChoice
    }

    var claudePath: String? { (provider as? ClaudeCodeProvider)?.executable?.path }

    func refreshStatus() async {
        status = await provider.status()
        if isPanelOpen, case .ready = status { chat.prewarm() }
    }

    func newChat() {
        chat.clear()
    }

    /// One-shot, tool-free request for an inline edit: low effort, no session left behind.
    func inlineRequest(prompt: String) -> AIRequest {
        AIRequest(prompt: prompt, systemPrompt: AIPrompts.inlineSystem, model: modelChoice.isEmpty ? nil : modelChoice,
                  effort: "low", tools: .none, keepSession: false)
    }

    /// Sign-in is Claude Code's own flow, run in Terminal. Flotion never handles a credential.
    func openSignIn() {
        guard let claudePath else { return }
        let script = workspace.url.deletingLastPathComponent().appendingPathComponent("Sign in to Claude.command")
        let body = "#!/bin/zsh\n\"\(claudePath)\" auth login\necho\necho \"Done. You can close this window and return to Flotion.\"\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSSound.beep()
        }
    }

    /// The command that connects an external MCP client (Claude Code) to this workspace.
    var externalConnectCommand: String {
        "claude mcp add flotion -- \"\(serverURL.path)\""
    }

    #if DEBUG || SELFTEST
    /// Stands in for Claude in the self-test: a chat turn appends a block the way the model
    /// would through the MCP tools, and an inline edit returns fixed text.
    private static func fakeProvider(workspace: Workspace) -> FakeProvider {
        FakeProvider { request in
            guard case .flotion(_, _, let actor) = request.tools else {
                return [.started(sessionID: "", model: "fake"), .text("A shorter "), .text("**sentence**."),
                        .finished(AIResult(text: "A shorter **sentence**."))]
            }
            var events: [AIEvent] = [.started(sessionID: "fake-session", model: "fake")]
            if let range = request.prompt.range(of: "page_id: ") {
                let pageID = String(request.prompt[range.upperBound...].prefix { $0 != ")" })
                events.append(.toolStarted(id: "t1", name: "append_blocks"))
                _ = try? workspace.insertBlocks(pageID: pageID, MarkdownCodec.parse("Summary added by the assistant."),
                                                context: ChangeContext(actor: actor))
                events.append(.toolFinished(id: "t1", isError: false))
            }
            events += [.text("Added a summary "), .text("to the end of the page."),
                       .finished(AIResult(text: "Added a summary to the end of the page.", sessionID: "fake-session"))]
            return events
        }
    }
    #endif
}
