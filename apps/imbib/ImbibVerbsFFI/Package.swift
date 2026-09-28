// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImbibVerbsFFI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImbibVerbsFFI", targets: ["ImbibVerbsFFI"])
    ],
    targets: [
        .target(
            name: "ImbibVerbsFFI",
            dependencies: ["imbib_verbs_ffiFFI"],
            path: "Sources/ImbibVerbsFFI",
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
            name: "imbib_verbs_ffiFFI",
            path: "../../../crates/imbib-verbs-ffi/frameworks/ImbibVerbsFfi.xcframework"
        )
    ]
)
