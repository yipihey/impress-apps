// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpartVerbsFFI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpartVerbsFFI", targets: ["ImpartVerbsFFI"])
    ],
    targets: [
        .target(
            name: "ImpartVerbsFFI",
            dependencies: ["impart_verbs_ffiFFI"],
            path: "Sources/ImpartVerbsFFI",
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
            name: "impart_verbs_ffiFFI",
            path: "../../../crates/impart-verbs-ffi/frameworks/ImpartVerbsFfi.xcframework"
        )
    ]
)
