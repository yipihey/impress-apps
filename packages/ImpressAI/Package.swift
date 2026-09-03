// swift-tools-version: 6.2

import PackageDescription
import Foundation

// Check if ImpressLLM XCFramework is available
let impressLLMPath = "../ImpressLLM"
let impressLLMAvailable = FileManager.default.fileExists(
    atPath: "\(impressLLMPath)/../../crates/impress-llm/frameworks/ImpressLLM.xcframework"
)

// Build dependencies list
var dependencies: [Package.Dependency] = [
    .package(path: "../ImpressKit"),
    .package(path: "../ImpressLogging"),
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
    .product(name: "ImpressRustCore", package: "ImpressRustCore"),
    .product(name: "KeychainSwift", package: "keychain-swift"),
]

// Add ImpressLLM if available
if impressLLMAvailable {
    dependencies.append(.package(path: impressLLMPath))
    targetDependencies.append(.product(name: "ImpressLLM", package: "ImpressLLM"))
}

let package = Package(
    name: "ImpressAI",
    platforms: [
        // Raised to match ImpressLLM (v26); every consumer already requires
        // macOS 26 via PublicationManagerCore/ImpressFTUI.
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
            swiftSettings: impressLLMAvailable ? [
                .define("IMPRESS_LLM_AVAILABLE"),
                .define("IMPRESS_RUST_AI"),
                .swiftLanguageMode(.v5)
            ] : [
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
