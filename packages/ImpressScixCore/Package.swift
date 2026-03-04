// swift-tools-version: 5.9
// ImpressScixCore — Swift package wrapping the scix-client-ffi XCFramework.
//
// ⚠️  PLACEHOLDER MODE: The XCFramework has not been built yet.
//
//     To build it:
//       cd crates/scix-client-ffi && ./build-xcframework.sh
//
//     After building, replace this Package.swift with the production version:
//
//     .target(
//         name: "ImpressScixCore",
//         dependencies: ["scix_client_ffiFFI"],
//         path: "Sources/ImpressScixCore",
//         linkerSettings: [
//             .linkedFramework("SystemConfiguration"),
//             .linkedFramework("Security"),
//             .linkedFramework("CoreFoundation")
//         ]
//     ),
//     .binaryTarget(
//         name: "scix_client_ffiFFI",
//         path: "../../crates/scix-client-ffi/frameworks/ScixClientCore.xcframework"
//     )

import PackageDescription

let package = Package(
    name: "ImpressScixCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressScixCore",
            targets: ["ImpressScixCore"]
        )
    ],
    targets: [
        // Pure Swift placeholder — real implementation comes from XCFramework.
        // The scix_client_ffi.swift file contains type definitions and stub
        // implementations that will be replaced by uniffi-bindgen output
        // after the XCFramework is built.
        .target(
            name: "ImpressScixCore",
            path: "Sources/ImpressScixCore"
        )
    ]
)
