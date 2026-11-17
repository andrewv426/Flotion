import Foundation

/// A child process with line-buffered output.
final class AIProcess: @unchecked Sendable {
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
            if !pending.isEmpty {
                if let sink { sink(pending) } else { backlog.append(pending) }
                pending.removeAll()
            }
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
