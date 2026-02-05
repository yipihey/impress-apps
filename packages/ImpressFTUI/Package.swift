// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressFTUI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressFTUI", targets: ["ImpressFTUI"])
    ],
    targets: [
        .target(name: "ImpressFTUI"),
        .testTarget(name: "ImpressFTUITests", dependencies: ["ImpressFTUI"])
    ]
)
