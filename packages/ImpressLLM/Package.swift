// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpressLLM",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressLLM",
            targets: ["ImpressLLM"]
        )
    ],
    targets: [
        // The main Swift wrapper that re-exports the generated code
        .target(
            name: "ImpressLLM",
            dependencies: ["impress_llmFFI"],
            path: "Sources/ImpressLLM",
            linkerSettings: [
                // Required by Rust's system-configuration crate (used by reqwest for proxy config)
                .linkedFramework("SystemConfiguration"),
                // Required by Rust's security-framework crate (used by native-tls)
                .linkedFramework("Security"),
                // Required by Rust's core-foundation crate
                .linkedFramework("CoreFoundation")
            ]
        ),
        // Binary target for the Rust static library
        .binaryTarget(
            name: "impress_llmFFI",
            path: "../../crates/impress-llm/frameworks/ImpressLLM.xcframework"
        )
    ]
)
