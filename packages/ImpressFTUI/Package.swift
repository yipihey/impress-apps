// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressFTUI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressFTUI", targets: ["ImpressFTUI"])
    ],
    targets: [
        .target(name: "ImpressFTUI", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressFTUITests", dependencies: ["ImpressFTUI"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
