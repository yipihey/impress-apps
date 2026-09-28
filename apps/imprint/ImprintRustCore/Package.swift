// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImprintRustCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImprintRustCore",
            targets: ["ImprintRustCore"]
        )
    ],
    targets: [
        .target(
            name: "ImprintRustCore",
            dependencies: ["imprint_coreFFI"],
            path: "Sources/ImprintRustCore",
            linkerSettings: [
                // Each Mach-O image owns its Rust globals (audit, refusals, stores).
                // Export only the public FFI, not Rust implementation symbols.
                .unsafeFlags([
                    "-Xlinker", "-unexported_symbol", "-Xlinker", "__R*",
                    "-Xlinker", "-unexported_symbol", "-Xlinker", "__ZN*17h*E"
                ]),
                .linkedLibrary("sqlite3")
            ]
        ),
        .binaryTarget(
            name: "imprint_coreFFI",
            // Note: When building from imprint.xcodeproj, the path is relative to the package
            path: "../Frameworks/ImprintCore.xcframework"
        )
    ]
)
