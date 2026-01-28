// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressAutomation",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressAutomation", targets: ["ImpressAutomation"])
    ],
    targets: [
        .target(name: "ImpressAutomation"),
        .testTarget(name: "ImpressAutomationTests", dependencies: ["ImpressAutomation"])
    ]
)
