// swift-tools-version: 6.2
import PackageDescription

// THROWAWAY. The standalone proof of plan wave 6 W6: an app that links ONLY
// ImpressLayout and ImpressRustCore (ImpressSurface, ImpressKeyboard and
// ImpressLogging arrive through ImpressLayout) and still draws a layout tree.
// Not an Xcode project, not in impress.xcworkspace, not shipped. See README.md.
let package = Package(
    name: "KitDemo",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../packages/ImpressLayout"),
        .package(path: "../../packages/ImpressRustCore")
    ],
    targets: [
        .executableTarget(
            name: "KitDemo",
            dependencies: [
                .product(name: "ImpressLayout", package: "ImpressLayout"),
                .product(name: "ImpressRustCore", package: "ImpressRustCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
