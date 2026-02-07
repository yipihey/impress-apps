// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressPresence",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "ImpressPresence",
            targets: ["ImpressPresence"]
        ),
    ],
    targets: [
        .target(
            name: "ImpressPresence",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressPresenceTests",
            dependencies: ["ImpressPresence"],
            path: "Tests/ImpressPresenceTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
