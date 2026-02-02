// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressKeyboard",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressKeyboard", targets: ["ImpressKeyboard"])
    ],
    targets: [
        .target(name: "ImpressKeyboard"),
        .testTarget(name: "ImpressKeyboardTests", dependencies: ["ImpressKeyboard"])
    ]
)
