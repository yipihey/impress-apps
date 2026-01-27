// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImprintRustCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImprintRustCore",
            targets: ["ImprintRustCore"]
        )
    ],
    targets: [
        .target(
            name: "ImprintRustCore",
            dependencies: ["imprint_coreFFI"],
            path: "Sources/ImprintRustCore"
        ),
        .binaryTarget(
            name: "imprint_coreFFI",
            // Note: When building from imprint.xcodeproj, the path is relative to the package
            path: "../Frameworks/ImprintCore.xcframework"
        )
    ]
)
