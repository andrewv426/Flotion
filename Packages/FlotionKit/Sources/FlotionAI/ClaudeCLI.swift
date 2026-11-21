import Foundation

/// Everything Flotion knows about the user's own Claude Code install.
///
/// Flotion never signs in and never touches a credential: it runs the unmodified `claude`
/// binary, which uses whatever login the user completed through Anthropic's own flow.
public enum ClaudeCLI {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") { candidates.append("\(dir)/claude") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The environment for the child process. Session markers inherited from a parent Claude
    /// Code process are dropped, and so are API credentials: requests are meant to run on
    /// the subscription login, never silently on a metered key.
    public static func childEnvironment(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
    }

    /// The locked-down invocation: no built-in tools, no user settings, hooks, plugins or
    /// skills, and only the MCP server Flotion passes explicitly.
    public static func arguments(for request: AIRequest) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--permission-mode", "dontAsk",
            "--system-prompt", request.systemPrompt,
        ]
        if let model = request.model { args += ["--model", model] }
        if let effort = request.effort { args += ["--effort", effort] }
        if case .flotion(let server, let database, let actor) = request.tools {
            let config: [String: Any] = ["mcpServers": ["flotion": [
                "command": server.path,
                "env": ["FLOTION_DB": database.path, "FLOTION_ACTOR": actor],
            ]]]
            let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            args += ["--mcp-config", json, "--allowedTools", "mcp__flotion"]
        }
        if let session = request.resumeSessionID {
            args += ["--resume", session]
        } else if !request.keepSession {
            args += ["--no-session-persistence"]
        }
        return args
    }

    /// One user turn in the CLI's streaming input format.
    public static func userMessage(_ prompt: String) -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func parseStatus(_ output: Data) -> AIProviderStatus {
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              object["loggedIn"] as? Bool == true else { return .signedOut }
        return .ready(plan: object["subscriptionType"] as? String)
    }

    public static func probeStatus(executable: URL?, timeout: Duration = .seconds(15)) async -> AIProviderStatus? {
        guard let executable else { return .notInstalled }
        let result = await ProcessProbe.run(
            executable: executable,
            arguments: ["auth", "status", "--json"],
            environment: childEnvironment(),
            includeStandardError: false,
            timeout: timeout
        )
        switch result {
        case .exited(_, let data):
            return parseStatus(data)
        case .launchFailed(let executableMissing):
            return executableMissing ? .notInstalled : nil
        case .timedOutOrCancelled:
            return nil
        }
    }

    public static func status(executable: URL?, timeout: Duration = .seconds(15)) async -> AIProviderStatus {
        await probeStatus(executable: executable, timeout: timeout) ?? .signedOut
    }
}
