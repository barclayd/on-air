// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OnAirCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "OnAirCore", targets: ["OnAirCore"]),
        .library(name: "OnAirVisuals", targets: ["OnAirVisuals"]),
        .library(name: "OnAirSession", targets: ["OnAirSession"]),
    ],
    targets: [
        .target(name: "OnAirCore"), .target(name: "OnAirVisuals"),
        .target(name: "OnAirSession"),
        .testTarget(name: "OnAirSessionTests", dependencies: ["OnAirSession", "OnAirCore"]),
    ]
)
