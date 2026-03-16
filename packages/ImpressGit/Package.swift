// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressGit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressGit", targets: ["ImpressGit"])
    ],
    dependencies: [
        .package(path: "../ImpressToolbox"),
        .package(path: "../ImpressLogging"),
        .package(path: "../ImpressKit"),
    ],
    targets: [
        .target(
            name: "ImpressGit",
            dependencies: ["ImpressToolbox", "ImpressLogging", "ImpressKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressGitTests",
            dependencies: ["ImpressGit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
