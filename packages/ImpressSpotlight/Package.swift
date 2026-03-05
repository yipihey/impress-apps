// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressSpotlight",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressSpotlight", targets: ["ImpressSpotlight"])
    ],
    dependencies: [
        .package(path: "../ImpressKit"),
        .package(path: "../ImpressLogging"),
    ],
    targets: [
        .target(
            name: "ImpressSpotlight",
            dependencies: ["ImpressKit", "ImpressLogging"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressSpotlightTests",
            dependencies: ["ImpressSpotlight"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
