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
