// swift-tools-version: 5.9
import PackageDescription

// ⚠️ DEPRECATED: This package is deprecated in favor of impel-helix (Rust crate with UniFFI bindings).
// See crates/impel-helix for the replacement implementation.
// Migration guide: Use `cargo build -p impel-helix --features ffi` to generate Swift bindings.

let package = Package(
    name: "ImpressModalEditing",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressModalEditing", targets: ["ImpressModalEditing"])
    ],
    targets: [
        .target(
            name: "ImpressModalEditing",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ImpressModalEditingTests",
            dependencies: ["ImpressModalEditing"]
        )
    ]
)
