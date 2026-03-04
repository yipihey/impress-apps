// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressEmbeddings",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressEmbeddings",
            targets: ["ImpressEmbeddings"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ImpressEmbeddings",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressEmbeddingsTests",
            dependencies: ["ImpressEmbeddings"],
            path: "Tests/ImpressEmbeddingsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
