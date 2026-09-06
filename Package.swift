// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dayreed",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DayreedCore", targets: ["DayreedCore"]),
        .library(name: "DayreedAgent", targets: ["DayreedAgent"]),
        .library(name: "DayreedCapture", targets: ["DayreedCapture"]),
        .library(name: "DayreedUpdate", targets: ["DayreedUpdate"]),
        .library(name: "DayreedAnalysis", targets: ["DayreedAnalysis"]),
        .executable(name: "DayreedApp", targets: ["DayreedApp"]),
        .executable(name: "dayreed", targets: ["DayreedCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .target(name: "DayreedUpdate", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "DayreedUpdateTests", dependencies: ["DayreedUpdate"]),
        .target(name: "DayreedCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DayreedCapture", dependencies: ["DayreedCore"]),
        .target(name: "DayreedAgent", dependencies: ["DayreedCore"]),
        .target(name: "DayreedAnalysis", dependencies: ["DayreedCore"]),
        .executableTarget(name: "DayreedApp", dependencies: ["DayreedCore", "DayreedCapture", "DayreedUpdate"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "DayreedCLI", dependencies: ["DayreedCore", "DayreedAgent"]),
        .testTarget(name: "DayreedCoreTests", dependencies: ["DayreedCore"]),
        .testTarget(name: "DayreedAgentTests", dependencies: ["DayreedAgent", "DayreedCore"]),
        .testTarget(name: "DayreedCaptureTests", dependencies: ["DayreedCore", "DayreedCapture"]),
        .testTarget(name: "DayreedAnalysisTests", dependencies: ["DayreedCore", "DayreedAnalysis"]),
    ]
)
