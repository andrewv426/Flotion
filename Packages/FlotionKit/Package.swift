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
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
        // swift-markdown publishes toolchain-matched tags rather than semver.
        .package(url: "https://github.com/swiftlang/swift-markdown", revision: "swift-6.3.2-RELEASE"),
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
    ],
    swiftLanguageModes: [.v6]
)
