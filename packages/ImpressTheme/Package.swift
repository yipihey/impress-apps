// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressTheme",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressTheme", targets: ["ImpressTheme"])
    ],
    targets: [
        .target(name: "ImpressTheme", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressThemeTests", dependencies: ["ImpressTheme"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
