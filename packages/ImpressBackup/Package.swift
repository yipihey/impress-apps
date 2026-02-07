// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressBackup",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressBackup", targets: ["ImpressBackup"])
    ],
    targets: [
        .target(name: "ImpressBackup", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressBackupTests", dependencies: ["ImpressBackup"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
