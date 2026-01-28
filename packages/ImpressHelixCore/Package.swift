// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpressHelixCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressHelixCore",
            targets: ["ImpressHelixCore"]
        )
    ],
    targets: [
        // The main Swift wrapper that re-exports the generated code
        .target(
            name: "ImpressHelixCore",
            dependencies: ["impress_helixFFI"],
            path: "Sources/ImpressHelixCore"
        ),
        // Binary target for the Rust static library
        .binaryTarget(
            name: "impress_helixFFI",
            path: "../../crates/impress-helix/frameworks/ImpressHelix.xcframework"
        )
    ]
)
