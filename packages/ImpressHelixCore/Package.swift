// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressHelixCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
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
            path: "Sources/ImpressHelixCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Binary target for the Rust static library
        .binaryTarget(
            name: "impress_helixFFI",
            path: "../../crates/impress-helix/frameworks/ImpressHelix.xcframework"
        )
    ]
)
