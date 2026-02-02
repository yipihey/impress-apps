// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MessageManagerCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "MessageManagerCore",
            targets: ["MessageManagerCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/evgenyneu/keychain-swift", from: "21.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/appstefan/HighlightSwift", from: "1.0.0"),
        .package(path: "../ImpartRustCore"),
        .package(path: "../../../packages/ImpressAutomation"),
        .package(path: "../../../packages/ImpressAI"),
        .package(path: "../../../packages/ImpressKeyboard")
    ],
    targets: [
        .target(
            name: "MessageManagerCore",
            dependencies: [
                .product(name: "KeychainSwift", package: "keychain-swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "HighlightSwift", package: "HighlightSwift"),
                "ImpartRustCore",
                "ImpressAutomation",
                "ImpressAI",
                "ImpressKeyboard"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MessageManagerCoreTests",
            dependencies: ["MessageManagerCore"]
        )
    ]
)
