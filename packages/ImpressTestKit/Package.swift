// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressTestKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImpressTestKit", targets: ["ImpressTestKit"])
    ],
    targets: [
        .target(name: "ImpressTestKit")
    ]
)
