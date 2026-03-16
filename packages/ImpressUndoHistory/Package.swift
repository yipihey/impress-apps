// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressUndoHistory",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressUndoHistory", targets: ["ImpressUndoHistory"])
    ],
    dependencies: [
        .package(path: "../ImpressKit"),
        .package(path: "../ImpressLogging"),
        .package(path: "../ImpressTheme"),
    ],
    targets: [
        .target(
            name: "ImpressUndoHistory",
            dependencies: ["ImpressKit", "ImpressLogging", "ImpressTheme"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressUndoHistoryTests",
            dependencies: ["ImpressUndoHistory"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
