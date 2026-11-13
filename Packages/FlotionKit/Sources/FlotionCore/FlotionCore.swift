import Foundation

/// Shared constants for every Flotion process (app, MCP server, tests).
public enum Flotion {
    public static let version = "0.1.0"

    /// Default workspace database location.
    public static var defaultDatabaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Flotion", isDirectory: true)
            .appendingPathComponent("flotion.sqlite")
    }
}
