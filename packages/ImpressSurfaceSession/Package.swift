// swift-tools-version: 6.2
import PackageDescription

// The session that shows one generated surface, on both platforms.
// ImpressLayout is the macOS window and does not build for iOS, so the
// model, the feed, and the two Sendable conformances live here. ImpressSurface
// stays the renderer and does not link the store. One conformance: a second
// copy in a host would collide in the macOS binary.
let package = Package(
    name: "ImpressSurfaceSession",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressSurfaceSession", targets: ["ImpressSurfaceSession"])
    ],
    dependencies: [
        .package(path: "../ImpressRustCore"),
        .package(path: "../ImpressSurface"),
        .package(path: "../ImpressLogging")
    ],
    targets: [
        .target(
            name: "ImpressSurfaceSession",
            dependencies: ["ImpressRustCore", "ImpressSurface", "ImpressLogging"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ImpressSurfaceSessionTests",
            dependencies: ["ImpressSurfaceSession"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
