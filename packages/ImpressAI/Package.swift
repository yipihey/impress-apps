// swift-tools-version: 6.2

import PackageDescription

// Build dependencies list
var dependencies: [Package.Dependency] = [
    .package(path: "../ImpressKit"),
    .package(path: "../ImpressLogging"),
    // Shared chip/flow UI — the one FlowLayout. A local copy had drifted
    // into this package; both copies carried the same single-wide-chip
    // overflow bug, and fixing it once requires there being one.
    .package(path: "../ImpressFTUI"),
    // The Rust AI registry (ADR-0029): every provider, the catalogue and the
    // device selection live in `crates/impress-ai`, reached through the UniFFI
    // bindings in ImpressRustCore. `IMPRESS_RUST_AI` (below) compiles the real
    // `RustAIBridge`; without it the bridge is an "unavailable" stub.
    .package(path: "../ImpressRustCore"),
    .package(url: "https://github.com/evgenyneu/keychain-swift.git", from: "21.0.0"),
]

// Build target dependencies list
var targetDependencies: [Target.Dependency] = [
    .product(name: "ImpressKit", package: "ImpressKit"),
    .product(name: "ImpressLogging", package: "ImpressLogging"),
    .product(name: "ImpressFTUI", package: "ImpressFTUI"),
    .product(name: "ImpressRustCore", package: "ImpressRustCore"),
    .product(name: "KeychainSwift", package: "keychain-swift"),
]

let package = Package(
    name: "ImpressAI",
    platforms: [
        // Every consumer already requires macOS 26 via
        // PublicationManagerCore/ImpressFTUI.
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "ImpressAI",
            targets: ["ImpressAI"]
        ),
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "ImpressAI",
            dependencies: targetDependencies,
            swiftSettings: [
                .define("IMPRESS_RUST_AI"),
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ImpressAITests",
            dependencies: ["ImpressAI"],
            path: "Tests/ImpressAITests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
