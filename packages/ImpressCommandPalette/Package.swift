// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressCommandPalette",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressCommandPalette", targets: ["ImpressCommandPalette"])
    ],
    // ImpressKit is the ONLY dependency, and it is here for exactly one
    // reason: `SiblingApp.descriptors` is THE sibling-app table (bundle IDs,
    // URL schemes, HTTP automation ports). This package's whole job is dialling
    // the sibling apps, so that table is its domain model, not foreign weight.
    // ImpressKit is itself a leaf package (no package dependencies of its own),
    // and every app that would host the palette already links it.
    //
    // The package was previously `dependencies: []` and carried its OWN copy of
    // the port table — in which impel and implore were transposed. That is the
    // drift a parity test can only report after the fact; a single table makes
    // it unrepresentable.
    dependencies: [
        .package(path: "../ImpressKit")
    ],
    targets: [
        .target(
            name: "ImpressCommandPalette",
            dependencies: [.product(name: "ImpressKit", package: "ImpressKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ImpressCommandPaletteTests", dependencies: ["ImpressCommandPalette"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
