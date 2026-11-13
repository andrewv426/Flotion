import Foundation

/// A running `claude -p` child with line-buffered output.
final class ClaudeProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var pending = Data()
    private var backlog: [Data] = []
    private var ended = false
    private var sink: (@Sendable (Data?) -> Void)?

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData)
        }
        try process.run()
    }

    private func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data.isEmpty {
            guard !ended else { return }
            ended = true
            output.fileHandleForReading.readabilityHandler = nil
            sink?(nil)
            return
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let sink { sink(line) } else { backlog.append(line) }
        }
    }

    /// Starts delivering lines (nil marks the end of output). Lines read before this call are replayed first.
    func attach(_ sink: @escaping @Sendable (Data?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
        backlog.forEach(sink)
        backlog.removeAll()
        if ended { sink(nil) }
    }

    func send(_ data: Data) {
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Closing stdin tells the CLI there are no more turns, and it exits.
    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    func terminate() {
        closeInput()
        if process.isRunning { process.terminate() }
    }

    var isRunning: Bool { process.isRunning }
}

/// Runs requests through the user's installed Claude Code, on their subscription login.
public final class ClaudeCodeProvider: AIProvider, @unchecked Sendable {
    public let executable: URL?
    private let workingDirectory: URL
    private let lock = NSLock()
    private var spare: (arguments: [String], process: ClaudeProcess)?

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

    private func launch(_ arguments: [String]) throws -> ClaudeProcess {
        guard let executable else { throw CocoaError(.fileNoSuchFile) }
        return try ClaudeProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory,
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

    private func takeSpare(_ arguments: [String]) -> ClaudeProcess? {
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
            let process: ClaudeProcess
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
            process.send(ClaudeCLI.userMessage(request.prompt))
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
