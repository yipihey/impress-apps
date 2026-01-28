// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressBackup",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressBackup", targets: ["ImpressBackup"])
    ],
    targets: [
        .target(name: "ImpressBackup"),
        .testTarget(name: "ImpressBackupTests", dependencies: ["ImpressBackup"])
    ]
)
