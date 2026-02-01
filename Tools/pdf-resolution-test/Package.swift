// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PDFResolutionTest",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "pdf-resolution-test",
            targets: ["PDFResolutionTest"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "PDFResolutionTest",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
