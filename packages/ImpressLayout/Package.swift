// swift-tools-version: 6.2
import PackageDescription

// The layout host, moved out of PublicationManagerCore (plan wave 6, W6;
// ADR-0033 D7, ADR-0031 D9). It renders a Rust-owned layout tree: `Linear`
// → a split, `Tabs` → a strip, `Grid` → a grid, `Pane` → whatever view
// factory the `ViewKindRegistry` holds for the pane's view kind. The kit
// itself registers two, `placeholder` and `surface`; every domain view kind
// (outline, list, info, pdf, notes, bibtex, source, legacy) is a factory the
// HOST registers at startup — PublicationManagerCore does it from
// `ChassisRootView`. With nothing registered the kit still draws the whole
// tree, as placeholders, which is what makes it a kit.
//
// Kit-grade on purpose, and policed by `scripts/check-kit-packages.sh`:
// ImpressRustCore for `SharedLayout` / `SharedSurface` / `SharedStore`,
// ImpressSurface for `SurfaceView`, ImpressKeyboard for `.keyboardGuarded`
// and the h/l grammar, ImpressLogging for the three-point trace. ImpressTheme
// is on the list and arrives through ImpressSurface. NOT
// PublicationManagerCore, ImpressAutomation (it pulls ImpressKit), ImpressKit,
// MarkdownUI or any app core: a host that wants more hands it in (a store
// opener, surface hooks, view-kind factories).
//
// macOS only: every file is the macOS window's renderer. iOS has no tree.
let package = Package(
    name: "ImpressLayout",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ImpressLayout", targets: ["ImpressLayout"])
    ],
    dependencies: [
        .package(path: "../ImpressRustCore"),
        .package(path: "../ImpressSurface"),
        .package(path: "../ImpressKeyboard"),
        .package(path: "../ImpressLogging")
    ],
    targets: [
        .target(
            name: "ImpressLayout",
            dependencies: ["ImpressRustCore", "ImpressSurface", "ImpressKeyboard", "ImpressLogging"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ImpressLayoutTests",
            dependencies: ["ImpressLayout"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
