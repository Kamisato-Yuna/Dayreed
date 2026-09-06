// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dayreed",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DayreedCore", targets: ["DayreedCore"]),
        .executable(name: "DayreedApp", targets: ["DayreedApp"]),
        .executable(name: "dayreed", targets: ["DayreedCLI"]),
    ],
    targets: [
        .target(name: "DayreedCore"),
        .executableTarget(name: "DayreedApp", dependencies: ["DayreedCore"]),
        .executableTarget(name: "DayreedCLI", dependencies: ["DayreedCore"]),
        .testTarget(name: "DayreedCoreTests", dependencies: ["DayreedCore"]),
    ]
)
