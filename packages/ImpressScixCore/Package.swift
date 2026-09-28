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
        .target(
            name: "ImpressScixCore",
            dependencies: ["scix_client_ffiFFI"],
            path: "Sources/ImpressScixCore",
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
            name: "scix_client_ffiFFI",
            path: "../../crates/scix-client-ffi/frameworks/ScixClientCore.xcframework"
        )
    ]
)
