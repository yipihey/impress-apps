// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressSmartSearch",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "ImpressSmartSearch",
            targets: ["ImpressSmartSearch"]
        ),
        .executable(
            name: "smartsearch-debug",
            targets: ["smartsearch-debug"]
        ),
    ],
    dependencies: [
        // The deterministic search logic lives in Rust
        // (`crates/impress-smart-search`) and reaches Swift through
        // ImbibCore.xcframework, which PMC already links into every app that
        // embeds it — so this port added no new binary framework. Precedent for
        // a `packages/` module depending on this wrapper: ImpressPublicationUI.
        .package(path: "../../apps/imbib/ImbibRustCore"),
    ],
    targets: [
        .target(
            name: "ImpressSmartSearch",
            dependencies: ["ImbibRustCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "smartsearch-debug",
            dependencies: ["ImpressSmartSearch"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressSmartSearchTests",
            dependencies: ["ImpressSmartSearch"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
