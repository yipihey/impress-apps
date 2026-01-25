// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImbibRustCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImbibRustCore",
            targets: ["ImbibRustCore"]
        )
    ],
    targets: [
        // The main Swift wrapper that re-exports the generated code
        .target(
            name: "ImbibRustCore",
            dependencies: ["imbib_coreFFI"],
            path: "Sources/ImbibRustCore",
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
            name: "imbib_coreFFI",
            path: "../../../crates/imbib-core/frameworks/ImbibCore.xcframework"
        )
    ]
)
