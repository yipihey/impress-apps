// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpressRustCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressRustCore",
            targets: ["ImpressRustCore"]
        )
    ],
    targets: [
        // Swift wrapper that re-exports the UniFFI-generated bindings.
        .target(
            name: "ImpressRustCore",
            dependencies: ["impress_store_ffiFFI"],
            path: "Sources/ImpressRustCore",
            linkerSettings: [
                // Each Mach-O image owns its Rust globals (audit, refusals, stores).
                // Export only the public FFI, not Rust implementation symbols.
                .unsafeFlags([
                    "-Xlinker", "-unexported_symbol", "-Xlinker", "__R*",
                    "-Xlinker", "-unexported_symbol", "-Xlinker", "__ZN*17h*E"
                ]),
                .linkedLibrary("sqlite3"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // Binary target for the impress-store-ffi Rust static library.
        // Build with: cd crates/impress-store-ffi && ./build-xcframework.sh
        .binaryTarget(
            name: "impress_store_ffiFFI",
            path: "../../crates/impress-store-ffi/frameworks/ImpressStoreFfi.xcframework"
        )
    ]
)
