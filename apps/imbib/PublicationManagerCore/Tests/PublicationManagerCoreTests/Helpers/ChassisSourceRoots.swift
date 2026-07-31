//
//  ChassisSourceRoots.swift
//  PublicationManagerCoreTests
//
//  Stage 3 item C5 (ADR-0021 D5): the chassis now lives in TWO packages, so
//  the structural contract tests need two roots.
//
//  Several suites here assert on chassis SOURCE TEXT rather than on behaviour
//  — "this contract file is not wrapped in `#if os(macOS)`", "this file spells
//  the row-identifier prefix the UI suites match by prefix". Those assertions
//  are worth more than the behavioural ones (a macOS test cannot prove
//  "compiles on iOS"; it CAN prove nobody re-gated the file), and they all
//  resolve a path like `Chassis/Settings/AppSettingsConfiguration.swift`
//  against PMC's own Sources directory.
//
//  C5 moved five of those files into `packages/ImpressChassis`, mirroring the
//  folder shape minus the leading `Chassis/` component. Rather than teach each
//  suite which files moved — a list that would go stale the moment the
//  extraction grows — this resolver tries PMC first and falls back to the
//  chassis package. A path resolves as long as the file exists in EITHER, so
//  moving one more file down needs no edit here; a path that resolves in
//  neither still fails loudly, which is the property the suites depend on.
//

import Foundation

/// Locates a chassis source file across the two packages it may live in.
enum ChassisSourceRoots {

    /// `<repo>/apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore`,
    /// derived from this file's own path so the tests stay location-independent.
    static let publicationManagerCore: URL =
        packageRoot.appendingPathComponent("Sources/PublicationManagerCore")

    /// `<repo>/packages/ImpressChassis/Sources/ImpressChassis`.
    static let impressChassis: URL =
        repoRoot.appendingPathComponent("packages/ImpressChassis/Sources/ImpressChassis")

    /// Resolves a `Chassis/…`-rooted (or PMC-rooted) relative path to whichever
    /// package holds it.
    ///
    /// Inside `packages/ImpressChassis` the folder shape is the chassis one
    /// with the leading `Chassis/` dropped — `Chassis/Settings/X.swift` is
    /// `Sources/ImpressChassis/Settings/X.swift` — so a caller keeps spelling
    /// the path it always spelled.
    static func url(for relativePath: String) -> URL {
        let inPMC = publicationManagerCore.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: inPMC.path) { return inPMC }

        let withoutChassisPrefix = relativePath.hasPrefix("Chassis/")
            ? String(relativePath.dropFirst("Chassis/".count))
            : relativePath
        let inChassis = impressChassis.appendingPathComponent(withoutChassisPrefix)
        if FileManager.default.fileExists(atPath: inChassis.path) { return inChassis }

        // Neither: hand back the PMC path so the caller's read fails with the
        // path it asked for, which is the more useful error.
        return inPMC
    }

    /// The text of a chassis source file, from whichever package holds it.
    static func text(of relativePath: String) throws -> String {
        try String(contentsOf: url(for: relativePath), encoding: .utf8)
    }

    /// `<repo>/apps/imbib/PublicationManagerCore`.
    private static let packageRoot: URL =
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Helpers
            .deletingLastPathComponent()   // PublicationManagerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PublicationManagerCore

    /// `<repo>`.
    static let repoRoot: URL =
        packageRoot
            .deletingLastPathComponent()   // imbib
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // repo root

    /// The text of a repo-rooted file (an APP target's source, which PMC's test
    /// bundle cannot link). Used by the structural suites that assert what an
    /// app does or does not call.
    static func repoText(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
