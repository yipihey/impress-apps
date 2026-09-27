// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressKit",
    // 26 like every package and app that depends on this one (the 14/17
    // floor was a leftover no consumer could use); ImpressLogging, which
    // ImpressSettings logs through, is 26 too.
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressKit", targets: ["ImpressKit"])
    ],
    dependencies: [
        // The settings registry is Rust's (`crates/impress-settings`, ADR-0036
        // D5); `ImpressSettings` and `@ImpressSetting` are a projection over
        // the UniFFI `SharedSettings` object and hold no declaration of their
        // own.
        .package(path: "../ImpressRustCore"),
        .package(path: "../ImpressLogging"),
    ],
    targets: [
        .target(
            name: "ImpressKit",
            dependencies: ["ImpressRustCore", "ImpressLogging"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressKitTests", dependencies: ["ImpressKit"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
