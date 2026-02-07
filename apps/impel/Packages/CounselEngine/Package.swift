// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CounselEngine",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "CounselEngine",
            targets: ["CounselEngine"]
        ),
    ],
    dependencies: [
        .package(path: "../ImpelMail"),
        .package(path: "../../../../packages/ImpressAI"),
        .package(path: "../../../../packages/ImpressLogging"),
        .package(path: "../../../../packages/ImpressKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CounselEngine",
            dependencies: [
                "ImpelMail",
                "ImpressAI",
                "ImpressLogging",
                "ImpressKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CounselEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CounselEngineTests",
            dependencies: ["CounselEngine"],
            path: "Tests/CounselEngineTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
