// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressPublicationUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ImpressPublicationUI", targets: ["ImpressPublicationUI"]),
    ],
    dependencies: [
        // ImbibRustCore lives under apps/imbib/ImbibRustCore. Relative path from
        // packages/ImpressPublicationUI is ../../apps/imbib/ImbibRustCore.
        .package(path: "../../apps/imbib/ImbibRustCore"),
    ],
    targets: [
        .target(
            name: "ImpressPublicationUI",
            dependencies: [
                .product(name: "ImbibRustCore", package: "ImbibRustCore"),
            ]
        ),
    ]
)
