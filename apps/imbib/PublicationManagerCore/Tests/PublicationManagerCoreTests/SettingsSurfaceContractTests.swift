//
//  SettingsSurfaceContractTests.swift
//  PublicationManagerCoreTests
//
//  Stage 6 phase 1 oracle for the shared settings surface.
//
//  ADR-0021 D3's trade: `SettingsSectionID` is string-backed so sections are
//  additive, and exhaustiveness moves from the compiler to tests. This is that
//  test. Three things it pins that nothing else can:
//
//  1. The imprint MIGRATION is a reframe, not a redesign — the thirteen macOS
//     tabs, their exact titles, symbols, order and accessibility identifiers,
//     frozen against the `TabView` body that shipped before Stage 6. A tab
//     silently renamed, reordered or dropped by a future settings change fails
//     here.
//  2. Availability actually FILTERS — the iOS screen is a subset of the Mac's
//     for stated reasons, and a preset cannot accidentally promise iOS a pane
//     that needs a TeX toolchain.
//  3. Structural: the declarative half must not get `#if os(macOS)`-gated. Same
//     guard, same reason as `ChassisCrossPlatformContractTests` — a macOS test
//     cannot prove "compiles on iOS", but it can prove nobody re-gated the
//     contract.
//
//  Deliberately NOT `#if os(macOS)`-gated: it is a test ABOUT cross-platform
//  data, and every assertion is answerable from either platform because
//  availability is data rather than an `#if`.
//

import XCTest
@testable import PublicationManagerCore

final class SettingsSurfaceContractTests: XCTestCase {

    // MARK: - 1. The frozen imprint tab inventory

    /// The thirteen tabs `apps/imprint/macOS/Views/SettingsView.swift` shipped,
    /// in order: (id, title, SF Symbol). Transcribed from the pre-Stage-6
    /// `TabView` body. Do not "tidy" this — it is the oracle, not a copy.
    private static let frozenImprintMacTabs: [(id: String, title: String, symbol: String)] = [
        ("appearance", "Appearance", "paintbrush"),
        ("general", "General", "gear"),
        ("editor", "Editor", "doc.text"),
        ("ai", "AI", "sparkles"),
        ("aiTasks", "AI Tasks", "sparkles.rectangle.stack"),
        ("imbib", "Citations", "books.vertical"),
        ("latex", "LaTeX", "function"),
        ("documents", "Documents", "doc.badge.gearshape"),
        ("export", "Export", "square.and.arrow.up"),
        ("account", "Account", "person.circle"),
        ("automation", "Automation", "gearshape.2"),
        ("git", "Git", "arrow.triangle.branch"),
        ("spotlight", "Spotlight", "magnifyingglass"),
    ]

    func testImprintPresetIsTheFrozenThirteenTabInventory() {
        let rendered = AppSettingsConfiguration.imprint.sections(on: .macOS)
        XCTAssertEqual(
            rendered.count, 13,
            "imprint's macOS Settings scene shipped 13 tabs; the reframe must not change the count")
        for (index, expected) in Self.frozenImprintMacTabs.enumerated() {
            let actual = rendered[index]
            XCTAssertEqual(
                actual.id.rawValue, expected.id,
                "tab \(index) must be “\(expected.id)”, not “\(actual.id.rawValue)”")
            XCTAssertEqual(actual.title, expected.title, "tab \(expected.id) title changed")
            XCTAssertEqual(
                actual.systemImage, expected.symbol, "tab \(expected.id) SF Symbol changed")
        }
    }

    /// The identifiers imprint's UI tests and `SettingsPage` address panes by.
    /// Renaming a section id renames these, which is why the id is not free.
    func testAccessibilityIdentifiersAreTheShippedOnes() {
        let byID = Dictionary(
            uniqueKeysWithValues: AppSettingsConfiguration.imprint.sections.map {
                ($0.id.rawValue, $0.accessibilityIdentifier)
            })
        XCTAssertEqual(byID["appearance"], "settings.tabs.appearance")
        XCTAssertEqual(byID["aiTasks"], "settings.tabs.aiTasks")
        // The tab is LABELLED "Citations" and IDENTIFIED as "imbib". Both shipped.
        XCTAssertEqual(byID["imbib"], "settings.tabs.imbib")
        XCTAssertEqual(byID["spotlight"], "settings.tabs.spotlight")
        XCTAssertEqual(
            byID.count, 13, "every section must carry an accessibility identifier")
    }

    // MARK: - Ordering: declaration order IS sort order

    /// `AppSettingsConfiguration` sorts by `order`, but presets are READ in
    /// declaration order. Two representations of one truth drift; this is the
    /// cheap pin that keeps them together.
    func testPresetDeclarationOrderMatchesSortOrder() {
        let orders = AppSettingsConfiguration.imprint.sections.map(\.order)
        XCTAssertEqual(
            orders, orders.sorted(),
            "sections(on:) returns sort order; the preset literal must be written in it too")
        XCTAssertEqual(
            Set(orders).count, orders.count,
            "duplicate `order` values make the display order depend on a stable-sort detail")
    }

    func testDefaultSectionIsAvailableOnBothRenderedPlatforms() {
        let configuration = AppSettingsConfiguration.imprint
        guard let defaultID = configuration.defaultSection else {
            return XCTFail("imprint should land on a known first tab")
        }
        for platform in SettingsPlatform.allCases {
            XCTAssertTrue(
                configuration.sections(on: platform).contains { $0.id == defaultID },
                "\(platform.rawValue) would land on a section it filters out")
        }
    }

    // MARK: - 2. Availability filters, for stated reasons

    func testIOSSurfaceIsTheSubsetThatNeedsNoMacCapability() {
        let ios = AppSettingsConfiguration.imprint.sections(on: .iOS).map(\.id.rawValue)
        XCTAssertEqual(
            ios, ["appearance", "general", "editor", "documents", "account"],
            "imprint-iOS's first settings screen is the five capability-free panes")
    }

    func testEveryMacOnlySectionNamesWhyItIsMacOnly() {
        let macOnly = AppSettingsConfiguration.imprint.sections.filter {
            !$0.availability.platforms.contains(.iOS)
        }
        XCTAssertEqual(macOnly.count, 8)
        // Five of the eight are absent because of a CAPABILITY iOS lacks; the
        // requirement is the machine-readable reason.
        let requirements = Dictionary(
            uniqueKeysWithValues: macOnly.map { ($0.id.rawValue, $0.availability.requirements) })
        XCTAssertEqual(requirements["latex"], [.localToolchain])
        XCTAssertEqual(requirements["git"], [.localToolchain])
        XCTAssertEqual(requirements["automation"], [.httpAutomation])
        XCTAssertEqual(requirements["imbib"], [.siblingAppDiscovery])
        XCTAssertEqual(requirements["spotlight"], [.spotlightIndex])
        // The other three (ai, aiTasks, export) are platform-only: their
        // implementation lives in imprint's macOS target. Stated as an empty
        // requirement set, not as a missing entry.
        XCTAssertEqual(requirements["ai"], [])
        XCTAssertEqual(requirements["aiTasks"], [])
        XCTAssertEqual(requirements["export"], [])
    }

    /// Availability is DATA, so the filter can be driven from either platform —
    /// the property that makes the iOS surface testable by `swift test` on a
    /// Mac. A capability-poor macOS host loses exactly the capability-gated
    /// panes and keeps the platform-only ones.
    func testCapabilitiesFilterIndependentlyOfPlatform() {
        let starved = AppSettingsConfiguration.imprint
            .sections(on: .macOS, capabilities: [])
            .map(\.id.rawValue)
        XCTAssertEqual(
            starved,
            ["appearance", "general", "editor", "ai", "aiTasks", "documents", "export", "account"],
            "a macOS host with no capabilities keeps only the ungated sections")
        XCTAssertFalse(starved.contains("latex"))
        XCTAssertFalse(starved.contains("automation"))
    }

    func testIOSHostGrantsNoneOfTheMacCapabilities() {
        XCTAssertTrue(SettingsHostCapabilities.iOS.isEmpty)
        XCTAssertEqual(
            SettingsHostCapabilities.macOS, Set(SettingsRequirement.allCases),
            "a new requirement must be an explicit decision for macOS, not a default grant")
    }

    // MARK: - Registry

    func testBuiltinRegistryCarriesOnlyGenericChrome() {
        // The chassis must not grow app-shaped panes. Appearance and Spotlight
        // are the two things no app should fork; anything else here would mean
        // PMC linking an app's services.
        XCTAssertEqual(
            SettingsSectionRegistry.builtin.registeredSections,
            [.appearance, .spotlight])
    }

    func testComposingDoesNotMutateTheSharedBuiltinRegistry() {
        let before = SettingsSectionRegistry.builtin.registeredSections
        let composed = SettingsSectionRegistry.builtin.composing([
            SettingsSectionFactory(section: "test-only", makeContent: { _ in fatalError() })
        ])
        XCTAssertTrue(composed.registeredSections.contains("test-only"))
        XCTAssertEqual(
            SettingsSectionRegistry.builtin.registeredSections, before,
            "composing must COPY — a static registry scribbled on by one app's "
                + "registration is the bug the second adopter would find")
    }

    func testAppRegistrationReplacesABuiltinOfTheSameID() {
        let composed = SettingsSectionRegistry.builtin.composing([
            SettingsSectionFactory(section: .appearance, makeContent: { _ in fatalError() })
        ])
        XCTAssertEqual(composed.registeredSections.count, 2, "replacement, not duplication")
    }

    /// The runtime failure mode a preset can have: naming a section nobody
    /// builds. Renderers show a labelled warning; this is the test-time form.
    func testUnresolvedSectionsReportsPanesWithNoFactory() {
        let unresolved = SettingsSectionRegistry.builtin.unresolvedSections(
            of: .imprint, on: .iOS)
        // The chassis alone cannot build imprint's panes — that is correct, and
        // the point of the check: imprint's own registrations supply them.
        XCTAssertEqual(
            Set(unresolved.map(\.rawValue)), ["general", "editor", "documents", "account"])
        XCTAssertFalse(
            unresolved.contains(.appearance), "appearance IS a chassis builtin")
    }

    // MARK: - Settings preset ↔ shell preset agreement

    /// The two presets are siblings; they must not disagree about which apps
    /// exist. (`AppSettingsConfiguration` deliberately lives in its own file —
    /// see its header — so this is the seam that keeps them honest.)
    func testSettingsPresetAppIDMatchesAShellPreset() {
        let shellAppIDs = Set(
            [AppShellConfiguration.imbib, .imprint, .implore, .impart, .impel, .impress]
                .map(\.appID))
        XCTAssertTrue(
            shellAppIDs.contains(AppSettingsConfiguration.imprint.appID),
            "a settings preset for an app with no shell preset is a typo")
    }

    // MARK: - 3. Structural: the gate must not come back

    /// The declarative half of the settings surface. iOS links these; a
    /// `#if os(macOS)` on any of them takes imprint-iOS's settings screen away
    /// again, which is the exact regression Stage 6 exists to prevent.
    private static let crossPlatformContractFiles = [
        "Chassis/Settings/SettingsSectionDescriptor.swift",
        "Chassis/Settings/SettingsSectionRegistry.swift",
        "Chassis/Settings/AppSettingsConfiguration.swift",
    ]

    func testSettingsContractFilesAreNotWrappedInAMacOSGate() throws {
        for relativePath in Self.crossPlatformContractFiles {
            // Two of the three now live in `packages/ImpressChassis` (C5); the
            // registry, which reads `AppearanceMode` from PMC's theme layer,
            // does not. `ChassisSourceRoots` resolves either.
            let text = try ChassisSourceRoots.text(of: relativePath)
            let firstCode = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? ""
            XCTAssertFalse(
                firstCode.hasPrefix("#if os(macOS)"),
                """
                \(relativePath) is wrapped in `#if os(macOS)`. It is the \
                DECLARATIVE half of the settings surface: iOS reads it to \
                render `IOSSettingsScreen`. If a genuinely platform-bound \
                symbol landed in it, SPLIT the file (data here, renderer in a \
                gated companion) — never re-gate the contract.
                """)
        }
    }

    /// The renderers are the split-out halves, one gate each. The split is only
    /// worth anything if each really is separate.
    ///
    /// Stage 6 phase 2 added a THIRD renderer —
    /// `MacSettingsSidebarSceneContent`, the grouped source-list layout imbib's
    /// sixteen-pane Settings scene needs — and it is listed here for the same
    /// reason the other two are: a renderer that lost its gate would drag AppKit
    /// layout into the iOS build, and one that GAINED a gate it should not have
    /// would take a platform's settings away again. Note the count of gated
    /// renderers is now 3 against 3 ungated contract files: renderers multiply
    /// per platform AND per layout, declarations do not.
    func testRenderersStayPlatformGated() throws {
        for (relativePath, gate) in [
            ("Chassis/Settings/MacSettingsSceneContent.swift", "#if os(macOS)"),
            ("Chassis/Settings/MacSettingsSidebarSceneContent.swift", "#if os(macOS)"),
            ("Chassis/Settings/IOSSettingsScreen.swift", "#if os(iOS)"),
        ] {
            let text = try ChassisSourceRoots.text(of: relativePath)
            XCTAssertTrue(
                text.hasPrefix(gate), "\(relativePath) must start with `\(gate)`")
        }
    }
}
