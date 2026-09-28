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
                // Each Mach-O image owns its Rust globals (audit, refusals, stores).
                // Export only the public FFI, not Rust implementation symbols.
                .unsafeFlags([
                    "-Xlinker", "-unexported_symbol", "-Xlinker", "__R*",
                    "-Xlinker", "-unexported_symbol", "-Xlinker", "__ZN*17h*E"
                ]),
                .linkedLibrary("sqlite3"),
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
