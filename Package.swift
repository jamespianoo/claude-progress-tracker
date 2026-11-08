// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessionTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TrackerCore"),
        .executableTarget(name: "ClaudeSessionTracker", dependencies: ["TrackerCore"]),
        .testTarget(name: "TrackerCoreTests", dependencies: ["TrackerCore"]),
    ]
)
