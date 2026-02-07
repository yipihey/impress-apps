// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MessageManagerCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
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
        .package(path: "../../../packages/ImpressKeyboard"),
        .package(path: "../../../packages/ImpressSidebar"),
        .package(path: "../../../packages/ImpressLogging"),
        .package(path: "../../../packages/ImpressOperationQueue")
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
                "ImpressKeyboard",
                "ImpressSidebar",
                "ImpressLogging",
                "ImpressOperationQueue"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MessageManagerCoreTests",
            dependencies: ["MessageManagerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
