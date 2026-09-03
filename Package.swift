// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZoneCapture",
    platforms: [.macOS(.v13)],
    targets: [
        // Core library: pure logic (SQLite Store + URLFetcher) that both the
        // executable and the test target depend on. Keeping GUI/bootstrap code
        // out of here so the logic is testable without instantiating NSPanels
        // or registering global hotkeys.
        .target(
            name: "ZoneCaptureCore",
            path: "Sources/ZoneCaptureCore",
            resources: [],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),

        // Executable: the actual menu-bar app. Imports ZoneCaptureCore for
        // Store and URLFetcher; owns AppDelegate, CapturePanel, HotkeyManager,
        // and main.swift.
        .executableTarget(
            name: "ZoneCapture",
            dependencies: ["ZoneCaptureCore"],
            path: "Sources/ZoneCapture",
            resources: [],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),

        .testTarget(
            name: "ZoneCaptureTests",
            dependencies: ["ZoneCaptureCore"],
            path: "Tests/ZoneCaptureTests"
        ),
    ]
)
