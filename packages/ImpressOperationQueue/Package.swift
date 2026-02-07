// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressOperationQueue",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressOperationQueue", targets: ["ImpressOperationQueue"])
    ],
    dependencies: [
        .package(path: "../ImpressLogging")
    ],
    targets: [
        .target(
            name: "ImpressOperationQueue",
            dependencies: ["ImpressLogging"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressOperationQueueTests",
            dependencies: ["ImpressOperationQueue"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
