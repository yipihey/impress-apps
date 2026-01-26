// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpelCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ImpelCore",
            targets: ["ImpelCore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ImpelCore",
            dependencies: [],
            path: "Sources/ImpelCore"
        ),
        .testTarget(
            name: "ImpelCoreTests",
            dependencies: ["ImpelCore"],
            path: "Tests/ImpelCoreTests"
        ),
    ]
)
