// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnAirRegression",
    platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "OnAirE2ETests", path: "EndToEnd", resources: [.copy("Baselines")])]
)
