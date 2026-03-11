// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressToolbox",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressToolbox", targets: ["ImpressToolbox"])
    ],
    dependencies: [
        .package(path: "../ImpressLogging")
    ],
    targets: [
        .target(
            name: "ImpressToolbox",
            dependencies: ["ImpressLogging"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
