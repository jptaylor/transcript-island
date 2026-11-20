// swift-tools-version: 6.0
import PackageDescription

// The app's logic that doesn't need a microphone or a screen, so it can be unit tested:
// accumulating the transcript, wrapping it into caption lines, and detecting pauses.
let package = Package(
    name: "TranscriptCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranscriptCore", targets: ["TranscriptCore"]),
    ],
    targets: [
        .target(name: "TranscriptCore"),
        .testTarget(name: "TranscriptCoreTests", dependencies: ["TranscriptCore"]),
    ]
)
