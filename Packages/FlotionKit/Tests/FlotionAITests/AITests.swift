import Foundation
import Testing
import FlotionAI
import FlotionCore

// Lines in Claude Code's stream-json format. The authentication failure pair was captured
// from the real CLI (2.1.220); the others follow its documented event shapes.
private enum Lines {
    static let initEvent = #"{"type":"system","subtype":"init","session_id":"sess-1","model":"claude-sonnet-5-5","tools":[],"mcp_servers":[{"name":"flotion","status":"connected"}]}"#
    static func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
    }
    static let toolStart = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"mcp__flotion__get_page","input":{}}}}"#
    static let assistantWithTool = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_1","name":"mcp__flotion__get_page","input":{"page_id":"p"}}]}}"#
    static let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":false,"content":"page text"}]}}"#
    static let success = #"{"type":"result","subtype":"success","is_error":false,"result":"Let me look. Done.","session_id":"sess-1"}"#
    static let authAssistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},"error":"authentication_failed"}"#
    static let authResult = #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed","session_id":"sess-1"}"#
    static let rateRetry = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":2000,"error_status":429,"error":"rate_limit"}"#
    static let rateResult = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Request failed","session_id":"sess-1"}"#
}

private func parse(_ lines: [String]) -> [AIEvent] {
    var parser = ClaudeStreamParser()
    return lines.flatMap { parser.parse(Data($0.utf8)) }
}

@Suite struct ClaudeCLITests {
    let server = URL(fileURLWithPath: "/Applications/Flotion.app/Contents/MacOS/flotion-mcp")
    let database = URL(fileURLWithPath: "/tmp/ws/flotion.sqlite")

    @Test func everyRequestIsLockedDown() {
        let args = ClaudeCLI.arguments(for: AIRequest(prompt: "hi", systemPrompt: "SYS"))
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }

        #expect(value(after: "--tools") == "", "no built-in tools: no shell, no file access")
        #expect(args.contains("--strict-mcp-config"), "only MCP servers passed explicitly")
        #expect(value(after: "--setting-sources") == "", "the user's coding settings, hooks and CLAUDE.md stay out")
        #expect(args.contains("--disable-slash-commands"))
        #expect(value(after: "--permission-mode") == "dontAsk")
        #expect(value(after: "--system-prompt") == "SYS")
        #expect(value(after: "--input-format") == "stream-json" && value(after: "--output-format") == "stream-json")
        #expect(!args.contains("--bare"), "bare mode refuses the subscription login")
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--mcp-config"), "a tool-free request attaches no MCP server")
        #expect(!args.contains("hi"), "the prompt travels on stdin, never in the argument list")
    }

    @Test func toolAccessAttachesOnlyTheFlotionServer() throws {
        let request = AIRequest(prompt: "x", systemPrompt: "s", tools: .flotion(server: server, database: database, actor: "chat:abc"))
        let args = ClaudeCLI.arguments(for: request)
        let json = try #require(args.firstIndex(of: "--mcp-config").map { args[$0 + 1] })
        let config = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: [String: Any]]])
        #expect(Array(config["mcpServers"]!.keys) == ["flotion"])
        let flotion = config["mcpServers"]!["flotion"]!
        #expect(flotion["command"] as? String == server.path)
        #expect(flotion["env"] as? [String: String] == ["FLOTION_DB": database.path, "FLOTION_ACTOR": "chat:abc"])
        #expect(args.firstIndex(of: "--allowedTools").map { args[$0 + 1] } == "mcp__flotion")
    }

    @Test func sessionsResumeOrLeaveNoTrace() {
        let resumed = ClaudeCLI.arguments(for: AIRequest(prompt: "x", systemPrompt: "s", resumeSessionID: "sess-9"))
        #expect(resumed.firstIndex(of: "--resume").map { resumed[$0 + 1] } == "sess-9")
        let oneShot = ClaudeCLI.arguments(for: AIRequest(prompt: "x", systemPrompt: "s", keepSession: false))
        #expect(oneShot.contains("--no-session-persistence"))
        let fresh = ClaudeCLI.arguments(for: AIRequest(prompt: "x", systemPrompt: "s", model: "haiku", effort: "low"))
        #expect(!fresh.contains("--resume") && !fresh.contains("--no-session-persistence"))
        #expect(fresh.contains("haiku") && fresh.contains("low"))
    }

    @Test func childEnvironmentCarriesNoApiKeyOrSessionMarkers() {
        let env = ClaudeCLI.childEnvironment(from: [
            "PATH": "/usr/bin", "HOME": "/Users/x", "ANTHROPIC_API_KEY": "secret", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s",
        ])
        #expect(env == ["PATH": "/usr/bin", "HOME": "/Users/x"])
    }

    @Test func statusComesFromTheCLIsOwnReport() {
        #expect(ClaudeCLI.parseStatus(Data(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#.utf8)) == .ready(plan: "max"))
        #expect(ClaudeCLI.parseStatus(Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8)) == .signedOut)
        #expect(ClaudeCLI.parseStatus(Data("not json".utf8)) == .signedOut)
    }
}

@Suite struct StreamParserTests {
    @Test func streamsTextAndToolActivityThenFinishes() {
        let events = parse([Lines.initEvent, Lines.delta("Let me "), Lines.delta("look."), Lines.toolStart,
                            Lines.assistantWithTool, Lines.toolResult, Lines.delta(" Done."), Lines.success])
        #expect(events == [
            .started(sessionID: "sess-1", model: "claude-sonnet-5-5"),
            .text("Let me "), .text("look."),
            .toolStarted(id: "toolu_1", name: "get_page"),
            .toolFinished(id: "toolu_1", isError: false),
            .text(" Done."),
            .finished(AIResult(text: "Let me look. Done.", sessionID: "sess-1")),
        ])
    }

    @Test func worksWhenPartialMessagesAreNotStreamed() {
        let events = parse([Lines.initEvent, Lines.assistantWithTool, Lines.toolResult, Lines.success])
        #expect(events.contains(.text("Let me look.")))
        #expect(events.contains(.toolStarted(id: "toolu_1", name: "get_page")))
        #expect(events.last == .finished(AIResult(text: "Let me look.", sessionID: "sess-1")))
    }

    @Test func signedOutIsRecognisedAndItsMessageIsNotShownAsAReply() {
        let events = parse([Lines.initEvent, Lines.authAssistant, Lines.authResult])
        #expect(!events.contains { if case .text = $0 { true } else { false } })
        guard case .finished(let result) = events.last else { Issue.record("no result"); return }
        #expect(result.failure == .notSignedIn)
        #expect(result.message?.contains("authenticate") == true)
    }

    @Test func rateLimitsAreReportedWhileWaitingAndOnFailure() {
        let events = parse([Lines.initEvent, Lines.rateRetry, Lines.rateResult])
        #expect(events.contains(.retrying(reason: "rate_limit")))
        guard case .finished(let result) = events.last else { Issue.record("no result"); return }
        #expect(result.failure == .rateLimited)
    }

    @Test func unknownAndMalformedLinesAreIgnored() {
        #expect(parse(["", "not json", #"{"type":"something_new","x":1}"#, #"{"no_type":true}"#]).isEmpty)
    }
}

/// A stand-in `claude` binary: records its launch, echoes the prompt it was sent, exits when stdin closes.
private func makeStubCLI(directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("claude")
    let script = """
        #!/bin/bash
        echo "launch $*" >> "\(directory.path)/launches.log"
        IFS= read -r line
        echo "$line" > "\(directory.path)/stdin.json"
        echo '\(Lines.initEvent)'
        echo '\(Lines.delta("Echo: "))'
        echo '\(Lines.delta("ok"))'
        echo '\(Lines.success)'
        cat > /dev/null
        """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flotion-ai-\(newID())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct ProviderProcessTests {
    @Test func sendsThePromptOnStdinAndStreamsTheReply() async throws {
        let dir = try tempDirectory()
        let provider = ClaudeCodeProvider(executable: try makeStubCLI(directory: dir), workingDirectory: dir.appendingPathComponent("cwd"))
        var events: [AIEvent] = []
        for await event in provider.run(AIRequest(prompt: "Shorten this", systemPrompt: "s", keepSession: false)) { events.append(event) }

        #expect(events.first == .started(sessionID: "sess-1", model: "claude-sonnet-5-5"))
        #expect(events.contains(.text("Echo: ")) && events.contains(.text("ok")))
        #expect(events.last == .finished(AIResult(text: "Echo: ok", sessionID: "sess-1")))

        let sent = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("stdin.json"))) as? [String: Any])
        #expect(sent["type"] as? String == "user")
        #expect((sent["message"] as? [String: Any])?["content"] as? String == "Shorten this")
    }

    @Test func aPrewarmedProcessIsUsedInsteadOfStartingAnother() async throws {
        let dir = try tempDirectory()
        let provider = ClaudeCodeProvider(executable: try makeStubCLI(directory: dir), workingDirectory: dir.appendingPathComponent("cwd"))
        let request = AIRequest(prompt: "one", systemPrompt: "s", keepSession: false)
        provider.prewarm(request)
        provider.prewarm(request) // asking twice must not start a second spare
        for await _ in provider.run(request) {}
        let launches = try String(contentsOf: dir.appendingPathComponent("launches.log"), encoding: .utf8).split(separator: "\n")
        #expect(launches.count == 1)

        // A request of a different shape cannot use that spare.
        for await _ in provider.run(AIRequest(prompt: "two", systemPrompt: "other", keepSession: false)) {}
        let after = try String(contentsOf: dir.appendingPathComponent("launches.log"), encoding: .utf8).split(separator: "\n")
        #expect(after.count == 2)
    }

    @Test func aMissingCLIFailsCleanly() async throws {
        let provider = ClaudeCodeProvider(executable: nil, workingDirectory: try tempDirectory())
        #expect(await provider.status() == .notInstalled)
        var last: AIEvent?
        for await event in provider.run(AIRequest(prompt: "x", systemPrompt: "s")) { last = event }
        guard case .finished(let result) = last else { Issue.record("no result"); return }
        #expect(result.failure == .notInstalled)
    }

    @Test func aProcessThatDiesMidReplyEndsTheStreamWithAFailure() async throws {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("claude")
        try "#!/bin/bash\nIFS= read -r line\necho '\(Lines.initEvent)'\nexit 3\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let provider = ClaudeCodeProvider(executable: url, workingDirectory: dir.appendingPathComponent("cwd"))
        var last: AIEvent?
        for await event in provider.run(AIRequest(prompt: "x", systemPrompt: "s")) { last = event }
        guard case .finished(let result) = last else { Issue.record("the stream must still end with a result"); return }
        #expect(result.failure == .other)
    }
}

@MainActor @Suite struct ChatSessionTests {
    let server = URL(fileURLWithPath: "/unused/flotion-mcp")

    private func waitUntilIdle(_ session: ChatSession) async {
        for _ in 0..<400 where session.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aTurnStreamsTextShowsToolsAndGroupsItsChangesForUndo() async throws {
        let ws = try Workspace.temporary()
        let page = try ws.createPage(title: "Notes", blocks: [Block(.paragraph, "original")])
        let block = try ws.blocks(pageID: page.id)[0]

        let provider = FakeProvider { request in
            // Behave like the model calling flotion tools: write with the session's actor.
            guard case .flotion(_, _, let actor) = request.tools else { return [] }
            let context = ChangeContext(actor: actor)
            _ = try? ws.updateBlock(id: block.id, context: context) { $0.runs = [TextRun("rewritten by AI")] }
            _ = try? ws.insertBlocks(pageID: page.id, [Block(.bullet, "added by AI")], context: context)
            return [.started(sessionID: "sess-1", model: "m"), .toolStarted(id: "t1", name: "update_block"),
                    .toolFinished(id: "t1", isError: false), .text("Tightened "), .text("the intro."),
                    .finished(AIResult(text: "Tightened the intro.", sessionID: "sess-1"))]
        }
        let session = ChatSession(provider: provider, workspace: ws, server: server)
        session.send("tighten the intro", context: PageContext(pageID: page.id, title: "Notes", markdown: "original"))
        #expect(session.isRunning)
        await waitUntilIdle(session)

        #expect(session.messages.map(\.role) == [.user, .assistant])
        let reply = session.messages[1]
        #expect(reply.text == "Tightened the intro.")
        #expect(!reply.isStreaming)
        #expect(reply.tools.map(\.label) == ["Editing a block"])
        let allDone = reply.tools.allSatisfy { $0.isDone }
        #expect(allDone)
        #expect(reply.changeCount == 2)
        #expect(try ws.blocks(pageID: page.id).map(\.plainText) == ["rewritten by AI", "added by AI"])

        await session.undo(reply.id)
        #expect(session.messages[1].isUndone)
        #expect(try ws.blocks(pageID: page.id).map(\.plainText) == ["original"])
    }

    @Test func pageContextIsSentOnceThenOnlyWhenItChanges() async throws {
        let ws = try Workspace.temporary()
        let provider = FakeProvider { _ in [.started(sessionID: "sess-7", model: "m"), .finished(AIResult(text: "ok", sessionID: "sess-7"))] }
        let session = ChatSession(provider: provider, workspace: ws, server: server)
        let context = PageContext(pageID: "p1", title: "Roadmap", markdown: "# Q1\n\nShip it.", selection: "Ship it.")

        session.send("first", context: context)
        await waitUntilIdle(session)
        session.send("second", context: context)
        await waitUntilIdle(session)
        session.send("third", context: PageContext(pageID: "p1", title: "Roadmap", markdown: "# Q1\n\nShipped."))
        await waitUntilIdle(session)

        let prompts = provider.requests.filter { !$0.prompt.isEmpty }.map(\.prompt)
        #expect(prompts.count == 3)
        #expect(prompts[0].contains("page_id: p1") && prompts[0].contains("# Q1") && prompts[0].contains("Selected text"))
        #expect(prompts[0].hasSuffix("first"))
        #expect(!prompts[1].contains("# Q1") && prompts[1].contains("unchanged"))
        #expect(prompts[2].contains("Shipped."), "an edited page is sent again")

        let turns = provider.requests.filter { !$0.prompt.isEmpty }
        #expect(turns[0].resumeSessionID == nil)
        #expect(turns[1].resumeSessionID == "sess-7", "later turns continue the same conversation")
        guard case .flotion(_, let database, let actor) = turns[0].tools else { Issue.record("chat must have the flotion tools"); return }
        #expect(database == ws.url)
        #expect(actor.hasPrefix("chat:"))
    }

    @Test func failuresBecomeAnActionableNotice() async throws {
        let ws = try Workspace.temporary()
        let provider = FakeProvider { _ in [.finished(.failed(.notSignedIn, "Failed to authenticate"))] }
        let session = ChatSession(provider: provider, workspace: ws, server: server)
        session.send("hello", context: nil)
        await waitUntilIdle(session)
        #expect(session.messages[1].failure == .notSignedIn)
        #expect(session.messages[1].notice?.contains("Settings") == true)
        #expect(!session.isRunning)
    }

    @Test func emptyMessagesAndDoubleSendsAreIgnored() async throws {
        let ws = try Workspace.temporary()
        let provider = FakeProvider { _ in
            try? await Task.sleep(for: .milliseconds(50))
            return [.finished(AIResult(text: "ok"))]
        }
        let session = ChatSession(provider: provider, workspace: ws, server: server)
        session.send("   ", context: nil)
        #expect(session.messages.isEmpty)
        session.send("one", context: nil)
        session.send("two", context: nil)
        #expect(session.messages.count == 2, "a second send while running is dropped, not queued")
        await waitUntilIdle(session)
    }
}

@Suite struct PromptTests {
    @Test func longPagesAreNotInlined() {
        let long = String(repeating: "word ", count: 6_000)
        let prompt = AIPrompts.chat("summarise", context: PageContext(pageID: "p", title: "Big", markdown: long), includePage: true)
        #expect(prompt.count < 1_000)
        #expect(prompt.contains("get_page"))
    }

    @Test func inlinePromptSeparatesInstructionSelectionAndContext() {
        let prompt = AIPrompts.inline(instruction: "Make it shorter", selection: "A long sentence.", context: "Before. A long sentence. After.")
        #expect(prompt.hasPrefix("Instruction: Make it shorter"))
        #expect(prompt.contains("Text to rewrite:\n<<<\nA long sentence.\n>>>"))
        #expect(prompt.contains("do not rewrite"))
        #expect(!AIPrompts.inline(instruction: "x", selection: "y", context: "").contains("Surrounding"))
    }
}

/// Uses the real, signed-in Claude Code. Opt in with FLOTION_LIVE_AI=1 (Scripts/verify.sh --live-ai).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FLOTION_LIVE_AI"] == "1")) struct LiveClaudeTests {
    @Test func signedInCLIAnswersAnInlineEdit() async throws {
        let provider = ClaudeCodeProvider(workingDirectory: try tempDirectory())
        guard case .ready = await provider.status() else {
            Issue.record("Claude Code is not signed in: run `claude auth login` first")
            return
        }
        let request = AIRequest(prompt: AIPrompts.inline(instruction: "Make it shorter", selection: "The meeting that we had yesterday was very long.", context: ""),
                                systemPrompt: AIPrompts.inlineSystem, effort: "low", keepSession: false)
        let clock = ContinuousClock()
        let start = clock.now
        var firstToken: Duration?
        var result: AIResult?
        for await event in provider.run(request) {
            if case .text = event, firstToken == nil { firstToken = clock.now - start }
            if case .finished(let r) = event { result = r }
        }
        print("PERF live inline edit: first token \(String(describing: firstToken)), total \(clock.now - start)")
        let message = result?.message ?? ""
        let text = result?.text ?? ""
        #expect(result?.failure == nil, "\(message)")
        #expect(!text.isEmpty)
    }
}
