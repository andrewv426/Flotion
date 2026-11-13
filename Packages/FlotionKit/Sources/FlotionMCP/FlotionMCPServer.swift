import FlotionCore
import Foundation
import MCP

/// Entry point for the `flotion-mcp` executable.
///   FLOTION_DB     path to the workspace database (default: the app's database)
///   FLOTION_ACTOR  label recorded on every write (default: "mcp")
public enum FlotionMCPServer {
    public static func run() async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let databaseURL = environment["FLOTION_DB"].map { URL(fileURLWithPath: $0) } ?? Flotion.defaultDatabaseURL
        do {
            let workspace = try Workspace(url: databaseURL)
            let tools = FlotionTools(workspace: workspace, actor: environment["FLOTION_ACTOR"] ?? "mcp")
            let server = Server(
                name: "flotion", version: Flotion.version, instructions: FlotionTools.instructions,
                capabilities: .init(tools: .init(listChanged: false)))
            _ = await server.withMethodHandler(ListTools.self) { _ in .init(tools: FlotionTools.definitions) }
            _ = await server.withMethodHandler(CallTool.self) { params in
                tools.call(params.name, params.arguments ?? [:])
            }
            try await server.start(transport: BlockingStdioTransport())
            await server.waitUntilCompleted()
            return 0
        } catch {
            FileHandle.standardError.write(Data("flotion-mcp: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
