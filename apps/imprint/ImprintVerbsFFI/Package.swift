// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImprintVerbsFFI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImprintVerbsFFI", targets: ["ImprintVerbsFFI"])
    ],
    targets: [
        .target(
            name: "ImprintVerbsFFI",
            dependencies: ["imprint_verbs_ffiFFI"],
            path: "Sources/ImprintVerbsFFI",
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
            name: "imprint_verbs_ffiFFI",
            path: "../../../crates/imprint-verbs-ffi/frameworks/ImprintVerbsFfi.xcframework"
        )
    ]
)
