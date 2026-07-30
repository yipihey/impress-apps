// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PublicationManagerCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
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
        // GUI-meld Phase 3: the Typst compile/edit stack moves into PMC.
        // ImprintCore is the Swift wrapper around the in-process Typst
        // renderer (transitively links ImprintRustCore + ImprintCore.xcframework);
        // ImpressSyntaxHighlight backs the source editor's highlighting.
        .package(path: "../../imprint/Packages/ImprintCore"),
        .package(path: "../../../packages/ImpressSyntaxHighlight"),
        .package(path: "../../../packages/ImpressRustCore"),
        .package(path: "../../../packages/ImpressScixCore"),
        .package(path: "../../../packages/ImpressAutomation"),
        .package(path: "../../../packages/ImpressAI"),
        .package(path: "../../../packages/ImpressKeyboard"),
        .package(path: "../../../packages/ImpressSidebar"),
        .package(path: "../../../packages/ImpressFTUI"),
        .package(path: "../../../packages/ImpressMailStyle"),
        .package(path: "../../../packages/ImpressLogging"),
        .package(path: "../../../packages/ImpressStoreKit"),
        .package(path: "../../../packages/ImpressOperationQueue"),
        .package(path: "../../../packages/ImpressKit"),
        .package(path: "../../../packages/ImpressEmbeddings"),
        .package(path: "../../../packages/ImpressSpotlight"),
        .package(path: "../../../packages/ImpressTheme"),
        .package(path: "../../../packages/ImpressUndoHistory"),
        .package(path: "../../../packages/ImpressSmartSearch"),
        .package(path: "../../../packages/ImpressHelixCore"),
        // ADR-0021 D5 / C5: the extracted half of the chassis contract. PMC
        // depends on it and `@_exported import`s it (see
        // `Chassis/ImpressChassisReexport.swift`), so every existing
        // `import PublicationManagerCore` still resolves every symbol — the
        // compatibility invariant of the lift. The arrow used to point the
        // other way (ImpressChassis was a façade over PMC).
        .package(path: "../../../packages/ImpressChassis")
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
                .product(name: "ImprintCore", package: "ImprintCore"),
                "ImpressSyntaxHighlight",
                "ImpressRustCore",
                "ImpressScixCore",
                "ImpressAutomation",
                "ImpressAI",
                "ImpressKeyboard",
                "ImpressSidebar",
                "ImpressFTUI",
                "ImpressMailStyle",
                "ImpressLogging",
                "ImpressStoreKit",
                "ImpressOperationQueue",
                "ImpressKit",
                .product(name: "ImpressEmbeddings", package: "ImpressEmbeddings"),
                "ImpressSpotlight",
                "ImpressTheme",
                "ImpressUndoHistory",
                "ImpressSmartSearch",
                "ImpressHelixCore",
                "ImpressChassis"
            ],
            resources: [
                .copy("Resources/neal_dalal_quote.jpg"),
                .copy("Resources/mathjax")
                // `Publishers/Resources/publisher-rules.json` was removed in
                // Stage 7 item 9: it was a stale 12-rule subset of
                // DefaultRules.swift's 16, it shipped in every app bundle, and
                // nothing ever loaded it (`setCustomRulesPath` had no callers).
                // The rule table now lives in imbib-core.
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PublicationManagerCoreTests",
            dependencies: [
                "PublicationManagerCore",
                // Imported directly by the smart-search parity suite and by
                // ADSQueryNormalizerTests (which now assert the Rust
                // implementation through the real FFI).
                "ImpressSmartSearch",
                "ImbibRustCore",
            ],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
