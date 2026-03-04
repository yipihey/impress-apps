// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ImploreCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "ImploreCore",
            targets: ["ImploreCore"]
        ),
    ],
    dependencies: [
        .package(path: "../../ImploreRustCore"),
        .package(path: "../../../../packages/ImpressKit"),
        .package(path: "../../../../packages/ImpressRustCore")
    ],
    targets: [
        .target(
            name: "ImploreCore",
            dependencies: [
                "ImploreRustCore",
                .product(name: "ImpressKit", package: "ImpressKit"),
                "ImpressRustCore"
            ],
            path: "Sources/ImploreCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ImploreCoreTests",
            dependencies: ["ImploreCore"],
            path: "Tests/ImploreCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
