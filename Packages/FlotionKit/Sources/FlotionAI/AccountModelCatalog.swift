import Foundation

public struct AccountModel: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name.isEmpty ? id : name
    }
}

extension AccountCLIProvider {
    /// Fetches the CLI's picker catalog using the existing sign-in, without a model turn.
    public func availableModels() async -> [AccountModel]? {
        guard let executable else { return nil }
        return await withTaskGroup(of: [AccountModel]?.self) { group in
            group.addTask {
                do {
                    try prepareDirectory()
                    return try await loadCatalog(executable)
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil
            }
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }

    private func loadCatalog(_ executable: URL) async throws -> [AccountModel]? {
        guard !Task.isCancelled else { return nil }
        let arguments = cli == .codex
            ? ["app-server", "--listen", "stdio://", "-c", "model_provider=\"openai\"",
               "-c", "forced_login_method=\"chatgpt\"", "-c", "cli_auth_credentials_store=\"auto\"",
               "-c", "mcp_servers={}", "--disable", "hooks", "--disable", "plugins", "--disable", "apps"]
            : ["--list-models", "--output-format", "json"]
        let command = command(executable, arguments)
        let process = try AIProcess(executable: command.executable, arguments: command.arguments,
                                    workingDirectory: command.directory, environment: command.environment)
        defer { process.terminate() }
        if cli == .codex {
            return await codexCatalog(process)
        }
        let lines = process.lines()
        process.closeInput()
        var output = Data()
        for await line in lines {
            output.append(line)
            output.append(0x0A)
        }
        guard !Task.isCancelled else { return nil }
        let models = try JSONDecoder().decode([GeminiCatalogModel].self, from: output)
        return models.map { AccountModel(id: $0.modelId, name: $0.displayName ?? $0.name ?? $0.modelId) }
    }
}

private struct GeminiCatalogModel: Decodable {
    let modelId: String
    let displayName: String?
    let name: String?
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
