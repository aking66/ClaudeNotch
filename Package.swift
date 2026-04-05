// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            path: "Sources/ClaudeNotch"
        ),
        // Tiny helper binary invoked by Claude Code hooks. Reads the JSON
        // event from stdin and forwards it to the running ClaudeNotch app
        // over a Unix domain socket, then exits.
        .executableTarget(
            name: "ClaudeNotchBridge",
            path: "Sources/ClaudeNotchBridge"
        )
    ]
)
