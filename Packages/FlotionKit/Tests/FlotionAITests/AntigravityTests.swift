import Foundation
import Testing
@testable import FlotionAI

@Suite struct AntigravityTests {
    @Test func accountDiscoveryAndSignInUseAntigravityWithoutAPrompt() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = try provider(in: folder)
        #expect(await provider.status() == .ready(plan: nil))
        #expect(await provider.availableModels() == [
            AccountModel(id: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)"),
        ])
        let login = try #require(try provider.signInCommand())
        #expect(login.arguments == ["acp", "--login"])
        #expect(login.environment["GEMINI_CLI_HOME"] == nil)
        let messages = try log(in: folder)
        #expect(messages.filter { $0["method"] as? String == "session/prompt" }.isEmpty)
        let setups = messages.filter { $0["method"] as? String == "session/new" }
        #expect(setups.count == 2)
        #expect(setups.allSatisfy {
            (($0["params"] as? [String: Any])?["mcpServers"] as? [[String: Any]])?.isEmpty == true
        })
    }

    @Test func workspaceRequestsAttachFlotionAndRouteModelTextToolsAndPermissions() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = try provider(in: folder)
        let tools = ToolAccess.flotion(server: URL(fileURLWithPath: "/test/Flotion App/flotion-mcp"),
                                       database: URL(fileURLWithPath: "/test/notes.sqlite"), actor: "chat:test-turn")
        let request = AIRequest(prompt: "Add a synthetic note", systemPrompt: "Use Flotion tools.",
                                model: "gemini-3.8-flash-high", tools: tools,
                                history: [AIChatTurn(user: "Previous question", assistant: "Previous reply")])
        var events: [AIEvent] = []
        for await event in provider.run(request) { events.append(event) }
        #expect(events == [
            .started(sessionID: "", model: "gemini-3.8-flash-high"),
            .toolStarted(id: "write", name: "append_blocks"), .toolFinished(id: "write", isError: false),
            .text("Done."), .finished(AIResult(text: "Done.")),
        ])
        let messages = try log(in: folder)
        let setup = try #require(messages.first { $0["method"] as? String == "session/new" })
        let params = try #require(setup["params"] as? [String: Any])
        let servers = try #require(params["mcpServers"] as? [[String: Any]])
        #expect(servers.count == 1)
        #expect(servers[0]["name"] as? String == "flotion")
        #expect(servers[0]["command"] as? String == "/test/Flotion App/flotion-mcp")
        let environment = try #require(servers[0]["env"] as? [[String: String]])
        #expect(environment.contains(["name": "FLOTION_DB", "value": "/test/notes.sqlite"]))
        #expect(environment.contains(["name": "FLOTION_ACTOR", "value": "chat:test-turn"]))
        #expect(messages.contains { $0["method"] as? String == "session/set_model" })
        let prompt = try #require(messages.first { $0["method"] as? String == "session/prompt" })
        let content = try JSONSerialization.data(withJSONObject: prompt)
        #expect(String(decoding: content, as: UTF8.self).contains("Previous reply"))
        let permission = try #require(messages.first { $0["id"] as? String == "permission" })
        let result = try #require(permission["result"] as? [String: Any])
        #expect((result["outcome"] as? [String: String])?["optionId"] == "allow")
        let file = try #require(messages.first { $0["id"] as? String == "file" })
        #expect((file["error"] as? [String: Any])?["code"] as? Int == -32601)
        let shell = try #require(messages.first { $0["id"] as? String == "shell" })
        let shellResult = try #require(shell["result"] as? [String: Any])
        #expect((shellResult["outcome"] as? [String: String])?["optionId"] == "reject")
    }

    @Test func inlineRequestsHaveNoMCPAndRejectWorkspacePermissions() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = try provider(in: folder)
        var result: AIResult?
        for await event in provider.run(AIRequest(prompt: "Shorten this text.", systemPrompt: "Edit only.")) {
            if case .finished(let value) = event { result = value }
        }
        #expect(result?.text == "Done.")
        let messages = try log(in: folder)
        let setup = try #require(messages.first { $0["method"] as? String == "session/new" })
        let params = try #require(setup["params"] as? [String: Any])
        #expect((params["mcpServers"] as? [[String: Any]])?.isEmpty == true)
        let permission = try #require(messages.first { $0["id"] as? String == "permission" })
        let resultObject = try #require(permission["result"] as? [String: Any])
        #expect((resultObject["outcome"] as? [String: String])?["optionId"] == "reject")
    }

    @Test func signedOutAccountsReportTheAuthenticationFailure() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = try script(in: folder, content: """
            import json, sys
            for line in sys.stdin:
                message = json.loads(line)
                print(json.dumps({"id":message["id"], "error":{"code":-32000,"message":"Authentication required"}}), flush=True)
            """)
        let provider = AccountCLIProvider(.agy, executable: binary, directory: folder)
        #expect(await provider.inspect() == AccountInspection(status: .signedOut, models: nil))
        #expect(await provider.status() == .signedOut)
        #expect(await provider.availableModels() == nil)
        var result: AIResult?
        for await event in provider.run(AIRequest(prompt: "test", systemPrompt: "test")) {
            if case .finished(let value) = event { result = value }
        }
        #expect(result?.failure == .notSignedIn)
    }

    @Test func singlePassInspectReturnsStatusAndModelsInOneInvocation() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = try provider(in: folder)
        let inspection = await provider.inspect()
        #expect(inspection == AccountInspection(
            status: .ready(plan: nil),
            models: [AccountModel(id: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)")]
        ))
        let messages = try log(in: folder)
        #expect(messages.filter { $0["method"] as? String == "session/prompt" }.isEmpty)
        let setups = messages.filter { $0["method"] as? String == "session/new" }
        #expect(setups.count == 1)
    }

    @Test func inspectTimeoutAndTransientErrorsDoNotReportSignedOutOrNotInstalled() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let stalled = try script(in: folder, name: "agy-stalled", content: "import time\ntime.sleep(30)")
        let stalledProvider = AccountCLIProvider(.agy, executable: stalled, directory: folder)
        let clock = ContinuousClock()
        let start = clock.now
        let timedOut = await stalledProvider.inspect(timeout: .milliseconds(120))
        let elapsed = start.duration(to: clock.now)
        #expect(timedOut == AccountInspection(status: nil, models: nil))
        #expect(elapsed < .seconds(5))

        let transient = try script(in: folder, name: "agy-transient", content: """
            import json, sys
            for line in sys.stdin:
                message = json.loads(line)
                print(json.dumps({"id":message["id"], "error":{"code":-32603,"message":"Temporary backend error"}}), flush=True)
            """)
        let transientProvider = AccountCLIProvider(.agy, executable: transient, directory: folder)
        #expect(await transientProvider.inspect() == AccountInspection(status: nil, models: nil))

        let disconnected = try script(in: folder, name: "agy-disconnect", content: "import sys\nsys.exit(1)")
        let disconnectedProvider = AccountCLIProvider(.agy, executable: disconnected, directory: folder)
        #expect(await disconnectedProvider.inspect() == AccountInspection(status: nil, models: nil))

        let missingProvider = AccountCLIProvider(.agy, executable: nil, directory: folder)
        #expect(await missingProvider.inspect() == AccountInspection(status: .notInstalled, models: nil))
    }

    @Test func cancellingDiscoveryStopsTheProtocolProcess() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = try script(in: folder, content: "import time\ntime.sleep(30)")
        let provider = AccountCLIProvider(.agy, executable: binary, directory: folder)
        let task = Task { await provider.availableModels() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)

        let inspectTask = Task { await provider.inspect() }
        try await Task.sleep(for: .milliseconds(50))
        inspectTask.cancel()
        #expect(await inspectTask.value == AccountInspection(status: nil, models: nil))
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotion-agy-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func script(in folder: URL, name: String = "agy-stub", content: String) throws -> URL {
        let binary = folder.appendingPathComponent(name)
        try ("#!/usr/bin/python3\n" + content + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary
    }

    private func log(in folder: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: folder.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:]
        }
    }

    private func provider(in folder: URL) throws -> AccountCLIProvider {
        let record = folder.appendingPathComponent("requests.jsonl").path
        let content = #"""
            import json, sys
            assert sys.argv[1:] == ["acp", "--include-default-customizations=false", "--sandbox"]
            def emit(value):
                print(json.dumps(value), flush=True)
            for line in sys.stdin:
                message = json.loads(line)
                with open("#RECORD#", "a") as log:
                    log.write(json.dumps(message) + "\n")
                method = message.get("method")
                if method == "initialize":
                    emit({"id":message["id"],"result":{"protocolVersion":1}})
                elif method == "session/new":
                    emit({"id":message["id"],"result":{"sessionId":"test-session","models":{
                        "currentModelId":"gemini-3.8-flash-high",
                        "availableModels":[{"modelId":"gemini-3.8-flash-high","name":"Gemini 3.8 Flash (High)"}]}}})
                elif method == "session/set_model":
                    assert message["params"]["modelId"] == "gemini-3.8-flash-high"
                    emit({"id":message["id"],"result":{}})
                elif method == "session/prompt":
                    emit({"id":"file","method":"fs/read_text_file","params":{"sessionId":"test-session","path":"/private"}})
                    emit({"id":"shell","method":"session/request_permission","params":{
                        "toolCall":{"name":"run_command","kind":"execute"},
                        "options":[{"kind":"allow_once","optionId":"allow"},{"kind":"reject_once","optionId":"reject"}]}})
                    emit({"id":"permission","method":"session/request_permission","params":{
                        "toolCall":{"name":"mcp_flotion_append_blocks","kind":"other"},
                        "options":[{"kind":"allow_once","optionId":"allow"},{"kind":"reject_once","optionId":"reject"}]}})
                    continue
                elif message.get("id") == "permission":
                    for update in [
                        {"sessionUpdate":"tool_call","toolCallId":"write","name":"mcp_flotion_append_blocks","status":"pending"},
                        {"sessionUpdate":"tool_call_update","toolCallId":"write","status":"completed"},
                        {"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}},
                    ]:
                        emit({"method":"session/update","params":{"sessionId":"test-session","update":update}})
                    emit({"id":3,"result":{"stopReason":"end_turn"}})
            """#.replacingOccurrences(of: "#RECORD#", with: record)
        return AccountCLIProvider(.agy, executable: try script(in: folder, content: content), directory: folder)
    }
}
