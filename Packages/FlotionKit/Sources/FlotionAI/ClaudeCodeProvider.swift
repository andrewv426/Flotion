import Foundation

/// Runs requests through the user's installed Claude Code, on their subscription login.
public final class ClaudeCodeProvider: AIProvider, @unchecked Sendable {
    public let executable: URL?
    public let supportsWorkspaceTools = true
    private let workingDirectory: URL
    private let lock = NSLock()
    private var spare: (arguments: [String], process: AIProcess)?

    /// - Parameter workingDirectory: an empty folder; the model has no file tools, and this
    ///   also keeps any project-level configuration out of reach.
    public init(executable: URL? = ClaudeCLI.locate(), workingDirectory: URL) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    deinit { spare?.process.terminate() }

    public func status() async -> AIProviderStatus {
        await ClaudeCLI.status(executable: executable)
    }

    private func launch(_ arguments: [String]) throws -> AIProcess {
        guard let executable else { throw CocoaError(.fileNoSuchFile) }
        return try AIProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                                 environment: ClaudeCLI.childEnvironment())
    }

    /// Process start-up is the slowest local step (300–600 ms measured), so a process for the
    /// next request can be started ahead of time. It idles on stdin until used.
    public func prewarm(_ request: AIRequest) {
        let arguments = ClaudeCLI.arguments(for: request)
        lock.lock()
        defer { lock.unlock() }
        if let spare, spare.arguments == arguments, spare.process.isRunning { return }
        spare?.process.terminate()
        spare = (try? launch(arguments)).map { (arguments, $0) }
    }

    private func takeSpare(_ arguments: [String]) -> AIProcess? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = spare, current.arguments == arguments, current.process.isRunning else { return nil }
        spare = nil
        return current.process
    }

    public func run(_ request: AIRequest) -> AsyncStream<AIEvent> {
        AsyncStream { continuation in
            guard executable != nil else {
                continuation.yield(.finished(.failed(.notInstalled, "Claude Code is not installed.")))
                continuation.finish()
                return
            }
            let arguments = ClaudeCLI.arguments(for: request)
            let process: AIProcess
            do {
                process = try takeSpare(arguments) ?? launch(arguments)
            } catch {
                continuation.yield(.finished(.failed(.other, "Could not start Claude Code: \(error.localizedDescription)")))
                continuation.finish()
                return
            }
            let parser = LockedParser()
            process.attach { line in
                guard let line else {
                    if !parser.isFinished {
                        continuation.yield(.finished(.failed(.other, "Claude Code stopped before finishing.")))
                    }
                    continuation.finish()
                    return
                }
                for event in parser.parse(line) {
                    continuation.yield(event)
                    if case .finished = event { process.closeInput() }
                }
            }
            process.send(ClaudeCLI.userMessage(request.promptWithHistory))
            continuation.onTermination = { _ in process.terminate() }
        }
    }
}

private final class LockedParser: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = ClaudeStreamParser()

    func parse(_ line: Data) -> [AIEvent] {
        lock.lock(); defer { lock.unlock() }
        return parser.parse(line)
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return parser.isFinished
    }
}
