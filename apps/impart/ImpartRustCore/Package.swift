// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpartRustCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpartRustCore",
            targets: ["ImpartRustCore"]
        )
    ],
    targets: [
        // Placeholder target - will be replaced with FFI bindings when Rust core is built
        .target(
            name: "ImpartRustCore",
            path: "Sources/ImpartRustCore"
        )
    ]
)
