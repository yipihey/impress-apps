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
        // TEST-TARGET-ONLY. `PublicationManagerCore` is wired into
        // `CounselEngineTests` and MUST NOT be added to the `CounselEngine`
        // library target or to either executable target (`journal-submit`,
        // `journal-backfill`).
        //
        // Why: PMC is the shared GUI chassis. It pulls ~20 `packages/Impress*`
        // plus HighlightSwift, SwiftMath and swift-markdown-ui, and both
        // executables link the CounselEngine library — so putting PMC on the
        // library would link the entire GUI stack into two headless CLIs.
        //
        // Why it is here at all: `JournalStatusPolicyParityTests` cross-checks
        // `JournalPipeline.autoSnapshotStatuses` against the canonical
        // manuscript lifecycle in `ManuscriptRecordKind.descriptor.triage`, so
        // the shipped status literals cannot drift from the descriptor that owns
        // them. Only the test needs to see the descriptor; production code
        // deliberately keeps its own derived literal set (see the doc comment on
        // `autoSnapshotStatuses` for the full trade).
        .package(path: "../../../imbib/PublicationManagerCore"),
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
            dependencies: [
                "CounselEngine",
                // Test-only — see the note on the package dependency above.
                // Never add this to `CounselEngine`, `journal-submit` or
                // `journal-backfill`.
                "PublicationManagerCore",
            ],
            path: "Tests/CounselEngineTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
