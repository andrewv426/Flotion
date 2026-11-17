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
    @ObservationIgnored let workspace: Workspace
    /// The MCP server shipped inside the app bundle; the in-app AI uses the same one external clients use.
    @ObservationIgnored let serverURL: URL
    @ObservationIgnored private let usesFakeProviders: Bool
    @ObservationIgnored private var providers: [AssistantService: any AIProvider] = [:]
    @ObservationIgnored private let scratch: URL
    @ObservationIgnored private var statusRefresh = UUID()

    private(set) var statuses: [AssistantService: AIProviderStatus] = [:]
    private(set) var enabledIDs: Set<String>
    private(set) var customModels: [AssistantModel]
    private(set) var selectedModelID: String
    let chat: ChatSession

    var isPanelOpen: Bool = AppDefaults.store.bool(forKey: "aiPanelOpen") {
        didSet {
            AppDefaults.store.set(isPanelOpen, forKey: "aiPanelOpen")
            prewarm()
        }
    }

    var allModels: [AssistantModel] { AssistantModel.suggested + customModels }
    var visibleModels: [AssistantModel] { allModels.filter { enabledIDs.contains($0.id) } }
    var selectedModel: AssistantModel { visibleModels.first { $0.id == selectedModelID } ?? .claudeDefault }
    var status: AIProviderStatus? { statuses[selectedModel.service] }
    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    var provider: any AIProvider { providers[selectedModel.service]! }

    init(workspace: Workspace) {
        self.workspace = workspace
        serverURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/flotion-mcp")
        scratch = workspace.url.deletingLastPathComponent().appendingPathComponent("ai-workdir", isDirectory: true)
        #if DEBUG || SELFTEST
        usesFakeProviders = ProcessInfo.processInfo.environment["FLOTION_FAKE_AI"] == "1"
        #else
        usesFakeProviders = false
        #endif

        let defaults = AppDefaults.store
        let savedModels = defaults.data(forKey: "assistantCustomModels")
            .flatMap { try? JSONDecoder().decode([AssistantModel].self, from: $0) } ?? []
        let legacyAlias = defaults.string(forKey: "aiModel") ?? ""
        let legacy = AssistantModel(service: .claude, alias: legacyAlias, name: legacyAlias)
        let previousID = defaults.string(forKey: "assistantModel") ?? legacy.id
        var models = savedModels
        if defaults.string(forKey: "assistantModel") == nil,
           !(AssistantModel.suggested + models).contains(where: { $0.id == legacy.id }) {
            models.append(legacy)
        }
        let allModels = AssistantModel.suggested + models
        let enabled = Set(defaults.stringArray(forKey: "assistantEnabledModels") ?? allModels.filter { $0.service == .claude }.map(\.id))
        let visible = allModels.filter { enabled.contains($0.id) }
        let initial = visible.first { $0.id == previousID } ?? visible.first ?? .claudeDefault
        customModels = models
        enabledIDs = visible.isEmpty ? [initial.id] : Set(visible.map(\.id))
        selectedModelID = initial.id
        let claude: any AIProvider = usesFakeProviders
            ? Self.fakeClaude(workspace: workspace) : ClaudeCodeProvider(workingDirectory: scratch)
        chat = ChatSession(provider: claude, workspace: workspace, server: serverURL)
        providers[.claude] = claude
        for (service, cli) in [(AssistantService.openAI, AccountCLIProvider.CLI.codex), (.gemini, .gemini)] {
            providers[service] = usesFakeProviders
                ? FakeProvider(supportsWorkspaceTools: false) { _ in
                    [.finished(AIResult(text: "An answer from the selected model."))]
                }
                : AccountCLIProvider(cli, directory: scratch)
        }
        selectCurrentProvider()
        persistModels()
    }

    func refreshStatus() async {
        if !usesFakeProviders && !chat.isRunning {
            let claude = ClaudeCLI.locate()
            if (providers[.claude] as? ClaudeCodeProvider)?.executable != claude {
                providers[.claude] = ClaudeCodeProvider(executable: claude, workingDirectory: scratch)
                if selectedModel.service == .claude { selectCurrentProvider() }
            }
            for (service, cli) in [(AssistantService.openAI, AccountCLIProvider.CLI.codex), (.gemini, .gemini)] {
                if (providers[service] as? AccountCLIProvider)?.executable != AccountCLIProvider.locate(cli) {
                    providers[service] = AccountCLIProvider(cli, directory: scratch)
                    if selectedModel.service == service { selectCurrentProvider() }
                }
            }
        }
        let refresh = UUID()
        statusRefresh = refresh
        let updated = await withTaskGroup(of: (AssistantService, AIProviderStatus).self) { group in
            for (service, provider) in providers {
                group.addTask { (service, await provider.status()) }
            }
            var values: [AssistantService: AIProviderStatus] = [:]
            for await (service, status) in group { values[service] = status }
            return values
        }
        guard refresh == statusRefresh, !Task.isCancelled else { return }
        statuses = updated
        prewarm()
    }

    func selectModel(_ id: String) {
        guard !chat.isRunning, id != selectedModelID, enabledIDs.contains(id) else { return }
        selectedModelID = id
        selectCurrentProvider()
        persistModels()
    }

    func setEnabled(_ enabled: Bool, for model: AssistantModel) {
        guard !chat.isRunning else { return }
        if enabled {
            enabledIDs.insert(model.id)
        } else {
            guard enabledIDs.count > 1 else { return }
            enabledIDs.remove(model.id)
            if model.id == selectedModelID, let first = visibleModels.first { selectModel(first.id) }
        }
        persistModels()
    }

    func addModel(alias: String, service: AssistantService) -> Bool {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chat.isRunning, alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$"#, options: .regularExpression) != nil else { return false }
        let model = AssistantModel(service: service, alias: alias, name: alias)
        guard !allModels.contains(where: { $0.id == model.id }) else { return false }
        customModels.append(model)
        setEnabled(true, for: model)
        return true
    }

    func removeModel(_ model: AssistantModel) {
        guard !chat.isRunning, !enabledIDs.contains(model.id) || enabledIDs.count > 1 else { return }
        setEnabled(false, for: model)
        customModels.removeAll { $0.id == model.id }
        persistModels()
    }

    private func persistModels() {
        let defaults = AppDefaults.store
        defaults.set(Array(enabledIDs).sorted(), forKey: "assistantEnabledModels")
        defaults.set(selectedModelID, forKey: "assistantModel")
        defaults.set(try? JSONEncoder().encode(customModels), forKey: "assistantCustomModels")
    }

    private func selectCurrentProvider() {
        let model = selectedModel
        chat.configure(provider: provider, model: model.alias.isEmpty ? nil : model.alias, label: model.label)
        prewarm()
    }

    private func prewarm() {
        if isPanelOpen, isReady { chat.prewarm() }
    }

    func newChat() {
        chat.clear()
        prewarm()
    }

    /// One-shot, tool-free request for an inline edit: low effort, no session left behind.
    func inlineRequest(prompt: String) -> AIRequest {
        let model = selectedModel
        return AIRequest(prompt: prompt, systemPrompt: AIPrompts.inlineSystem, model: model.alias.isEmpty ? nil : model.alias,
                         effort: "low", tools: .none, keepSession: false)
    }

    /// Terminal runs the CLI's interactive browser sign-in. Flotion handles no credentials.
    func openSignIn(_ service: AssistantService) {
        do {
            let command: AICommand?
            if let executable = (providers[service] as? ClaudeCodeProvider)?.executable {
                command = AICommand(executable: executable, arguments: ["auth", "login"], directory: scratch,
                                    environment: AICommand.loginEnvironment(executable: executable))
            } else {
                command = try (providers[service] as? AccountCLIProvider)?.signInCommand()
            }
            guard let command else { return }
            let script = scratch.appendingPathComponent("Sign in to \(service.label).command")
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let environment = command.environment.sorted(by: { $0.key < $1.key }).map { quote("\($0.key)=\($0.value)") }
            let invocation = (["/usr/bin/env", "-i"] + environment + [quote(command.executable.path)] + command.arguments.map(quote))
                .joined(separator: " ")
            let body = """
                #!/bin/zsh
                cd -- \(quote(command.directory.path)) || exit 1
                \(invocation)
                echo
                echo "Return to Flotion and click Check again after signing in."
                """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSSound.beep()
        }
    }

    /// The command that connects an external MCP client (Claude Code) to this workspace.
    var externalConnectCommand: String {
        "claude mcp add flotion -- \"\(serverURL.path)\""
    }

    /// Stands in for Claude in the self-test: a chat turn appends a block the way the model
    /// would through the MCP tools, and an inline edit returns fixed text.
    private static func fakeClaude(workspace: Workspace) -> FakeProvider {
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
}
