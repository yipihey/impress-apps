// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressMailStyle",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressMailStyle", targets: ["ImpressMailStyle"])
    ],
    dependencies: [
        .package(path: "../ImpressFTUI")
    ],
    targets: [
        .target(
            name: "ImpressMailStyle",
            dependencies: ["ImpressFTUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressMailStyleTests",
            dependencies: ["ImpressMailStyle"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
