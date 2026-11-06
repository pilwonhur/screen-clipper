// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ScreenClipper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScreenClipper", targets: ["ScreenClipper"]),
        .executable(name: "clipper-spike", targets: ["ClipperSpike"]),
        .library(name: "ClipperCore", targets: ["ClipperCore"]),
    ],
    targets: [
        // Capture, stitching, OCR, summary, Discord and Obsidian logic (no UI).
        .target(name: "ClipperCore"),
        // The menu-bar app.
        .executableTarget(name: "ScreenClipper", dependencies: ["ClipperCore"]),
        // M0 command-line tool: capture/stitch without the app UI.
        .executableTarget(name: "ClipperSpike", dependencies: ["ClipperCore"], path: "Sources/clipper-spike"),
        .testTarget(name: "ClipperCoreTests", dependencies: ["ClipperCore"]),
    ]
)
