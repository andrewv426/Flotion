import Foundation

/// A minimal MCP client that spawns a server binary and speaks JSON-RPC over its stdio.
/// Test tooling only: it exists so the contract is checked against the real process.
public final class MCPStdioClient: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 0

    /// The built `flotion-mcp` that sits beside the running test bundle.
    public static var builtServerURL: URL {
        // This class is linked statically into the test bundle, so its bundle is the
        // .xctest in the build products directory, where the executable is also built.
        Bundle(for: MCPStdioClient.self).bundleURL.deletingLastPathComponent().appendingPathComponent("flotion-mcp")
    }

    public init(executable: URL = MCPStdioClient.builtServerURL, database: URL, actor: String = "mcp") throws {
        process.executableURL = executable
        process.environment = ["FLOTION_DB": database.path, "FLOTION_ACTOR": actor]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData)
        }
        try process.run()
    }

    deinit { terminate() }

    public func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        condition.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int {
                responses[id] = object
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    @discardableResult
    public func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) throws -> [String: Any] {
        condition.lock()
        nextID += 1
        let id = nextID
        condition.unlock()
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil {
            if !condition.wait(until: deadline) { throw Failure(description: "No response to \(method) within \(timeout)s") }
        }
        let response = responses.removeValue(forKey: id)!
        if let error = response["error"] as? [String: Any] {
            throw Failure(description: "\(method) failed: \(error["message"] ?? error)")
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    /// Performs the MCP handshake and returns the server's `initialize` result.
    @discardableResult
    public func initialize() throws -> [String: Any] {
        let result = try request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "flotion-tests", "version": "1"],
        ])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return result
    }

    public func listTools() throws -> [[String: Any]] {
        try request("tools/list")["tools"] as? [[String: Any]] ?? []
    }

    public func callTool(_ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let result = try request("tools/call", ["name": name, "arguments": arguments])
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? false)
    }
}
