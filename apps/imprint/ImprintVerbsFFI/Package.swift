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
