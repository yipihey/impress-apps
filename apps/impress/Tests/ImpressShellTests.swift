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

    /// The root consumes the preset UNCHANGED. This is the D9 claim in its
    /// smallest testable form: if a future edit adds `withCustomSurfaces` or
    /// `presenting` here, the shell has started having opinions the preset
    /// cannot express, and that should be a deliberate change.
    @MainActor
    func testMacRootRunsTheUnmodifiedImpressPreset() {
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
