import Foundation

/// Cursor is used as a text provider in Ask mode, with a separate configuration for each request.
public final class CursorProvider: AIProvider {
    public let executable: URL?
    private let apiKey: String?

    public init(executable: URL? = CursorProvider.locate(), apiKey: String?) {
        self.executable = executable
        self.apiKey = apiKey
    }

    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.lazy.flatMap { dir in ["\(dir)/agent", "\(dir)/cursor-agent"] }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func status() async -> AIProviderStatus {
        guard executable != nil else { return .notInstalled }
        return apiKey == nil ? .signedOut : .ready(plan: nil)
    }

    public func run(_ request: AIRequest) -> AsyncStream<AIEvent> {
        AsyncStream { continuation in
            func fail(_ failure: AIFailure, _ message: String) {
                continuation.yield(.finished(.failed(failure, message)))
                continuation.finish()
            }
            guard let executable else { return fail(.notInstalled, "Install the Cursor CLI.") }
            guard let apiKey else { return fail(.notSignedIn, "Add a Cursor API key.") }
            let prompt = request.systemPrompt + "\n\n" + request.promptWithHistory
            guard prompt.utf8.count <= 96_000, !prompt.contains("\0") else {
                return fail(.other, "This request is too long or contains invalid text for Cursor. Try a shorter prompt or a smaller selection.")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flotion-cursor-\(UUID())", isDirectory: true)
            let process: AIProcess
            do {
                process = try launch(executable, apiKey: apiKey, directory: directory, model: request.model, prompt: prompt)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return fail(.other, "Could not start Cursor. Check your CLI installation.")
            }
            process.closeInput()
            continuation.onTermination = { _ in
                process.terminate()
                try? FileManager.default.removeItem(at: directory)
            }
            continuation.yield(.started(sessionID: "", model: request.model ?? "auto"))
            process.attach { data in
                guard let data else {
                    continuation.yield(.finished(.failed(.other, "Cursor ended without a reply. Check your API key, model ID, and CLI version.")))
                    continuation.finish()
                    return
                }
                guard let result = Self.parseResult(data) else { return }
                if result.failure == nil { continuation.yield(.text(result.text)) }
                continuation.yield(.finished(result))
                continuation.finish()
            }
        }
    }

    private func launch(_ executable: URL, apiKey: String, directory: URL, model: String?, prompt: String) throws -> AIProcess {
        let config = directory.appendingPathComponent("config", isDirectory: true)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        for folder in [config, workspace] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let configJSON = """
            {
              "version": 1,
              "editor": {"vimMode": false},
              "approvalMode": "allowlist",
              "sandbox": {"readBoundary": "workspace"},
              "permissions": {"allow": [], "deny": ["Shell(*)", "Read(**)", "Read(/**)", "Write(**)", "Write(/**)", "WebFetch(*)", "Mcp(*:*)"]}
            }
            """
        try configJSON.write(to: config.appendingPathComponent("cli-config.json"), atomically: true, encoding: .utf8)
        var arguments = ["--print", "--mode", "ask", "--sandbox", "enabled", "--output-format", "stream-json",
                         "--workspace", workspace.path]
        if let model { arguments += ["--model", model] }
        arguments += ["--", prompt]
        return try AIProcess(executable: executable, arguments: arguments, workingDirectory: workspace, environment: [
            "CURSOR_API_KEY": apiKey,
            "CURSOR_CONFIG_DIR": config.path,
            "HOME": directory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": directory.path,
        ])
    }

    private struct Record: Decodable {
        let type: String
        let subtype: String?
        let is_error: Bool?
        let result: String?
    }

    static func parseResult(_ data: Data) -> AIResult? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.type == "result" else { return nil }
        guard record.is_error != true, record.subtype == "success" || record.subtype == nil,
              let text = record.result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(.other, "Cursor returned no reply. Check your API key and model ID in Settings.")
        }
        return AIResult(text: text)
    }
}
