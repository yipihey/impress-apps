// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressOperationQueue",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressOperationQueue", targets: ["ImpressOperationQueue"])
    ],
    dependencies: [
        .package(path: "../ImpressLogging")
    ],
    targets: [
        .target(
            name: "ImpressOperationQueue",
            dependencies: ["ImpressLogging"]
        ),
        .testTarget(
            name: "ImpressOperationQueueTests",
            dependencies: ["ImpressOperationQueue"]
        )
    ]
)
