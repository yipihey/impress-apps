// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressKeyboard",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressKeyboard", targets: ["ImpressKeyboard"])
    ],
    targets: [
        .target(name: "ImpressKeyboard", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressKeyboardTests", dependencies: ["ImpressKeyboard"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
