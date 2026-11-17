import Foundation

/// A CLI invocation that can also be run in Terminal for interactive sign-in.
public struct AICommand: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let directory: URL
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }

    /// GUI apps do not normally receive Homebrew's PATH. Pass only the environment needed
    /// to find runtimes and the user's CLI login, without inheriting API keys or endpoints.
    public static func loginEnvironment(
        executable: URL,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inherited.filter { ["LANG", "LC_ALL", "TMPDIR", "USER", "LOGNAME"].contains($0.key) }
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"
        return environment
    }
}

/// Account-authenticated CLIs. Flotion replays its own history on every request.
public struct AccountCLIProvider: AIProvider {
    public enum CLI: String, Sendable { case codex, agy }

    public let supportsWorkspaceTools = true
    public let cli: CLI
    public let executable: URL?
    let directory: URL

    public init(_ cli: CLI, directory: URL) {
        self.init(cli, executable: Self.locate(cli), directory: directory)
    }

    init(_ cli: CLI, executable: URL?, directory: URL) {
        self.cli = cli
        self.executable = executable
        self.directory = directory.appendingPathComponent(cli.rawValue, isDirectory: true)
    }

    public static func locate(_ cli: CLI) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(cli.rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var label: String { cli == .codex ? "ChatGPT" : "Antigravity" }

    public func status() async -> AIProviderStatus {
        guard let executable else { return .notInstalled }
        if cli == .agy {
            do {
                try prepareDirectory()
                return await AntigravitySession.inspect(command(executable, AntigravitySession.arguments)).status
            } catch {
                return .notInstalled
            }
        }
        return await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["login", "status"]
            process.environment = AICommand.loginEnvironment(executable: executable)
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                let signedIn = process.terminationStatus == 0 && text.split(whereSeparator: \.isNewline).contains("Logged in using ChatGPT")
                return signedIn ? AIProviderStatus.ready(plan: nil) : .signedOut
            } catch {
                return .notInstalled
            }
        }.value
    }

    public func signInCommand() throws -> AICommand? {
        guard let executable else { return nil }
        try prepareDirectory()
        let arguments = cli == .codex ? ["login", "-c", "forced_login_method=\"chatgpt\""] : ["acp", "--login"]
        return command(executable, arguments)
    }

    func arguments(for request: AIRequest) throws -> [String] {
        var args: [String]
        switch cli {
        case .codex:
            args = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                    "--sandbox", "read-only", "-c", "approval_policy=\"never\"", "-c", "forced_login_method=\"chatgpt\"",
                    "-c", "cli_auth_credentials_store=\"auto\"", "-c", "web_search=\"disabled\"",
                    "-c", try codexMCPConfig(request.tools)]
            for feature in ["shell_tool", "shell_snapshot", "view_image", "browser_use", "browser_use_external", "in_app_browser",
                            "apps", "plugins", "hooks", "multi_agent", "multi_agent_v2", "code_mode"] {
                args += ["--disable", feature]
            }
        case .agy:
            return AntigravitySession.arguments
        }
        if let model = request.model { args += ["--model", model] }
        if cli == .codex { args.append("-") }
        return args
    }

    private func codexMCPConfig(_ access: ToolAccess) throws -> String {
        guard case .flotion(let server, let database, let actor) = access else { return "mcp_servers={}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // These JSON strings are also TOML basic strings. Disabling slash escaping keeps paths valid in TOML.
        func quote(_ string: String) throws -> String { String(decoding: try encoder.encode(string), as: UTF8.self) }
        return """
            mcp_servers={ flotion={ command=\(try quote(server.path)), required=true, default_tools_approval_mode="approve", env={ FLOTION_DB=\(try quote(database.path)), FLOTION_ACTOR=\(try quote(actor)) } } }
            """
    }

    public func run(_ request: AIRequest) -> AsyncStream<AIEvent> {
        AsyncStream { continuation in
            let task = Task.detached {
                defer { continuation.finish() }
                let result = await complete(request, continuation)
                if !Task.isCancelled { continuation.yield(.finished(result)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func complete(_ request: AIRequest, _ continuation: AsyncStream<AIEvent>.Continuation) async -> AIResult {
        guard let executable else { return .failed(.notInstalled, "Install \(cli == .codex ? "Codex CLI" : "Antigravity CLI").") }
        guard !Task.isCancelled else { return .failed(.other, "Stopped.") }
        do {
            try prepareDirectory()
            if cli == .agy {
                return await AntigravitySession.run(command(executable, AntigravitySession.arguments),
                                                    request: request, continuation: continuation)
            }
            guard case .ready = await status() else { return .failed(.notSignedIn, "Sign in to \(label) in the CLI.") }
            let command = command(executable, try arguments(for: request))
            let process = try AIProcess(executable: command.executable, arguments: command.arguments,
                                        workingDirectory: command.directory, environment: command.environment, includeStandardError: true)
            let lines = process.lines()
            // Read the prompt from stdin so notes and chat history stay out of the argument list.
            process.send(Data((request.systemPrompt + "\n\n" + request.promptWithHistory).utf8))
            process.closeInput()
            var stream = AccountCLIStream(cli: cli, model: request.model ?? "")
            for await line in lines {
                guard !Task.isCancelled else { break }
                for event in stream.consume(line) { continuation.yield(event) }
                if stream.completed { break }
            }
            process.terminate()
            return stream.result(label: label)
        } catch {
            return .failed(.other, "Could not start \(label). Check the CLI installation and try again.")
        }
    }

    func command(_ executable: URL, _ arguments: [String]) -> AICommand {
        AICommand(executable: executable, arguments: arguments, directory: directory,
                  environment: AICommand.loginEnvironment(executable: executable))
    }

    func prepareDirectory() throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

struct AccountCLIStream {
    let cli: AccountCLIProvider.CLI
    let model: String
    private var text = ""
    private var failure: AIFailure?
    private var activeTools = Set<String>()
    private var usedTools = false
    private(set) var completed = false

    init(cli: AccountCLIProvider.CLI, model: String) {
        self.cli = cli
        self.model = model
    }

    mutating func consume(_ line: Data) -> [AIEvent] {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = record["type"] as? String else {
            detectFailure(String(decoding: line, as: UTF8.self))
            return []
        }
        switch (cli, type) {
        case (.codex, "thread.started"):
            return [.started(sessionID: "", model: record["model"] as? String ?? model)]
        case (.codex, "item.started"), (.codex, "item.completed"):
            guard let item = record["item"] as? [String: Any] else { return [] }
            if item["type"] as? String == "mcp_tool_call", item["server"] as? String == "flotion",
               let id = item["id"] as? String, let name = item["tool"] as? String {
                let start = startTool(id, name: name)
                if type == "item.started" { return start }
                return start + finishTool(id, isError: item["status"] as? String == "failed" || item["error"] is [String: Any])
            }
            guard type == "item.completed", item["type"] as? String == "agent_message",
                  let content = item["text"] as? String else { return [] }
            return append(content, separator: text.isEmpty ? "" : "\n\n")
        case (.codex, "turn.completed"):
            completed = true
            failure = nil
        case (.codex, "turn.failed"):
            completed = true
            detectFailure((record["error"] as? [String: Any])?["message"] as? String ?? "")
            failure = failure ?? .other
        case (_, "error"):
            detectFailure(record["message"] as? String ?? "")
        default:
            break
        }
        return []
    }

    private mutating func startTool(_ id: String, name: String) -> [AIEvent] {
        guard activeTools.insert(id).inserted else { return [] }
        usedTools = true
        return [.toolStarted(id: id, name: name)]
    }

    private mutating func finishTool(_ id: String, isError: Bool) -> [AIEvent] {
        guard activeTools.remove(id) != nil else { return [] }
        return [.toolFinished(id: id, isError: isError)]
    }

    private mutating func append(_ content: String, separator: String = "") -> [AIEvent] {
        guard !content.isEmpty else { return [] }
        let piece = separator + content
        text += piece
        return [.text(piece)]
    }

    private mutating func detectFailure(_ diagnostic: String) {
        let lower = diagnostic.lowercased()
        if ["not logged in", "unauthorized", "invalid_grant", "re-authenticate", "failed to login",
            "authentication failed", "failed to authenticate", "no authentication is configured", "401 unauthorized"].contains(where: lower.contains) {
            failure = .notSignedIn
        } else if ["rate limit", "429 too many requests", "quota exceeded"].contains(where: lower.contains) {
            failure = .rateLimited
        }
    }

    func result(label: String) -> AIResult {
        if completed && failure == nil && (usedTools || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return AIResult(text: text)
        }
        if failure == .notSignedIn { return .failed(.notSignedIn, "Sign in to \(label) again.") }
        if failure == .rateLimited { return .failed(.rateLimited, "The \(label) usage limit was reached.") }
        return .failed(.other, "\(label) did not finish a reply. Check the CLI version and model in Settings.")
    }
}
