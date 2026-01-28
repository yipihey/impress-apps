// swift-tools-version: 5.9

import PackageDescription
import Foundation

// Check if ImpressLLM XCFramework is available
let impressLLMPath = "../ImpressLLM"
let impressLLMAvailable = FileManager.default.fileExists(
    atPath: "\(impressLLMPath)/../../crates/impress-llm/frameworks/ImpressLLM.xcframework"
)

// Build dependencies list
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/evgenyneu/keychain-swift.git", from: "21.0.0"),
]

// Build target dependencies list
var targetDependencies: [Target.Dependency] = [
    .product(name: "KeychainSwift", package: "keychain-swift"),
]

// Add ImpressLLM if available
if impressLLMAvailable {
    dependencies.append(.package(path: impressLLMPath))
    targetDependencies.append(.product(name: "ImpressLLM", package: "ImpressLLM"))
}

let package = Package(
    name: "ImpressAI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ImpressAI",
            targets: ["ImpressAI"]
        ),
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "ImpressAI",
            dependencies: targetDependencies,
            swiftSettings: impressLLMAvailable ? [
                .define("IMPRESS_LLM_AVAILABLE")
            ] : []
        ),
        .testTarget(
            name: "ImpressAITests",
            dependencies: ["ImpressAI"],
            path: "Tests/ImpressAITests"
        ),
    ]
)
