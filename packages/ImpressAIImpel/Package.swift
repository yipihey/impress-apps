// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpressAIImpel",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressAIImpel",
            targets: ["ImpressAIImpel"]
        ),
    ],
    dependencies: [
        .package(path: "../ImpressAI"),
    ],
    targets: [
        .target(
            name: "ImpressAIImpel",
            dependencies: ["ImpressAI"]
        ),
        .testTarget(
            name: "ImpressAIImpelTests",
            dependencies: ["ImpressAIImpel"]
        ),
    ]
)
