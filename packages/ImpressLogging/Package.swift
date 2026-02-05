// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ImpressLogging",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressLogging", targets: ["ImpressLogging"])
    ],
    targets: [
        .target(name: "ImpressLogging"),
        .testTarget(name: "ImpressLoggingTests", dependencies: ["ImpressLogging"])
    ]
)
