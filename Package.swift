// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AgentIsland", targets: ["AgentIsland"]),
        .executable(name: "agent-island-hook", targets: ["AgentIslandHook"]),
    ],
    targets: [
        .target(name: "IslandCore"),
        .executableTarget(
            name: "AgentIsland",
            dependencies: ["IslandCore"]
        ),
        .executableTarget(
            name: "AgentIslandHook",
            path: "Sources/agent-island-hook"
        ),
        .testTarget(
            name: "IslandCoreTests",
            dependencies: ["IslandCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
