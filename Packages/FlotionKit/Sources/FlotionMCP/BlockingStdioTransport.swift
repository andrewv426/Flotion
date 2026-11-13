import Foundation
import Logging
import MCP

/// Newline-delimited JSON-RPC over stdin/stdout using blocking I/O on a dedicated thread.
///
/// The SDK's own `StdioTransport` sets the descriptors non-blocking and polls with 10 ms
/// sleeps, which put a ~10 ms floor under every tool call (measured: 12 ms for a 1 ms
/// operation). Blocking reads wake the moment a request arrives.
public actor BlockingStdioTransport: Transport {
    public nonisolated let logger: Logger
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var started = false

    public init() {
        logger = Logger(label: "flotion.mcp.stdio") { _ in SwiftLogNoOpLogHandler() }
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    public func connect() async throws {
        guard !started else { return }
        started = true
        let continuation = self.continuation
        let reader = Thread {
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(STDIN_FILENO, &chunk, chunk.count)
                if count > 0 {
                    pending.append(contentsOf: chunk[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = pending.subdata(in: pending.startIndex..<newline)
                        pending.removeSubrange(pending.startIndex...newline)
                        if !line.isEmpty { continuation.yield(line) }
                    }
                } else if count == 0 {
                    continuation.finish() // the client closed our stdin
                    return
                } else if errno != EINTR {
                    continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
            }
        }
        reader.name = "flotion-mcp.stdin"
        reader.start()
    }

    public func disconnect() async {
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        var message = data
        message.append(0x0A)
        try message.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }
}
