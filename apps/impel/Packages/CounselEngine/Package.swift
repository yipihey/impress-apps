// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CounselEngine",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "CounselEngine",
            targets: ["CounselEngine"]
        ),
        .executable(
            name: "journal-submit",
            targets: ["journal-submit"]
        ),
        .executable(
            name: "journal-backfill",
            targets: ["journal-backfill"]
        ),
    ],
    dependencies: [
        .package(path: "../ImpelMail"),
        .package(path: "../../../../packages/ImpressAI"),
        .package(path: "../../../../packages/ImpressLogging"),
        .package(path: "../../../../packages/ImpressStoreKit"),
        .package(path: "../../../../packages/ImpressKit"),
        .package(path: "../../../../packages/ImpressRustCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CounselEngine",
            dependencies: [
                "ImpelMail",
                "ImpelToolsFFI",
                "ImpressAI",
                "ImpressLogging",
                "ImpressStoreKit",
                "ImpressKit",
                "ImpressRustCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CounselEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // UniFFI bindings for `crates/impel-tools`, which projects the
        // #[impress_service] inventory into the agent loop's tool surface.
        // Both this file and the XCFramework are produced by
        // `crates/impel-tools/build-xcframework.sh` — regenerate together.
        .target(
            name: "ImpelToolsFFI",
            dependencies: ["impel_toolsFFI"],
            path: "Sources/ImpelToolsFFI",
            // UniFFI emits a mutable global (`initializationResult`) that Swift 6
            // strict concurrency rejects. Generated code — pin the language mode
            // rather than patching it, since the file is regenerated on every build.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .binaryTarget(
            name: "impel_toolsFFI",
            path: "../../../../crates/impel-tools/frameworks/ImpelTools.xcframework"
        ),
        .executableTarget(
            name: "journal-submit",
            dependencies: ["CounselEngine"],
            path: "Sources/journal-submit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "journal-backfill",
            dependencies: ["CounselEngine"],
            path: "Sources/journal-backfill",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CounselEngineTests",
            dependencies: ["CounselEngine"],
            path: "Tests/CounselEngineTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
