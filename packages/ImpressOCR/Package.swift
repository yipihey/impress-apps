// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImpressOCR",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "ImpressOCR", targets: ["ImpressOCR"]),
        .executable(name: "impress-ocr", targets: ["impress-ocr"]),
    ],
    targets: [
        .target(
            name: "ImpressOCR",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "impress-ocr",
            dependencies: ["ImpressOCR"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ImpressOCRTests",
            dependencies: ["ImpressOCR"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
