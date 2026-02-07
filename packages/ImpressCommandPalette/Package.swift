// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressCommandPalette",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressCommandPalette", targets: ["ImpressCommandPalette"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ImpressCommandPalette", dependencies: [], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressCommandPaletteTests", dependencies: ["ImpressCommandPalette"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
