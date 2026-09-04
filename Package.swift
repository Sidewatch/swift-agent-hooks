// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentHooks",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentHooks", targets: ["AgentHooks"]),
    ],
    targets: [
        .target(name: "AgentHooks", path: "Sources",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AgentHooksTests", dependencies: ["AgentHooks"], path: "Tests"),
    ]
)
