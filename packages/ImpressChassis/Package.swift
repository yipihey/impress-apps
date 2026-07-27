// swift-tools-version: 6.2
import PackageDescription

// Stage 3 façade (ADR-0021 / Stage-2 WP-X1): new app shells import
// `ImpressChassis`, so the eventual physical extraction of the chassis out of
// PublicationManagerCore touches zero app code. Extraction trigger: all three
// app conversions shipped AND the descriptor API stable across two
// consecutive record-kind additions AND measurable build/size pain.
let package = Package(
    name: "ImpressChassis",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ImpressChassis", targets: ["ImpressChassis"])
    ],
    dependencies: [
        .package(path: "../../apps/imbib/PublicationManagerCore"),
    ],
    targets: [
        .target(
            name: "ImpressChassis",
            dependencies: [
                .product(name: "PublicationManagerCore", package: "PublicationManagerCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
