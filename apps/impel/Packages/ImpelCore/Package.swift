// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpelCore",
    platforms: [
        .macOS(.v26)
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
            path: "Sources/ImpelCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpelCoreTests",
            dependencies: ["ImpelCore"],
            path: "Tests/ImpelCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
