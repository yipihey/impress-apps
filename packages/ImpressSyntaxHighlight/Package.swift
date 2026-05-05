// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressSyntaxHighlight",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ImpressSyntaxHighlight", targets: ["ImpressSyntaxHighlight"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.9.0"),
    ],
    targets: [
        // Vendored tree-sitter-latex grammar (pre-generated parser.c + scanner.c)
        .target(
            name: "TreeSitterLaTeX",
            path: "Sources/TreeSitterLaTeX",
            exclude: [],
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
            ]
        ),
        // Vendored tree-sitter-typst grammar
        .target(
            name: "TreeSitterTypst",
            path: "Sources/TreeSitterTypst",
            exclude: [],
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
            ]
        ),
        // Public Swift API — wraps Neon + SwiftTreeSitter
        .target(
            name: "ImpressSyntaxHighlight",
            dependencies: [
                "TreeSitterLaTeX",
                "TreeSitterTypst",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            ],
            resources: [
                .copy("Resources/latex-highlights.scm"),
                .copy("Resources/typst-highlights.scm"),
            ]
        ),
    ]
)
