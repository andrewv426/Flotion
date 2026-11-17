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

    @Test func geminiUsesOneProfileForGoogleSignInAndHeadlessRequests() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = try stub(in: folder, script: #"""
            [[ "$*" == *"--output-format stream-json"* && "$*" == *"--model selected-model"* ]]
            [[ "$*" != *"Latest question"* && -z "${GEMINI_API_KEY:-}" ]]
            grep -Fq '"enforcedType": "oauth-personal"' "$GEMINI_CLI_HOME/.gemini/settings.json"
            grep -Fq '"core": []' "$GEMINI_CLI_HOME/.gemini/settings.json"
            [[ "$*" == *"--allowed-mcp-server-names flotion-no-mcp"* && ! -f .gemini/settings.json ]]
            input="$(cat)"
            [[ "$input" == *"Latest question"* && "$input" == *"Previous answer"* ]]
            echo '{"type":"init","session_id":"private","model":"selected-model"}'
            echo '{"type":"message","role":"user","content":"ignored echo"}'
            echo '{"type":"message","role":"assistant","content":"Gemini "}'
            echo '{"type":"message","role":"assistant","content":"answer","delta":true}'
            echo '{"type":"result","status":"success"}'
            """#)
        let provider = AccountCLIProvider(.gemini, executable: binary, directory: folder)
        #expect(await provider.status() == .signedOut)
        let signIn = try #require(try provider.signInCommand())
        #expect(signIn.environment["GEMINI_CLI_HOME"] == provider.profile.path)
        try Data().write(to: provider.geminiCredentials)
        #expect(await provider.status() == .ready(plan: nil))
        #expect(await events(provider, request()) == [
            .started(sessionID: "", model: "selected-model"), .text("Gemini "), .text("answer"),
            .finished(AIResult(text: "Gemini answer")),
        ])
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

    @Test func geminiChatScopesConfigAndReadWriteEventsToTheFlotionServer() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directoryRecord = folder.appendingPathComponent("turn-directory")
        let binary = try stub(in: folder, script: #"""
            [[ "$*" == *"--allowed-mcp-server-names flotion --model"* ]]
            grep -Fq '"core": []' "$GEMINI_CLI_HOME/.gemini/settings.json"
            grep -Fq 'toolName = "*"' "$GEMINI_CLI_HOME/.gemini/policies/flotion.toml"
            grep -Fq 'mcpName = "flotion"' "$GEMINI_CLI_HOME/.gemini/policies/flotion.toml"
            grep -Fq '"FLOTION_DB":"/test/my workspace.sqlite"' .gemini/settings.json
            grep -Fq '"FLOTION_ACTOR":"chat:turn-one"' .gemini/settings.json
            grep -Fq '"command":"/test/Flotion Test.app/flotion-mcp"' .gemini/settings.json
            printf '%s' "$PWD" > '#PATH#'
            input="$(cat)"
            [[ "$input" == *"Previous answer"* ]]
            echo '{"type":"tool_use","tool_name":"run_shell_command","tool_id":"shell"}'
            echo '{"type":"tool_result","tool_id":"shell","status":"error"}'
            echo '{"type":"tool_use","tool_name":"mcp_flotion_get_page","tool_id":"read"}'
            echo '{"type":"tool_result","tool_id":"read","status":"success"}'
            echo '{"type":"tool_use","tool_name":"mcp_flotion_update_block","tool_id":"edit"}'
            echo '{"type":"tool_result","tool_id":"edit","status":"success"}'
            echo '{"type":"result","status":"success"}'
            """#.replacingOccurrences(of: "#PATH#", with: directoryRecord.path))
        let provider = AccountCLIProvider(.gemini, executable: binary, directory: folder)
        _ = try provider.signInCommand()
        try Data().write(to: provider.geminiCredentials)
        #expect(await events(provider, request(tools: workspaceTools)) == [
            .toolStarted(id: "read", name: "get_page"), .toolFinished(id: "read", isError: false),
            .toolStarted(id: "edit", name: "update_block"), .toolFinished(id: "edit", isError: false),
            .finished(AIResult(text: "")),
        ])
        let turnDirectory = try String(contentsOf: directoryRecord, encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: turnDirectory))
        let profile = try String(contentsOf: provider.geminiSettings, encoding: .utf8)
        #expect(!profile.contains("FLOTION_DB"))
    }

    @Test func terminalErrorsAndInterruptedStreamsFail() {
        var codex = AccountCLIStream(cli: .codex, model: "")
        _ = codex.consume(Data(#"{"type":"turn.failed","error":{"message":"401 Unauthorized"}}"#.utf8))
        #expect(codex.result(label: "ChatGPT").failure == .notSignedIn)
        var gemini = AccountCLIStream(cli: .gemini, model: "")
        _ = gemini.consume(Data(#"{"type":"message","role":"assistant","content":"unfinished"}"#.utf8))
        #expect(gemini.result(label: "Gemini").failure == .other)
        _ = gemini.consume(Data(#"{"type":"result","status":"error","error":{"message":"quota exceeded"}}"#.utf8))
        #expect(gemini.result(label: "Gemini").failure == .rateLimited)
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
