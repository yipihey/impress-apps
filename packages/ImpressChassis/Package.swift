// swift-tools-version: 6.2
import PackageDescription

// The chassis package (ADR-0021 D5, Stage 3 item C5).
//
// DIRECTION. This package used to be a façade that `@_exported import`ed
// PublicationManagerCore. As of C5 the arrow is reversed: ImpressChassis holds
// real code and PMC depends on it, re-exporting it so every existing
// `import PublicationManagerCore` still resolves every symbol. That is the
// compatibility invariant — zero churn in app targets and tests.
//
// WHAT LIVES HERE, and why so little. C5 measured the cut before making it
// (see ADR-0021 D5 "Extraction status"). `Chassis/` is 97 files / 32.3k LOC,
// but its transitive closure inside PMC is 348 of 545 files — 64% of PMC. The
// chassis is the TOP layer of PMC, not the bottom one, so only files that
// reach NOTHING outside `Chassis/` can move down here without dragging imbib's
// domain with them. There are nine of those; five are here (the four whose
// gated AppKit companions stay in PMC were left behind rather than split
// across a module boundary).
//
// The rule for adding a file: it must reference no PMC symbol at all. If it
// needs one, the question is which class that edge is in — seam, injection
// point, or hard entanglement. The boundary table in ADR-0021 D5 answers that,
// and the answer is a design task, not a file move.
//
// DEPENDENCIES: deliberately none. Every dependency added here would ship to
// every app in the suite (the blast-radius argument in ADR-0018 that
// scripts/check-chassis-deps.sh exists to enforce); the chassis contract is
// data, and data needs Foundation and SwiftUI. That lint polices this manifest
// too, with an allowlist of its own.
let package = Package(
    name: "ImpressChassis",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "ImpressChassis", targets: ["ImpressChassis"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ImpressChassis",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
