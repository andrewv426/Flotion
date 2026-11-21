import Foundation

public struct AccountModel: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name.isEmpty ? id : name
    }
}

/// The result of inspecting an account-authenticated CLI provider.
/// `status == nil` means the probe timed out or failed transiently rather than reporting a definitive state.
public struct AccountInspection: Equatable, Sendable {
    public let status: AIProviderStatus?
    public let models: [AccountModel]?

    public init(status: AIProviderStatus?, models: [AccountModel]?) {
        self.status = status
        self.models = models
    }
}

extension AccountCLIProvider {
    /// Checks sign-in status and fetches the account model catalog in a single pass when supported.
    public func inspect(timeout: Duration = .seconds(15)) async -> AccountInspection {
        guard let executable else { return AccountInspection(status: .notInstalled, models: nil) }
        if cli == .agy {
            do {
                try prepareDirectory()
                return await AntigravitySession.inspect(command(executable, AntigravitySession.arguments), timeout: timeout)
            } catch {
                return AccountInspection(status: nil, models: nil)
            }
        }
        let status = await probeStatus(timeout: timeout)
        guard case .ready = status else {
            return AccountInspection(status: status, models: nil)
        }
        let models = await availableModels(timeout: timeout)
        return AccountInspection(status: status, models: models)
    }

    /// Fetches the CLI's picker catalog using the existing sign-in, without a model turn.
    public func availableModels(timeout: Duration = .seconds(15)) async -> [AccountModel]? {
        guard let executable else { return nil }
        if cli == .agy {
            return await inspect(timeout: timeout).models
        }
        return await withTaskGroup(of: [AccountModel]?.self) { group in
            group.addTask {
                do {
                    try Task.checkCancellation()
                    try prepareDirectory()
                    return try await loadCatalog(executable)
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }

    private func loadCatalog(_ executable: URL) async throws -> [AccountModel]? {
        guard !Task.isCancelled else { return nil }
        let arguments = ["app-server", "--listen", "stdio://", "-c", "model_provider=\"openai\"",
               "-c", "forced_login_method=\"chatgpt\"", "-c", "cli_auth_credentials_store=\"auto\"",
               "-c", "mcp_servers={}", "--disable", "hooks", "--disable", "plugins", "--disable", "apps"]
        let command = command(executable, arguments)
        let process = try AIProcess(executable: command.executable, arguments: command.arguments,
                                    workingDirectory: command.directory, environment: command.environment)
        defer { process.terminate() }
        return await codexCatalog(process)
    }
}
private struct CodexCatalogPage: Decodable {
    struct Entry: Decodable {
        let model: String
        let displayName: String
        let hidden: Bool?
    }
    let data: [Entry]
    let nextCursor: String?
}

private func codexCatalog(_ process: AIProcess) async -> [AccountModel]? {
    struct Response: Decodable {
        let result: CodexCatalogPage
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        process.send(data)
    }

    let lines = process.lines()
    send(["id": 0, "method": "initialize", "params": [
        "clientInfo": ["name": "flotion", "title": "Flotion", "version": "0.1.0"],
    ]])
    var requestID = 0
    var cursors = Set<String>()
    var models: [AccountModel] = []
    for await line in lines {
        if Task.isCancelled { return nil }
        guard let header = try? JSONDecoder().decode(CodexCatalogReplyID.self, from: line),
              header.id == requestID else { continue }
        var params: [String: Any] = ["includeHidden": false]
        if requestID == 0 {
            guard header.error == nil else { return nil }
            send(["method": "initialized"])
        } else {
            guard let page = try? JSONDecoder().decode(Response.self, from: line).result else { return nil }
            models += page.data.filter { $0.hidden != true }.map { AccountModel(id: $0.model, name: $0.displayName) }
            guard let cursor = page.nextCursor else { return models }
            guard cursors.insert(cursor).inserted else { return nil }
            params["cursor"] = cursor
        }
        requestID += 1
        send(["id": requestID, "method": "model/list", "params": params])
    }
    return nil
}

private struct CodexCatalogReplyID: Decodable {
    let id: Int
    let error: RPCError?

    struct RPCError: Decodable { let code: Int }
}
