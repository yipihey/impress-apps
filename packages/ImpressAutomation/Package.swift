// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressAutomation",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressAutomation", targets: ["ImpressAutomation"])
    ],
    dependencies: [
        .package(path: "../ImpressKit"),
        .package(path: "../ImpressLogging")
    ],
    targets: [
        .target(name: "ImpressAutomation", dependencies: ["ImpressKit", "ImpressLogging"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressAutomationTests", dependencies: ["ImpressAutomation"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
