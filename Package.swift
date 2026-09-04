// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeCodeHooks",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeCodeHooks", targets: ["ClaudeCodeHooks"]),
    ],
    targets: [
        .target(name: "ClaudeCodeHooks", path: "Sources",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ClaudeCodeHooksTests", dependencies: ["ClaudeCodeHooks"], path: "Tests"),
    ]
)
