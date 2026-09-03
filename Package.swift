// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeCodeHooks",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "ClaudeCodeHooks", targets: ["ClaudeCodeHooks"]),
    ],
    targets: [
        .target(name: "ClaudeCodeHooks", path: "Sources",
                swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .testTarget(name: "ClaudeCodeHooksTests", dependencies: ["ClaudeCodeHooks"], path: "Tests"),
    ]
)
