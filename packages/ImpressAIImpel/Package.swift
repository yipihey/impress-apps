// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressAIImpel",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
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
            dependencies: ["ImpressAI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressAIImpelTests",
            dependencies: ["ImpressAIImpel"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
