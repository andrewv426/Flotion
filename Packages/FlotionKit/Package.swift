// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "FlotionKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FlotionCore", targets: ["FlotionCore"]),
        .library(name: "FlotionMCP", targets: ["FlotionMCP"]),
        .library(name: "FlotionEditor", targets: ["FlotionEditor"]),
        .executable(name: "flotion-mcp", targets: ["flotion-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
        // swift-markdown publishes toolchain-matched tags rather than semver.
        .package(url: "https://github.com/swiftlang/swift-markdown", revision: "swift-6.3.2-RELEASE"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "FlotionCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "FlotionCoreTests",
            dependencies: ["FlotionCore"],
            swiftSettings: strict
        ),
        .target(
            name: "FlotionMCP",
            dependencies: ["FlotionCore", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "flotion-mcp",
            dependencies: ["FlotionMCP"],
            swiftSettings: strict
        ),
        // Drives a real flotion-mcp process over stdio; shared by contract and budget tests.
        .target(
            name: "FlotionTestSupport",
            swiftSettings: strict
        ),
        .testTarget(
            name: "FlotionMCPTests",
            dependencies: ["FlotionCore", "FlotionMCP", "FlotionTestSupport", "flotion-mcp", .product(name: "MCP", package: "swift-sdk")],
            swiftSettings: strict
        ),
        // Budget tests: public API only, run with `swift test -c release`.
        .testTarget(
            name: "FlotionPerfTests",
            dependencies: ["FlotionCore", "FlotionTestSupport", "flotion-mcp"],
            swiftSettings: strict
        ),
        .target(
            name: "FlotionEditor",
            dependencies: ["FlotionCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "FlotionEditorTests",
            dependencies: ["FlotionCore", "FlotionEditor"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
