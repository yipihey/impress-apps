// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressSidebar",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressSidebar", targets: ["ImpressSidebar"])
    ],
    targets: [
        .target(name: "ImpressSidebar"),
        .testTarget(name: "ImpressSidebarTests", dependencies: ["ImpressSidebar"])
    ]
)
