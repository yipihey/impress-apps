// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressDeposit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressDeposit", targets: ["ImpressDeposit"])
    ],
    targets: [
        .target(name: "ImpressDeposit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressDepositTests", dependencies: ["ImpressDeposit"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
