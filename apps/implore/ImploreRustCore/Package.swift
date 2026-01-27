// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImploreRustCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ImploreRustCore",
            targets: ["ImploreRustCore"]
        )
    ],
    targets: [
        // The main Swift wrapper that re-exports the generated code
        .target(
            name: "ImploreRustCore",
            dependencies: ["implore_coreFFI"],
            path: "Sources/ImploreRustCore"
        ),
        // Binary target for the Rust static library
        .binaryTarget(
            name: "implore_coreFFI",
            path: "../Frameworks/ImploreCore.xcframework"
        )
    ]
)
