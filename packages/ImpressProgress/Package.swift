// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpressProgress",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressProgress",
            targets: ["ImpressProgress"]
        ),
    ],
    targets: [
        .target(
            name: "ImpressProgress"
        ),
        .testTarget(
            name: "ImpressProgressTests",
            dependencies: ["ImpressProgress"],
            path: "Tests/ImpressProgressTests"
        ),
    ]
)
