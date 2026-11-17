import Foundation

struct AntigravityAccountSnapshot: Sendable {
    let status: AIProviderStatus
    let models: [AccountModel]?
}

/// Antigravity's editor protocol supplies account models, streaming replies, and scoped MCP access.
struct AntigravitySession {
    static let arguments = ["acp", "--include-default-customizations=false", "--sandbox"]

    private let process: AIProcess
    private var lines: AsyncStream<Data>.Iterator
    private var sessionID = ""
    private var text = ""
    private var activeTools: [String: String] = [:]
    private var seenTools = Set<String>()
    private var usedTools = false

    private init(_ command: AICommand) throws {
        process = try AIProcess(executable: command.executable, arguments: command.arguments,
                                workingDirectory: command.directory, environment: command.environment)
        lines = process.lines().makeAsyncIterator()
    }

    static func inspect(_ command: AICommand) async -> AntigravityAccountSnapshot {
        await withTaskGroup(of: AntigravityAccountSnapshot.self) { group in
            group.addTask {
                do {
                    var session = try AntigravitySession(command)
                    defer { session.process.terminate() }
                    let setup = try await session.open(directory: command.directory, tools: .none)
                    guard let models = setup["models"] as? [String: Any],
                          let entries = models["availableModels"] as? [[String: Any]] else {
                        return AntigravityAccountSnapshot(status: .ready(plan: nil), models: nil)
                    }
                    let catalog = entries.compactMap { entry -> AccountModel? in
                        guard let id = entry["modelId"] as? String, !id.isEmpty else { return nil }
                        return AccountModel(id: id, name: entry["name"] as? String ?? id)
                    }
                    return AntigravityAccountSnapshot(status: .ready(plan: nil), models: catalog)
                } catch let error as SessionError {
                    return AntigravityAccountSnapshot(status: error.isAuthentication ? .signedOut : .notInstalled, models: nil)
                } catch {
                    return AntigravityAccountSnapshot(status: .notInstalled, models: nil)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return AntigravityAccountSnapshot(status: .signedOut, models: nil)
            }
            let result = await group.next()
            group.cancelAll()
            return result ?? AntigravityAccountSnapshot(status: .signedOut, models: nil)
        }
    }

    static func run(_ command: AICommand, request: AIRequest,
                    continuation: AsyncStream<AIEvent>.Continuation) async -> AIResult {
        do {
            var session = try AntigravitySession(command)
            defer { session.process.terminate() }
            _ = try await session.open(directory: command.directory, tools: request.tools)
            if let model = request.model {
                session.send(id: 2, method: "session/set_model", params: ["sessionId": session.sessionID, "modelId": model])
                _ = try await session.receive(id: 2)
            }
            continuation.yield(.started(sessionID: "", model: request.model ?? ""))
            session.send(id: 3, method: "session/prompt", params: [
                "sessionId": session.sessionID,
                "prompt": [["type": "text", "text": request.systemPrompt + "\n\n" + request.promptWithHistory]],
            ])
            let result = try await session.receive(id: 3, tools: request.tools, continuation: continuation)
            guard result["stopReason"] as? String == "end_turn",
                  session.usedTools || !session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed(.other, "Antigravity ended the request before completing a reply.")
            }
            return AIResult(text: session.text)
        } catch let error as SessionError {
            return .failed(error.failure, error.message)
        } catch {
            return .failed(.other, "Could not start Antigravity. Update Antigravity CLI and try again.")
        }
    }

    private mutating func open(directory: URL, tools: ToolAccess) async throws -> [String: Any] {
        send(id: 0, method: "initialize", params: [
            "protocolVersion": 1,
            "clientInfo": ["name": "flotion", "version": "0.1.0"],
            "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": true],
        ])
        _ = try await receive(id: 0)
        var servers: [[String: Any]] = []
        if case .flotion(let server, let database, let actor) = tools {
            servers = [["name": "flotion", "command": server.path, "args": [],
                        "env": [["name": "FLOTION_DB", "value": database.path],
                                ["name": "FLOTION_ACTOR", "value": actor]]]]
        }
        send(id: 1, method: "session/new", params: ["cwd": directory.path, "mcpServers": servers])
        let result = try await receive(id: 1)
        guard let id = result["sessionId"] as? String else {
            throw SessionError(code: 0, message: "Antigravity did not create a session.")
        }
        sessionID = id
        return result
    }

    private func send(id: Int, method: String, params: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        process.send(data)
    }

    private mutating func receive(id: Int, tools: ToolAccess = .none,
                                  continuation: AsyncStream<AIEvent>.Continuation? = nil) async throws -> [String: Any] {
        while let line = await lines.next() {
            try Task.checkCancellation()
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                if let requestID = message["id"] {
                    respond(to: method, id: requestID, params: params, tools: tools)
                } else if method == "session/update", params["sessionId"] as? String == sessionID,
                          let update = params["update"] as? [String: Any] {
                    consume(update, tools: tools, continuation: continuation)
                }
                continue
            }
            guard message["id"] as? Int == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw SessionError(code: error["code"] as? Int ?? 0,
                                   message: error["message"] as? String ?? "Antigravity could not complete the request.")
            }
            guard let result = message["result"] as? [String: Any] else {
                throw SessionError(code: 0, message: "Antigravity returned an invalid response.")
            }
            return result
        }
        throw SessionError(code: 0, message: "Antigravity disconnected before completing the request.")
    }

    private func respond(to method: String, id: Any, params: [String: Any], tools: ToolAccess) {
        if method == "session/request_permission" {
            let call = params["toolCall"] as? [String: Any] ?? [:]
            let options = params["options"] as? [[String: Any]] ?? []
            let allowed = toolName(call, tools: tools) != nil
            let option = options.first { $0["kind"] as? String == (allowed ? "allow_once" : "reject_once") }
            let outcome: [String: Any] = option.flatMap { $0["optionId"] as? String }
                .map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
            write(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
        } else {
            // Antigravity delegates filesystem and terminal operations to this client.
            write(["jsonrpc": "2.0", "id": id,
                   "error": ["code": -32601, "message": "Flotion provides workspace access through its MCP server."]])
        }
    }

    private mutating func consume(_ update: [String: Any], tools: ToolAccess,
                                  continuation: AsyncStream<AIEvent>.Continuation?) {
        let kind = update["sessionUpdate"] as? String
        if kind == "agent_message_chunk", let content = update["content"] as? [String: Any],
           content["type"] as? String == "text", let piece = content["text"] as? String {
            text += piece
            continuation?.yield(.text(piece))
        }
        guard kind == "tool_call" || kind == "tool_call_update",
              let id = update["toolCallId"] as? String else { return }
        if !seenTools.contains(id), let name = toolName(update, tools: tools) {
            seenTools.insert(id)
            activeTools[id] = name
            usedTools = true
            continuation?.yield(.toolStarted(id: id, name: name))
        }
        if let status = update["status"] as? String, ["completed", "failed"].contains(status),
           activeTools.removeValue(forKey: id) != nil {
            continuation?.yield(.toolFinished(id: id, isError: status == "failed"))
        }
    }

    private func toolName(_ call: [String: Any], tools: ToolAccess) -> String? {
        guard case .flotion = tools else { return nil }
        let input = call["rawInput"] as? [String: Any] ?? [:]
        let names = [call["name"], input["name"], input["toolName"], call["title"]].compactMap { $0 as? String }
        let available: Set<String> = ["search_pages", "list_pages", "get_page", "create_page", "update_page",
                                      "append_blocks", "update_block", "delete_block", "archive_page",
                                      "create_diagram", "get_diagram", "update_diagram"]
        for name in names {
            for prefix in ["mcp__flotion__", "mcp_flotion_", "flotion__", "flotion/", "flotion."] where name.hasPrefix(prefix) {
                let tool = String(name.dropFirst(prefix.count))
                if available.contains(tool) { return tool }
            }
            if available.contains(name) { return name }
        }
        return nil
    }

    private struct SessionError: Error {
        let code: Int
        let message: String

        var isAuthentication: Bool {
            code == -32000 || ["auth_required", "authentication required", "sign in", "unauthorized"]
                .contains { message.lowercased().contains($0) }
        }

        var failure: AIFailure {
            if isAuthentication { return .notSignedIn }
            if ["rate limit", "quota", "resource_exhausted", "429"].contains(where: message.lowercased().contains) {
                return .rateLimited
            }
            return .other
        }
    }
}
