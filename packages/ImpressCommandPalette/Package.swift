// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressCommandPalette",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressCommandPalette", targets: ["ImpressCommandPalette"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ImpressCommandPalette", dependencies: []),
        .testTarget(name: "ImpressCommandPaletteTests", dependencies: ["ImpressCommandPalette"])
    ]
)
