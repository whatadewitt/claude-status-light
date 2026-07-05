// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ClaudeStatusLight",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ClaudeStatusLight",
            path: "Sources/ClaudeStatusLight"
        )
    ]
)
