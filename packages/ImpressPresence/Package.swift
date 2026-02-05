// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpressPresence",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressPresence",
            targets: ["ImpressPresence"]
        ),
    ],
    targets: [
        .target(
            name: "ImpressPresence"
        ),
        .testTarget(
            name: "ImpressPresenceTests",
            dependencies: ["ImpressPresence"],
            path: "Tests/ImpressPresenceTests"
        ),
    ]
)
