//
//  ImpressShellTests.swift
//  impressTests
//
//  What this app target CLAIMS, asserted here rather than in PMC — because
//  these are facts about the SHELL (which preset it runs, what it registers),
//  and PMC deliberately cannot link an app target.
//

import ImpressKit
import PublicationManagerCore
import XCTest

@testable import impress

final class ImpressShellTests: XCTestCase {

    /// The root consumes the preset UNCHANGED, and its SIDEBAR is the
    /// composition of the other five.
    ///
    /// This replaced `testMacRootRunsTheUnmodifiedImpressPreset`, whose whole
    /// claim was that this shell has no opinions the preset cannot express.
    /// That claim is still here — every assertion it made is below — but it is
    /// no longer the WHOLE story, and a test that stopped at the preset would
    /// now be quietly asserting the wrong thing: what impress renders and what
    /// its sidebar SHOWS became two questions on 2026-07-31.
    ///
    /// They are two values for a reason. The preset says which sections and
    /// kinds this window may render (all of them, which is why
    /// `presentableKinds` stays nil and the parity suites still pin the flat
    /// preset). The composition says whose sidebar each row belongs to — the
    /// fact a UNION of sections cannot carry, and the reason flat impress had
    /// exactly one Flagged section, bound to `.publication`, and no row anywhere
    /// for a flagged manuscript.
    @MainActor
    func testMacRootRunsTheImpressPresetAndTheComposedSidebar() {
        let shell = ImpressChassisRoot.shellConfiguration
        XCTAssertEqual(shell.appID, AppShellConfiguration.impress.appID)
        XCTAssertEqual(shell.visibleSections, AppShellConfiguration.impress.visibleSections)
        XCTAssertNil(
            shell.presentableKinds,
            "macOS impress presents every kind; narrowing it would be a claim that is not true")
        XCTAssertTrue(
            shell.customSurfaces.appSurfaces.isEmpty,
            "impress registers NO app-owned surfaces — the grouped-search surface it shows "
                + "is the chassis builtin, and registering a copy would replace it")

        // The sidebar: the five sibling presets, as groups, in the suite
        // table's order. Nothing here names a section, a record kind or an app.
        let composition = ImpressChassisRoot.sidebarComposition
        XCTAssertEqual(composition, SidebarComposition.impress)
        XCTAssertEqual(
            composition.appIDs,
            SiblingApp.descriptors.map(\.id).filter { $0 != .impress }.map(\.rawValue),
            "the groups and their order are a lookup into the one suite table")
        XCTAssertNil(
            composition["impress"],
            "impress owns no domain, so it contributes no group — it IS the window")
        for (id, preset) in [
            ("imbib", AppShellConfiguration.imbib), ("imprint", .imprint),
            ("implore", .implore), ("impel", .impel), ("impart", .impart),
        ] {
            XCTAssertEqual(
                composition[id]?.configuration, preset,
                "\(id)'s group must BE \(id)'s shipping preset, not a copy that can drift")
        }
    }

    /// The composition lifts the exact limitation the flat preset has, and the
    /// flat preset still has it — which is why they are two values.
    @MainActor
    func testTheComposedSidebarBindsFlaggedPerAppWhereTheFlatPresetCannot() {
        XCTAssertEqual(
            AppShellConfiguration.impress.sectionBindings[.flagged], .publication,
            "a union names ONE kind per section; this is the loss, still present")
        XCTAssertEqual(
            ImpressChassisRoot.sidebarComposition["imbib"]?
                .configuration.recordKind(for: .flagged),
            .publication)
        XCTAssertEqual(
            ImpressChassisRoot.sidebarComposition["imprint"]?
                .configuration.recordKind(for: .flagged),
            .manuscript,
            "impress must have a Flagged section that means MANUSCRIPTS — the row that did "
                + "not exist anywhere under the flat preset")
    }

    /// The builtin store-search surface still arrives without registration.
    /// This is what makes "register none" honest rather than an omission.
    @MainActor
    func testTheGroupedSearchSurfaceArrivesFromTheChassisBuiltin() {
        let ids = ImpressChassisRoot.shellConfiguration.customSurfaces.surfaces.map(\.id)
        XCTAssertTrue(
            ids.contains(StoreSearchSurface.surfaceID),
            "⌘⇧F's target must be present in the registry without an app-side registration")
    }

    /// Every section the preset permits must resolve to something. `permits`
    /// and `passesFacetGate` are two independent gates and impress is the one
    /// shell that must pass BOTH for the facet sections — an `==` owner test
    /// anywhere would silently blank Figures/Mail/Agents here.
    @MainActor
    func testEveryPermittedSectionAlsoPassesTheFacetGate() {
        let shell = ImpressChassisRoot.shellConfiguration
        for section in SidebarSectionType.allCases where shell.permits(section) {
            XCTAssertTrue(
                shell.passesFacetGate(section),
                ".\(section.rawValue) is permitted but fails the facet gate, so it would "
                    + "never render")
        }
    }

    /// impress's automation server binds THE port table's row for it, and the
    /// registered default agrees. Both drifted in the suite before (implore and
    /// impel bound the same socket), which is why this is a test and not a
    /// comment.
    func testAutomationPortComesFromTheSiblingTable() {
        XCTAssertEqual(ImpressHTTPServer.defaultPort, SiblingApp.impress.httpPort)
        XCTAssertEqual(SiblingApp.impress.httpPort, 23125)
        XCTAssertEqual(SiblingApp.app(forHTTPPort: 23125), .impress)
    }

    /// The two settings families must agree that this app exists, and the
    /// settings preset must be buildable from what the app registers plus the
    /// chassis builtins.
    @MainActor
    func testSettingsPresetIsFullyResolvable() {
        let unresolved = ImpressSettingsSections.registry.unresolvedSections(
            of: .impress, on: .macOS)
        XCTAssertTrue(
            unresolved.isEmpty,
            "impress declares settings panes with no factory: \(unresolved)")
        XCTAssertEqual(AppSettingsConfiguration.impress.appID, AppShellConfiguration.impress.appID)
    }
}
