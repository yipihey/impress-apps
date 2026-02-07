// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressTestKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ImpressTestKit", targets: ["ImpressTestKit"])
    ],
    targets: [
        .target(name: "ImpressTestKit", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
