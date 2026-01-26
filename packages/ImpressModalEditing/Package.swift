// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImpressModalEditing",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImpressModalEditing", targets: ["ImpressModalEditing"])
    ],
    targets: [
        .target(
            name: "ImpressModalEditing",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ImpressModalEditingTests",
            dependencies: ["ImpressModalEditing"]
        )
    ]
)
