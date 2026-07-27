// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressPublicationUI",
    platforms: [
        // Raised from .v14 to match ImpressFTUI (the suite's shared tag/flag
        // UI); the apps consuming this panel already require macOS 26 via
        // PublicationManagerCore → ImpressFTUI.
        .macOS(.v26),
    ],
    products: [
        .library(name: "ImpressPublicationUI", targets: ["ImpressPublicationUI"]),
    ],
    dependencies: [
        // ImbibRustCore lives under apps/imbib/ImbibRustCore. Relative path from
        // packages/ImpressPublicationUI is ../../apps/imbib/ImbibRustCore.
        .package(path: "../../apps/imbib/ImbibRustCore"),
        // Shared tag chips / flow layout (CLAUDE.md: always use the shared
        // versions, never hand-rolled capsules).
        .package(path: "../ImpressFTUI"),
    ],
    targets: [
        .target(
            name: "ImpressPublicationUI",
            dependencies: [
                .product(name: "ImbibRustCore", package: "ImbibRustCore"),
                .product(name: "ImpressFTUI", package: "ImpressFTUI"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
