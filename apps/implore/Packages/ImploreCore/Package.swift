// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ImploreCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ImploreCore",
            targets: ["ImploreCore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ImploreCore",
            dependencies: [],
            path: "Sources/ImploreCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ImploreCoreTests",
            dependencies: ["ImploreCore"],
            path: "Tests/ImploreCoreTests"
        ),
    ]
)
