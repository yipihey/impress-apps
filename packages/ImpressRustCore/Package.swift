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
