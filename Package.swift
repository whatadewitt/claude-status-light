// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeStatusLight",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ClaudeStatusLight",
            path: "Sources/ClaudeStatusLight",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeStatusLightTests",
            dependencies: ["ClaudeStatusLight"],
            path: "Tests/ClaudeStatusLightTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
