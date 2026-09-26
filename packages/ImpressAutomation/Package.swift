// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressAutomation",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressAutomation", targets: ["ImpressAutomation"])
    ],
    dependencies: [
        .package(path: "../ImpressKit"),
        .package(path: "../ImpressLogging"),
        // The loopback-token contract (P0, SEC-2) is Rust's
        // (`impress_core::loopback_token`, exported by `impress-store-ffi`);
        // `HTTPServer` calls it to mint and place this launch's token and
        // decides nothing about the path or the format itself.
        .package(path: "../ImpressRustCore")
    ],
    targets: [
        .target(
            name: "ImpressAutomation",
            dependencies: ["ImpressKit", "ImpressLogging", "ImpressRustCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressAutomationTests", dependencies: ["ImpressAutomation"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
