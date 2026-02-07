// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressKit", targets: ["ImpressKit"])
    ],
    targets: [
        .target(name: "ImpressKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressKitTests", dependencies: ["ImpressKit"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
