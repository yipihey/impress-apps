// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressSmartSearch",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "ImpressSmartSearch",
            targets: ["ImpressSmartSearch"]
        ),
        .executable(
            name: "smartsearch-debug",
            targets: ["smartsearch-debug"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ImpressSmartSearch",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "smartsearch-debug",
            dependencies: ["ImpressSmartSearch"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressSmartSearchTests",
            dependencies: ["ImpressSmartSearch"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
