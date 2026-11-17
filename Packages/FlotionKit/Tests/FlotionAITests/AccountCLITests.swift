import Foundation
import Testing
@testable import FlotionAI

@Suite struct AccountCLITests {
    @Test func accountCommandsDiscardInheritedCredentialsAndEndpoints() {
        let environment = AICommand.loginEnvironment(executable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), inherited: [
            "OPENAI_API_KEY": "key", "CODEX_API_KEY": "key", "CODEX_HOME": "/wrong/profile",
            "GEMINI_API_KEY": "key", "GOOGLE_API_KEY": "key", "GOOGLE_APPLICATION_CREDENTIALS": "file",
            "OPENAI_BASE_URL": "endpoint", "GOOGLE_GENAI_USE_VERTEXAI": "true", "LANG": "en_US.UTF-8",
        ])
        #expect(Set(environment.keys) == ["HOME", "PATH", "TERM", "LANG"])
        #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    @Test func codexUsesChatGPTStatusAndReceivesContextThroughStdin() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = try stub(in: folder, script: #"""
            if [[ "$1 $2" == "login status" ]]; then
                echo "Logged in using ChatGPT" >&2
                exit 0
            fi
            [[ "$*" == *"--ignore-user-config"* && "$*" == *"--ignore-rules"* ]]
            [[ "$*" == *"--disable shell_tool"* && "$*" == *"--sandbox read-only"* ]]
            [[ "$*" == *'forced_login_method="chatgpt"'* && "$*" == *"--model selected-model -"* ]]
            [[ "$*" == *'mcp_servers={}'* ]]
            [[ "$*" != *"Latest question"* && -z "${OPENAI_API_KEY:-}" ]]
            input="$(cat)"
            [[ "$input" == *"Latest question"* && "$input" == *"Previous answer"* ]]
            echo '{"type":"thread.started","thread_id":"native-id"}'
            echo '{"type":"item.completed","item":{"type":"agent_message","text":"Codex answer"}}'
            echo '{"type":"turn.completed"}'
            """#)
        let provider = AccountCLIProvider(.codex, executable: binary, directory: folder)
        #expect(await provider.status() == .ready(plan: nil))
        let signIn = try #require(try provider.signInCommand())
        #expect(signIn.arguments.first == "login")
        #expect(signIn.arguments.contains("forced_login_method=\"chatgpt\""))
        #expect(await events(provider, request()) == [
            .started(sessionID: "", model: "selected-model"), .text("Codex answer"), .finished(AIResult(text: "Codex answer")),
        ])
    }

    @Test func codexRejectsAnExistingAPIKeyLogin() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = try stub(in: folder, script: #"echo "Logged in using an API key""#)
        let provider = AccountCLIProvider(.codex, executable: binary, directory: folder)
        #expect(await provider.status() == .signedOut)
        #expect(await events(provider, request()).last == .finished(.failed(.notSignedIn, "Sign in to ChatGPT in the CLI.")))
    }

    @Test func codexListsVisibleModelsAcrossCatalogPagesWithoutStartingATurn() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = try stub(in: folder, script: #"""
            [[ "$1" == "app-server" && "$*" == *'forced_login_method="chatgpt"'* ]]
            read -r line
            [[ "$line" == *'"initialize"'* ]]
            echo '{"id":0,"result":{"userAgent":"codex"}}'
            read -r line
            [[ "$line" == *'"initialized"'* ]]
            read -r line
            [[ "$line" == *'"model/list"'* ]]
            echo '{"id":1,"result":{"data":[{"model":"first","displayName":"First"},{"model":"hidden","displayName":"Hidden","hidden":true}],"nextCursor":"second page"}}'
            read -r line
            [[ "$line" == *'"second page"'* && "$line" == *'"model/list"'* ]]
            echo '{"id":2,"result":{"data":[{"model":"second","displayName":"Second"}],"nextCursor":null}}'
            """#)
        let provider = AccountCLIProvider(.codex, executable: binary, directory: folder)
        #expect(await provider.availableModels() == [
            AccountModel(id: "first", name: "First"), AccountModel(id: "second", name: "Second"),
        ])
    }

    @Test func catalogErrorsAndCancellationReturnWithoutInventingModels() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rejected = try stub(in: folder, script: #"""
            read -r line
            echo '{"id":0,"error":{"code":-32600,"message":"Sign in required"}}'
            """#)
        let provider = AccountCLIProvider(.codex, executable: rejected, directory: folder)
        #expect(await provider.availableModels() == nil)
        let sleeping = try stub(in: folder, script: "exec /bin/sleep 30")
        let stalled = AccountCLIProvider(.codex, executable: sleeping, directory: folder)
        let task = Task { await stalled.availableModels() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func codexChatExposesOnlyTheFlotionServerAndReportsToolProgress() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = try stub(in: folder, script: #"""
            if [[ "$1 $2" == "login status" ]]; then
                echo "Logged in using ChatGPT"
                exit 0
            fi
            [[ "$*" == *'mcp_servers={ flotion={ command="/test/Flotion Test.app/flotion-mcp", required=true'* ]]
            [[ "$*" == *'default_tools_approval_mode="approve"'* ]]
            [[ "$*" == *'FLOTION_DB="/test/my workspace.sqlite", FLOTION_ACTOR="chat:turn-one"'* ]]
            input="$(cat)"
            [[ "$input" == *"Previous answer"* ]]
            echo '{"type":"item.started","item":{"id":"other","type":"mcp_tool_call","server":"other","tool":"write","status":"in_progress"}}'
            echo '{"type":"item.started","item":{"id":"read","type":"mcp_tool_call","server":"flotion","tool":"get_page","status":"in_progress"}}'
            echo '{"type":"item.completed","item":{"id":"read","type":"mcp_tool_call","server":"flotion","tool":"get_page","status":"completed"}}'
            echo '{"type":"item.completed","item":{"id":"edit","type":"mcp_tool_call","server":"flotion","tool":"update_block","status":"failed","error":{"message":"bad block"}}}'
            echo '{"type":"item.completed","item":{"type":"agent_message","text":"The edit failed."}}'
            echo '{"type":"turn.completed"}'
            """#)
        let provider = AccountCLIProvider(.codex, executable: binary, directory: folder)
        #expect(await events(provider, request(tools: workspaceTools)) == [
            .toolStarted(id: "read", name: "get_page"), .toolFinished(id: "read", isError: false),
            .toolStarted(id: "edit", name: "update_block"), .toolFinished(id: "edit", isError: true),
            .text("The edit failed."), .finished(AIResult(text: "The edit failed.")),
        ])
    }

    @Test func terminalErrorsAndInterruptedStreamsFail() {
        var codex = AccountCLIStream(cli: .codex, model: "")
        _ = codex.consume(Data(#"{"type":"turn.failed","error":{"message":"401 Unauthorized"}}"#.utf8))
        #expect(codex.result(label: "ChatGPT").failure == .notSignedIn)

    }

    private var workspaceTools: ToolAccess {
        .flotion(server: URL(fileURLWithPath: "/test/Flotion Test.app/flotion-mcp"),
                 database: URL(fileURLWithPath: "/test/my workspace.sqlite"), actor: "chat:turn-one")
    }

    private func request(tools: ToolAccess = .none) -> AIRequest {
        AIRequest(prompt: "Latest question", systemPrompt: "System instructions", model: "selected-model",
                  tools: tools, history: [AIChatTurn(user: "Previous question", assistant: "Previous answer")])
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotion-cli-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func stub(in folder: URL, script: String) throws -> URL {
        let binary = folder.appendingPathComponent("stub")
        try ("#!/bin/bash\nset -eu\n" + script + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary
    }

    private func events(_ provider: AccountCLIProvider, _ request: AIRequest) async -> [AIEvent] {
        var all: [AIEvent] = []
        for await event in provider.run(request) { all.append(event) }
        return all
    }
}
