// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImprintCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
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
            path: "Sources/ImprintCore"
        ),
        .testTarget(
            name: "ImprintCoreTests",
            dependencies: ["ImprintCore"],
            path: "Tests/ImprintCoreTests"
        ),
    ]
)
