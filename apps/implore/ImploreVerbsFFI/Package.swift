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
