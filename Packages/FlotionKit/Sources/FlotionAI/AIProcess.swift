import Foundation

/// A child process with line-buffered output and non-blocking ordered stdin writes.
final class AIProcess: @unchecked Sendable {
    private final class InputState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var closed = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled || closed
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func markClosed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return false }
            closed = true
            return true
        }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writeQueue = DispatchQueue(label: "app.flotion.ai-process.stdin")
    private let inputState = InputState()
    private let readLock = NSLock()
    private var outputClosed = false
    private let lock = NSLock()
    private var pending = Data()
    private var backlog: [Data] = []
    private var ended = false
    private var draining = false
    private var sink: (@Sendable (Data?) -> Void)?

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
         includeStandardError: Bool = false) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = includeStandardError ? output : FileHandle.nullDevice
        // Writes run off the caller's thread and must stay cancellable: no SIGPIPE when the child
        // has gone, and non-blocking so `terminate()` can stop a write the child never reads.
        let stdin = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(stdin, F_SETNOSIGPIPE, 1)
        _ = fcntl(stdin, F_SETFL, fcntl(stdin, F_GETFL) | O_NONBLOCK)
        try process.run()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            self.handleReadable(handle)
        }
    }

    deinit {
        terminate()
    }

    private func handleReadable(_ handle: FileHandle) {
        readLock.lock()
        if outputClosed {
            readLock.unlock()
            handle.readabilityHandler = nil
            return
        }
        let data = handle.availableData
        readLock.unlock()
        if data.isEmpty {
            handle.readabilityHandler = nil
            closeOutput()
        }
        ingest(data)
    }

    private func closeOutput() {
        readLock.lock()
        defer { readLock.unlock() }
        guard !outputClosed else { return }
        outputClosed = true
        try? output.fileHandleForReading.close()
    }

    private func ingest(_ data: Data) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        if data.isEmpty {
            ended = true
            if !pending.isEmpty {
                backlog.append(pending)
                pending.removeAll()
            }
            drainLocked()
            return
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            guard !line.isEmpty else { continue }
            backlog.append(line)
        }
        drainLocked()
    }

    /// Delivers queued lines and the terminal nil marker outside `lock`, preserving FIFO order.
    /// Caller must hold `lock`; `lock` is always unlocked on return.
    private func drainLocked() {
        guard !draining, sink != nil else {
            lock.unlock()
            return
        }
        draining = true
        while true {
            if !backlog.isEmpty, let currentSink = sink {
                let lines = backlog
                backlog.removeAll(keepingCapacity: true)
                lock.unlock()
                for line in lines {
                    currentSink(line)
                }
                lock.lock()
                continue
            }
            if ended, let currentSink = sink {
                sink = nil
                lock.unlock()
                currentSink(nil)
                lock.lock()
                continue
            }
            draining = false
            lock.unlock()
            return
        }
    }

    /// Starts delivering lines (nil marks the end of output). Lines read before this call are replayed first.
    func attach(_ sink: @escaping @Sendable (Data?) -> Void) {
        lock.lock()
        self.sink = sink
        drainLocked()
    }

    func lines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.terminate() }
            attach { data in
                if let data { continuation.yield(data) } else { continuation.finish() }
            }
        }
    }

    func send(_ data: Data) {
        let handle = input.fileHandleForWriting
        let state = inputState
        writeQueue.async {
            Self.write(data, to: handle.fileDescriptor, state: state)
        }
    }

    /// Writes all of `data`, waiting on a full pipe in short polls so cancellation is noticed.
    /// Stops quietly when the child has closed its end (EPIPE) or the input was stopped.
    private static func write(_ data: Data, to descriptor: Int32, state: InputState) {
        data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0, !state.isStopped {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written > 0 {
                    cursor += written
                    remaining -= written
                } else if written < 0, errno == EAGAIN {
                    var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&request, 1, 100)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// Closing stdin tells the CLI there are no more turns, and it exits.
    func closeInput() {
        let handle = input.fileHandleForWriting
        let state = inputState
        writeQueue.async {
            guard state.markClosed() else { return }
            try? handle.close()
        }
    }

    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        closeOutput()
        inputState.cancel()
        if process.isRunning { process.terminate() }
        closeInput()
        lock.lock()
        if !ended {
            ended = true
            pending.removeAll()
            backlog.removeAll()
        }
        drainLocked()
    }

    var isRunning: Bool { process.isRunning }

    /// Waits until every stdin write and close queued so far has run. Tests use it.
    func waitForInputIdle(timeout: DispatchTimeInterval) -> Bool {
        let idle = DispatchSemaphore(value: 0)
        writeQueue.async { idle.signal() }
        return idle.wait(timeout: .now() + timeout) == .success
    }

    /// The handle stdout is read from. Tests use it to check the read handler is removed.
    var outputHandle: FileHandle { output.fileHandleForReading }
}
