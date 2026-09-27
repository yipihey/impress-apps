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
