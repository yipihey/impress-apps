// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressProgress",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "ImpressProgress",
            targets: ["ImpressProgress"]
        ),
    ],
    targets: [
        .target(
            name: "ImpressProgress",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressProgressTests",
            dependencies: ["ImpressProgress"],
            path: "Tests/ImpressProgressTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
