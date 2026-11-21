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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshToken = UUID()
    @ObservationIgnored private var lastRefreshCompletedAt: ContinuousClock.Instant?
    @ObservationIgnored private var configuredModel: AssistantModel?
    @ObservationIgnored private var knownCatalogIDs: Set<String>
    private static let refreshCooldown: Duration = .seconds(45)

    private struct CachedModel: Decodable {
        let service: String
        let alias: String
        let name: String
    }

    private(set) var statuses: [AssistantService: AIProviderStatus] = [:]
    private(set) var modelCatalogs: [AssistantService: [AssistantModel]] = [:]
    private(set) var loadingModelCatalogs: Set<AssistantService> = []
    /// Providers whose last status check timed out or failed before reporting a state.
    private(set) var failedStatusChecks: Set<AssistantService> = []
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

    var allModels: [AssistantModel] {
        var seen = Set<String>()
        let discovered = AssistantService.allCases.flatMap { modelCatalogs[$0] ?? [] }
        return (AssistantModel.suggested + customModels + discovered).filter { seen.insert($0.id).inserted }
    }
    var visibleModels: [AssistantModel] {
        let visible = allModels.filter { enabledIDs.contains($0.id) }
        return visible.isEmpty ? [.claudeDefault] : visible
    }
    var selectedModel: AssistantModel {
        let visible = visibleModels
        return visible.first { $0.id == selectedModelID } ?? visible[0]
    }
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
        func migratedID(_ id: String) -> String {
            id.hasPrefix("gemini:") ? "antigravity:" : id
        }
        let previousID = migratedID(defaults.string(forKey: "assistantModel") ?? legacy.id)
        var models = savedModels.filter { !AssistantModel.suggested.contains($0) }
        if defaults.string(forKey: "assistantModel") == nil,
           !(AssistantModel.suggested + models).contains(where: { $0.id == legacy.id }) {
            models.append(legacy)
        }
        let cachedCatalogs: [AssistantService: [AssistantModel]] = {
            guard let data = defaults.data(forKey: "assistantCachedCatalogs"),
                  let decoded = try? JSONDecoder().decode([String: [CachedModel]].self, from: data) else { return [:] }
            var catalogs: [AssistantService: [AssistantModel]] = [:]
            for (key, entries) in decoded {
                guard let service = AssistantService(rawValue: key) else { continue }
                var seen = Set<String>()
                catalogs[service] = entries.compactMap { entry in
                    guard entry.service == key, !entry.alias.isEmpty else { return nil }
                    let item = AssistantModel(service: service, alias: entry.alias,
                                              name: entry.name.isEmpty ? entry.alias : entry.name)
                    return seen.insert(item.id).inserted ? item : nil
                }
            }
            return catalogs
        }()
        let discovered = AssistantService.allCases.flatMap { cachedCatalogs[$0] ?? [] }
        let allModels = AssistantModel.suggested + models + discovered
        let enabled = Set((defaults.stringArray(forKey: "assistantEnabledModels") ?? allModels.filter { $0.service == .claude }.map(\.id)).map(migratedID))
        let visible = allModels.filter { enabled.contains($0.id) }
        let initialID = enabled.contains(previousID) ? previousID : (visible.first ?? .claudeDefault).id
        knownCatalogIDs = Set((defaults.stringArray(forKey: "assistantKnownCatalogIDs") ?? []).filter { !$0.hasPrefix("gemini:") })
        modelCatalogs = cachedCatalogs
        customModels = models
        enabledIDs = enabled.isEmpty ? [initialID] : enabled
        selectedModelID = initialID
        let claude: any AIProvider = usesFakeProviders
            ? Self.fakeProvider(workspace: workspace, sessionID: "fake-session") : ClaudeCodeProvider(workingDirectory: scratch)
        chat = ChatSession(provider: claude, workspace: workspace, server: serverURL)
        providers[.claude] = claude
        for (service, cli) in [(AssistantService.openAI, AccountCLIProvider.CLI.codex), (.antigravity, .agy)] {
            providers[service] = usesFakeProviders
                ? Self.fakeProvider(workspace: workspace, sessionID: nil)
                : AccountCLIProvider(cli, directory: scratch)
        }
        selectCurrentProvider()
        persistModels()
    }

    func refreshStatus(force: Bool = false) async {
        if !force {
            if let task = refreshTask {
                await task.value
                return
            }
            if !usesFakeProviders,
               let last = lastRefreshCompletedAt,
               last.duration(to: ContinuousClock().now) < Self.refreshCooldown {
                return
            }
        } else {
            refreshTask?.cancel()
            refreshTask = nil
            if !loadingModelCatalogs.isEmpty {
                loadingModelCatalogs.removeAll()
            }
        }

        let token = UUID()
        refreshToken = token
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(token: token)
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(token: UUID) async {
        defer {
            if refreshToken == token {
                refreshTask = nil
                if !Task.isCancelled {
                    lastRefreshCompletedAt = ContinuousClock().now
                }
            }
        }
        if !usesFakeProviders && !chat.isRunning {
            let claude = ClaudeCLI.locate()
            if (providers[.claude] as? ClaudeCodeProvider)?.executable != claude {
                providers[.claude] = ClaudeCodeProvider(executable: claude, workingDirectory: scratch)
                if selectedModel.service == .claude { selectCurrentProvider() }
            }
            for (service, cli) in [(AssistantService.openAI, AccountCLIProvider.CLI.codex), (.antigravity, .agy)] {
                if (providers[service] as? AccountCLIProvider)?.executable != AccountCLIProvider.locate(cli) {
                    providers[service] = AccountCLIProvider(cli, directory: scratch)
                    if selectedModel.service == service { selectCurrentProvider() }
                }
            }
        }

        let snapshot = providers
        if usesFakeProviders {
            await withTaskGroup(of: (AssistantService, AIProviderStatus?).self) { group in
                for (service, provider) in snapshot {
                    group.addTask { (service, await provider.probeStatus()) }
                }
                for await (service, status) in group {
                    guard refreshToken == token, !Task.isCancelled else { return }
                    if let status { setStatus(status, for: service) }
                }
            }
            guard refreshToken == token, !Task.isCancelled else { return }
            prewarm()
            applyCatalog([AccountModel(id: "codex-test", name: "Codex Test")], for: .openAI)
            applyCatalog([AccountModel(id: "agy-test", name: "Antigravity Test")], for: .antigravity)
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for (service, provider) in snapshot {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.refreshProvider(service: service, provider: provider, token: token)
                }
            }
        }
    }

    private func refreshProvider(service: AssistantService, provider: any AIProvider, token: UUID) async {
        defer {
            if refreshToken == token {
                setLoadingCatalog(false, for: service)
            }
        }
        if let account = provider as? AccountCLIProvider {
            if account.cli == .agy {
                if statuses[service] != nil && modelCatalogs[service] == nil {
                    setLoadingCatalog(true, for: service)
                }
                let inspection = await account.inspect()
                guard refreshToken == token, !Task.isCancelled else { return }
                applyInspection(inspection, for: service)
                return
            }
            let status = await account.probeStatus()
            guard refreshToken == token, !Task.isCancelled else { return }
            guard let status else { return markStatusCheckFailed(for: service) }
            setStatus(status, for: service)
            guard case .ready = status else {
                clearCatalog(for: service)
                return
            }
            if selectedModel.service == service { prewarm() }
            if modelCatalogs[service] == nil {
                setLoadingCatalog(true, for: service)
            }
            let models = await account.availableModels()
            guard refreshToken == token, !Task.isCancelled else { return }
            applyCatalog(models, for: service)
            return
        }

        let status = await provider.probeStatus()
        guard refreshToken == token, !Task.isCancelled else { return }
        guard let status else { return markStatusCheckFailed(for: service) }
        setStatus(status, for: service)
        if case .ready = status, selectedModel.service == service {
            prewarm()
        }
    }

    /// Applies one provider inspection. A missing status is transient: the last known status and catalog stay.
    func applyInspection(_ inspection: AccountInspection, for service: AssistantService) {
        guard let status = inspection.status else { return markStatusCheckFailed(for: service) }
        setStatus(status, for: service)
        guard case .ready = status else {
            clearCatalog(for: service)
            return
        }
        applyCatalog(inspection.models, for: service)
        if selectedModel.service == service { prewarm() }
    }

    /// Replaces a provider's discovered models. `nil` means the fetch failed, so the cached catalog stays.
    func applyCatalog(_ models: [AccountModel]?, for service: AssistantService) {
        guard let models else { return }
        let previousModel = selectedModel
        let existingIDs = Set((AssistantModel.suggested + customModels).map(\.id))
        var seen = Set<String>()
        let discovered = models.compactMap { model -> AssistantModel? in
            guard !model.id.isEmpty else { return nil }
            let item = AssistantModel(service: service, alias: model.id, name: model.name)
            return seen.insert(item.id).inserted ? item : nil
        }
        let catalogChanged = modelCatalogs[service] != discovered
        if catalogChanged {
            modelCatalogs[service] = discovered
        }
        var updatedEnabled = enabledIDs
        var knownChanged = false
        for model in discovered where knownCatalogIDs.insert(model.id).inserted {
            knownChanged = true
            if !existingIDs.contains(model.id) { updatedEnabled.insert(model.id) }
        }
        let enabledChanged = updatedEnabled != enabledIDs
        if enabledChanged {
            enabledIDs = updatedEnabled
        }
        if catalogChanged || enabledChanged || knownChanged {
            persistModels()
        }
        if selectedModel != previousModel { selectCurrentProvider() }
    }

    private func clearCatalog(for service: AssistantService) {
        guard modelCatalogs[service] != nil else { return }
        let previousModel = selectedModel
        modelCatalogs.removeValue(forKey: service)
        persistModels()
        if selectedModel != previousModel { selectCurrentProvider() }
    }

    private func setStatus(_ status: AIProviderStatus, for service: AssistantService) {
        if failedStatusChecks.contains(service) { failedStatusChecks.remove(service) }
        guard statuses[service] != status else { return }
        statuses[service] = status
    }

    private func markStatusCheckFailed(for service: AssistantService) {
        if !failedStatusChecks.contains(service) { failedStatusChecks.insert(service) }
    }

    private func setLoadingCatalog(_ loading: Bool, for service: AssistantService) {
        if loading {
            guard !loadingModelCatalogs.contains(service) else { return }
            loadingModelCatalogs.insert(service)
        } else {
            guard loadingModelCatalogs.contains(service) else { return }
            loadingModelCatalogs.remove(service)
        }
    }

    func selectModel(_ id: String) {
        guard !chat.isRunning, id != selectedModelID, visibleModels.contains(where: { $0.id == id }) else { return }
        if !enabledIDs.contains(id) { enabledIDs.insert(id) }
        selectedModelID = id
        selectCurrentProvider()
        persistModels()
    }

    func setEnabled(_ enabled: Bool, for model: AssistantModel) {
        guard !chat.isRunning else { return }
        if enabled {
            guard !enabledIDs.contains(model.id) else { return }
            enabledIDs.insert(model.id)
        } else {
            guard enabledIDs.contains(model.id), visibleModels.count > 1 else { return }
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
        guard !chat.isRunning, !enabledIDs.contains(model.id) || visibleModels.count > 1 else { return }
        setEnabled(false, for: model)
        customModels.removeAll { $0.id == model.id }
        persistModels()
    }

    private func persistModels() {
        let defaults = AppDefaults.store
        defaults.set(Array(enabledIDs).sorted(), forKey: "assistantEnabledModels")
        defaults.set(Array(knownCatalogIDs).sorted(), forKey: "assistantKnownCatalogIDs")
        defaults.set(selectedModelID, forKey: "assistantModel")
        defaults.set(try? JSONEncoder().encode(customModels), forKey: "assistantCustomModels")
        let catalogs = Dictionary(uniqueKeysWithValues: modelCatalogs.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(catalogs), forKey: "assistantCachedCatalogs")
    }

    private func selectCurrentProvider() {
        guard !chat.isRunning else { return }
        let model = selectedModel
        configuredModel = model
        chat.configure(provider: provider, model: model.alias.isEmpty ? nil : model.alias, label: model.label)
        prewarm()
    }

    private func prewarm() {
        if isPanelOpen, isReady, configuredModel == selectedModel { chat.prewarm() }
    }

    func send(_ text: String, context: PageContext?) {
        if configuredModel != selectedModel { selectCurrentProvider() }
        chat.send(text, context: context)
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
            lastRefreshCompletedAt = nil
        } catch {
            NSSound.beep()
        }
    }

    /// The command that connects an external MCP client (Claude Code) to this workspace.
    var externalConnectCommand: String {
        "claude mcp add flotion -- \"\(serverURL.path)\""
    }

    /// Simulates an MCP edit in the self-test. A tool-free inline edit returns a preview.
    private static func fakeProvider(workspace: Workspace, sessionID: String?) -> FakeProvider {
        FakeProvider { request in
            guard case .flotion(_, _, let actor) = request.tools else {
                return [.started(sessionID: "", model: "fake"), .text("A shorter "), .text("**sentence**."),
                        .finished(AIResult(text: "A shorter **sentence**."))]
            }
            var events: [AIEvent] = [.started(sessionID: sessionID ?? "", model: "fake")]
            if let range = request.prompt.range(of: "page_id: ") {
                let pageID = String(request.prompt[range.upperBound...].prefix { $0 != ")" })
                events.append(.toolStarted(id: "t1", name: "append_blocks"))
                _ = try? workspace.insertBlocks(pageID: pageID, MarkdownCodec.parse("Summary added by the assistant."),
                                                context: ChangeContext(actor: actor))
                events.append(.toolFinished(id: "t1", isError: false))
            }
            events += [.text("Added a summary "), .text("to the end of the page."),
                       .finished(AIResult(text: "Added a summary to the end of the page.", sessionID: sessionID))]
            return events
        }
    }
}
