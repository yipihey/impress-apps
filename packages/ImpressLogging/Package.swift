// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressLogging",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressLogging", targets: ["ImpressLogging"])
    ],
    targets: [
        .target(name: "ImpressLogging", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressLoggingTests", dependencies: ["ImpressLogging"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
