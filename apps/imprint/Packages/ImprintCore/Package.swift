// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImprintCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "ImprintCore",
            targets: ["ImprintCore"]
        ),
    ],
    dependencies: [
        .package(path: "../../ImprintRustCore"),
        .package(path: "../../../../packages/ImpressKit"),
        .package(path: "../../../../packages/ImpressLogging"),
        .package(path: "../../../../packages/ImpressRustCore"),
        .package(path: "../../../../packages/ImpressStoreKit")
    ],
    targets: [
        .target(
            name: "ImprintCore",
            dependencies: [
                .product(name: "ImprintRustCore", package: "ImprintRustCore"),
                .product(name: "ImpressKit", package: "ImpressKit"),
                .product(name: "ImpressLogging", package: "ImpressLogging"),
                "ImpressRustCore",
                .product(name: "ImpressStoreKit", package: "ImpressStoreKit")
            ],
            path: "Sources/ImprintCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // NOTE: The test target does not build successfully under
        // `swift test` because SwiftPM does not re-link the
        // `impress_store_ffiFFI` binary target (in the ImpressRustCore
        // package) into the test executable. This is a pre-existing
        // SwiftPM limitation, not a regression from the gateway work.
        // The tests do compile and run under `xcodebuild test -scheme
        // imprint` because Xcode resolves the binary target correctly.
        // The gateway test file (`ImprintImpressStoreTests.swift`)
        // exercises the read methods against an in-memory SharedStore
        // and will run once we fix the SwiftPM linking.
        .testTarget(
            name: "ImprintCoreTests",
            dependencies: ["ImprintCore"],
            path: "Tests/ImprintCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
