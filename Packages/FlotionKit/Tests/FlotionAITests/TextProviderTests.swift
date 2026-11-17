import Foundation
import Testing
@testable import FlotionAI

@Suite struct TextProviderTests {
    @Test(arguments: [ChatCompletionsProvider.Service.openAI, .gemini, .grok])
    func chatCompletionsUsesTheExpectedEndpointAndRoles(_ service: ChatCompletionsProvider.Service) throws {
        let provider = ChatCompletionsProvider(service: service, apiKey: "test-key")
        let request = AIRequest(prompt: "latest", systemPrompt: "instructions", model: "selected",
                                resumeSessionID: "private-session", history: [AIChatTurn(user: "old question", assistant: "old reply")])
        let http = try #require(try provider.urlRequest(request))
        let endpoints: [ChatCompletionsProvider.Service: String] = [
            .openAI: "https://api.openai.com/v1/chat/completions",
            .gemini: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            .grok: "https://api.x.ai/v1/chat/completions",
        ]
        #expect(http.url?.absoluteString == endpoints[service])
        #expect(http.httpMethod == "POST")
        #expect(http.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let bodyData = try #require(http.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "selected")
        #expect(body["stream"] as? Bool == true)
        #expect(body["messages"] as? [[String: String]] == [
            ["role": "system", "content": "instructions"],
            ["role": "user", "content": "old question"],
            ["role": "assistant", "content": "old reply"],
            ["role": "user", "content": "latest"],
        ])
        #expect(!String(decoding: bodyData, as: UTF8.self).contains("private-session"))
    }

    @Test func streamParsesVisibleTextAndRejectsInterruptedResponses() {
        var stream = CompletionStream()
        #expect(stream.consume(": keepalive") == nil)
        #expect(stream.consume(#"data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}"#) == nil)
        #expect(stream.consume(#"data: {"choices":[{"delta":{"content":"Hello"}}]}"#) == "Hello")
        #expect(stream.result().failure == .other)
        #expect(stream.consume(#"data: {"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}"#) == " world")
        #expect(stream.consume("data: [DONE]") == nil)
        #expect(stream.ended)
        #expect(stream.result() == AIResult(text: "Hello world"))

        var error = CompletionStream()
        _ = error.consume(#"data: {"error":{"message":"server error"}}"#)
        #expect(error.ended && error.result().failure == .other)
    }

    @Test func missingAPIKeyFailsBeforeMakingARequest() async {
        let provider = ChatCompletionsProvider(service: .openAI, apiKey: nil)
        #expect(await provider.status() == .signedOut)
        var events: [AIEvent] = []
        for await event in provider.run(AIRequest(prompt: "hello", systemPrompt: "system", model: "gpt")) {
            events.append(event)
        }
        #expect(events == [.finished(.failed(.notSignedIn, "Add your OpenAI API key."))])
    }

    @Test func cursorRunsInAskModeWithAnIsolatedWorkspaceAndConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flotion-cursor-stub-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("cursor-agent")
        let stub = #"""
        #!/bin/bash
        set -eu
        [[ "$CURSOR_API_KEY" == "stub-key" ]]
        [[ "$PWD" == "$HOME/workspace" && -z "$(ls -A)" ]]
        [[ "$CURSOR_CONFIG_DIR" == "$HOME/config" ]]
        grep -q '"readBoundary": "workspace"' "$CURSOR_CONFIG_DIR/cli-config.json"
        grep -Fq '"Mcp(*:*)"' "$CURSOR_CONFIG_DIR/cli-config.json"
        [[ "$*" == *"--print --mode ask --sandbox enabled --output-format stream-json"* ]]
        [[ "$*" == *"--model composer-2 -- "* ]]
        [[ "${!#}" == *'"assistant":"first reply"'* && "${!#}" == *"latest turn text" ]]
        printf '%s' '{"type":"result","subtype":"success","result":"Cursor answer"}'
        """#
        try stub.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let cursor = CursorProvider(executable: executable, apiKey: "stub-key")
        #expect(await cursor.status() == .ready(plan: nil))
        let request = AIRequest(prompt: "latest turn text", systemPrompt: "instructions", model: "composer-2",
                                history: [AIChatTurn(user: "first question", assistant: "first reply")])
        var events: [AIEvent] = []
        for await event in cursor.run(request) { events.append(event) }
        #expect(events == [.started(sessionID: "", model: "composer-2"), .text("Cursor answer"),
                           .finished(AIResult(text: "Cursor answer"))])
    }
}
