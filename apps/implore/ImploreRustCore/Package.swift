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
            path: "Sources/ImploreRustCore",
            linkerSettings: [
                // Each Mach-O image owns its Rust globals (audit, refusals, stores).
                // Export only the public FFI, not Rust implementation symbols.
                .unsafeFlags([
                    "-Xlinker", "-unexported_symbol", "-Xlinker", "__R*",
                    "-Xlinker", "-unexported_symbol", "-Xlinker", "__ZN*17h*E"
                ]),
                .linkedLibrary("sqlite3")
            ]
        ),
        // Binary target for the Rust static library
        .binaryTarget(
            name: "implore_coreFFI",
            path: "../Frameworks/ImploreCore.xcframework"
        )
    ]
)
