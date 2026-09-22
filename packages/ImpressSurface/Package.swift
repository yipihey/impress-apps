// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImpressSurface",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ImpressSurface", targets: ["ImpressSurface"])
    ],
    // Kit-grade on purpose (ADR-0033 D7): ImpressKeyboard for
    // `.keyboardGuarded`, ImpressTheme for the cross-platform `Color`
    // helpers a surface's `log`/`kv`/`status` widgets want, ImpressLogging
    // for the `.plain` hooks' default trace line. NOT ImpressRustCore,
    // PublicationManagerCore, ImprintRustCore or MarkdownUI — this package
    // renders a `RenderTree` it is handed and never opens a store, a plot
    // engine or a markdown parser itself; the host supplies all three
    // through `SurfaceHooks` (see that file's header).
    dependencies: [
        .package(path: "../ImpressKeyboard"),
        .package(path: "../ImpressTheme"),
        .package(path: "../ImpressLogging")
    ],
    targets: [
        .target(
            name: "ImpressSurface",
            dependencies: ["ImpressKeyboard", "ImpressTheme", "ImpressLogging"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpressSurfaceTests",
            dependencies: ["ImpressSurface"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
