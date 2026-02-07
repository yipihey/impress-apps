// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpelMail",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ImpelMail",
            targets: ["ImpelMail"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ImpelMail",
            dependencies: [],
            path: "Sources/ImpelMail",
            resources: [.copy("Resources/localhost.p12")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpelMailTests",
            dependencies: ["ImpelMail"],
            path: "Tests/ImpelMailTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
