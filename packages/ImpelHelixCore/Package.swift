// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpelHelixCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpelHelixCore",
            targets: ["ImpelHelixCore"]
        )
    ],
    targets: [
        // The main Swift wrapper that re-exports the generated code
        .target(
            name: "ImpelHelixCore",
            dependencies: ["impel_helixFFI"],
            path: "Sources/ImpelHelixCore"
        ),
        // Binary target for the Rust static library
        .binaryTarget(
            name: "impel_helixFFI",
            path: "../../crates/impel-helix/frameworks/ImpelHelix.xcframework"
        )
    ]
)
