// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PublicationManagerCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "PublicationManagerCore",
            targets: ["PublicationManagerCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/evgenyneu/keychain-swift", from: "21.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
        .package(url: "https://github.com/appstefan/HighlightSwift", from: "1.0.0"),
        .package(path: "../ImbibRustCore"),
        .package(path: "../../../packages/ImpressAutomation"),
        .package(path: "../../../packages/ImpressAI")
    ],
    targets: [
        .target(
            name: "PublicationManagerCore",
            dependencies: [
                .product(name: "KeychainSwift", package: "keychain-swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "HighlightSwift", package: "HighlightSwift"),
                "ImbibRustCore",
                "ImpressAutomation",
                "ImpressAI"
            ],
            resources: [
                .copy("Resources/neal_dalal_quote.jpg"),
                .copy("Publishers/Resources/publisher-rules.json")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "PublicationManagerCoreTests",
            dependencies: ["PublicationManagerCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
