// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressStoreKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressStoreKit", targets: ["ImpressStoreKit"])
    ],
    dependencies: [
        .package(path: "../ImpressLogging")
    ],
    targets: [
        .target(
            name: "ImpressStoreKit",
            dependencies: ["ImpressLogging"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressStoreKitTests",
            dependencies: ["ImpressStoreKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
