// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImprintCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "ImprintCore",
            targets: ["ImprintCore"]
        ),
    ],
    dependencies: [
        .package(path: "../../ImprintRustCore")
    ],
    targets: [
        .target(
            name: "ImprintCore",
            dependencies: [
                .product(name: "ImprintRustCore", package: "ImprintRustCore")
            ],
            path: "Sources/ImprintCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImprintCoreTests",
            dependencies: ["ImprintCore"],
            path: "Tests/ImprintCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
