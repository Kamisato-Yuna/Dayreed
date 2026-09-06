// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dayreed",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DayreedCore", targets: ["DayreedCore"]),
        .library(name: "DayreedCapture", targets: ["DayreedCapture"]),
        .executable(name: "DayreedApp", targets: ["DayreedApp"]),
        .executable(name: "dayreed", targets: ["DayreedCLI"]),
    ],
    targets: [
        .target(name: "DayreedCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DayreedCapture", dependencies: ["DayreedCore"]),
        .executableTarget(name: "DayreedApp", dependencies: ["DayreedCore", "DayreedCapture"]),
        .executableTarget(name: "DayreedCLI", dependencies: ["DayreedCore"]),
        .testTarget(name: "DayreedCoreTests", dependencies: ["DayreedCore"]),
        .testTarget(name: "DayreedCaptureTests", dependencies: ["DayreedCore", "DayreedCapture"]),
    ]
)
