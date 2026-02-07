// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressSidebar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressSidebar", targets: ["ImpressSidebar"])
    ],
    targets: [
        .target(name: "ImpressSidebar", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ImpressSidebarTests", dependencies: ["ImpressSidebar"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
