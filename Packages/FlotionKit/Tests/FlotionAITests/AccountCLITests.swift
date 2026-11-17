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

    private func request() -> AIRequest {
        AIRequest(prompt: "Latest question", systemPrompt: "System instructions", model: "selected-model",
                  history: [AIChatTurn(user: "Previous question", assistant: "Previous answer")])
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
