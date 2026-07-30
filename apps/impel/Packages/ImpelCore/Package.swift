// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpelCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ImpelCore",
            targets: ["ImpelCore"]
        ),
    ],
    dependencies: [
        .package(path: "../../../../packages/ImpressKit"),
        // Stage 0: direct reads from the shared item store (task@1.0.0 /
        // agent-run@1.0.0 rows written by impel-taskd).
        .package(path: "../../../../packages/ImpressRustCore"),
        // The shared store-mirror kernel: `LazyStoreHandle` (open once, remember
        // the failure) and the buffering/batching write gate this adapter will
        // need when its command path moves off HTTP.
        .package(path: "../../../../packages/ImpressStoreKit"),
    ],
    targets: [
        .target(
            name: "ImpelCore",
            dependencies: [
                "ImpressKit",
                .product(name: "ImpressRustCore", package: "ImpressRustCore"),
                .product(name: "ImpressStoreKit", package: "ImpressStoreKit"),
            ],
            path: "Sources/ImpelCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpelCoreTests",
            dependencies: ["ImpelCore"],
            path: "Tests/ImpelCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
