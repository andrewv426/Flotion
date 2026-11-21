import Foundation

enum ProcessProbeResult: Sendable, Equatable {
    case exited(status: Int32, output: Data)
    case launchFailed(executableMissing: Bool)
    case timedOutOrCancelled
}

/// Runs a short CLI status check with a deadline. A timeout or cancellation terminates the child
/// and returns at once, without waiting on a pipe the child may still hold open.
enum ProcessProbe {
    static func run(executable: URL, arguments: [String], directory: URL? = nil, environment: [String: String],
                    includeStandardError: Bool = false, timeout: Duration = .seconds(15)) async -> ProcessProbeResult {
        guard !Task.isCancelled else { return .timedOutOrCancelled }
        let probe = ProbeProcess(executable: executable, arguments: arguments, directory: directory,
                                 environment: environment, includeStandardError: includeStandardError)
        return await withTaskGroup(of: ProcessProbeResult.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { probe.start($0) }
                } onCancel: {
                    probe.stop()
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOutOrCancelled
            }
            let first = await group.next() ?? .timedOutOrCancelled
            group.cancelAll()
            return first
        }
    }
}

private final class ProbeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private var continuation: CheckedContinuation<ProcessProbeResult, Never>?
    private var output = Data()
    private var exitStatus: Int32?
    private var reachedEnd = false
    private var stopped = false

    init(executable: URL, arguments: [String], directory: URL?, environment: [String: String], includeStandardError: Bool) {
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = includeStandardError ? pipe : FileHandle.nullDevice
    }

    func start(_ continuation: CheckedContinuation<ProcessProbeResult, Never>) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            continuation.resume(returning: .timedOutOrCancelled)
            return
        }
        self.continuation = continuation
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData) }
        process.terminationHandler = { [weak self] process in self?.exited(process.terminationStatus) }
        do {
            try process.run()
            lock.unlock()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            self.continuation = nil
            stopped = true
            lock.unlock()
            let missing = !FileManager.default.isExecutableFile(atPath: process.executableURL?.path ?? "")
            continuation.resume(returning: .launchFailed(executableMissing: missing))
        }
    }

    /// Ends the probe early: resumes the waiting task and stops the child, escalating to SIGKILL.
    func stop() {
        lock.lock()
        stopped = true
        let pending = continuation
        continuation = nil
        pipe.fileHandleForReading.readabilityHandler = nil
        let running = process.isRunning
        lock.unlock()
        if running {
            let process = process
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        pending?.resume(returning: .timedOutOrCancelled)
    }

    private func received(_ chunk: Data) {
        lock.lock()
        if chunk.isEmpty {
            reachedEnd = true
            pipe.fileHandleForReading.readabilityHandler = nil
        } else {
            output.append(chunk)
        }
        let finished = takeFinished()
        lock.unlock()
        if let (continuation, result) = finished { continuation.resume(returning: result) }
    }

    private func exited(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let finished = takeFinished()
        lock.unlock()
        if let (continuation, result) = finished { continuation.resume(returning: result) }
    }

    /// Called with the lock held: the result once the child has exited and its output is drained.
    private func takeFinished() -> (CheckedContinuation<ProcessProbeResult, Never>, ProcessProbeResult)? {
        guard reachedEnd, let exitStatus, let continuation else { return nil }
        self.continuation = nil
        return (continuation, .exited(status: exitStatus, output: output))
    }
}
