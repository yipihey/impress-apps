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
        // `swift test` works here, including the `impress_store_ffiFFI`
        // binary target from ImpressRustCore, provided both xcframeworks
        // have been built first:
        //   bash crates/imprint-core/build-xcframework.sh
        //   bash crates/impress-store-ffi/build-xcframework.sh
        // (The first also generates the ../../ImprintRustCore package this
        // manifest depends on.) imprint-swift.yml runs exactly that.
        .testTarget(
            name: "ImprintCoreTests",
            dependencies: ["ImprintCore"],
            path: "Tests/ImprintCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
