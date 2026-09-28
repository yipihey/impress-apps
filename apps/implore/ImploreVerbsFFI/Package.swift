// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImploreVerbsFFI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImploreVerbsFFI", targets: ["ImploreVerbsFFI"])
    ],
    targets: [
        .target(
            name: "ImploreVerbsFFI",
            dependencies: ["implore_verbs_ffiFFI"],
            path: "Sources/ImploreVerbsFFI",
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
        .binaryTarget(
            name: "implore_verbs_ffiFFI",
            path: "../../../crates/implore-verbs-ffi/frameworks/ImploreVerbsFfi.xcframework"
        )
    ]
)
