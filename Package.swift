// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterSim",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BetterSim", path: "Sources/BetterSim"),
        .testTarget(name: "BetterSimTests", dependencies: ["BetterSim"], path: "Tests/BetterSimTests"),
    ]
)
