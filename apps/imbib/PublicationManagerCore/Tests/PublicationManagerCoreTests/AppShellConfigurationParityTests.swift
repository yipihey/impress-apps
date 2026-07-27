//
//  AppShellConfigurationParityTests.swift
//  PublicationManagerCoreTests
//
//  S1-WP2 regression oracle: the v2 declarative fields must derive EXACTLY
//  the frozen Boolean truth table in docs/chassis-capability-matrix.md
//  ("Frozen shell-preset truth table"). If a preset edit changes a derived
//  value, that is a deliberate behavior change and the matrix must move too.
//

import XCTest
@testable import PublicationManagerCore

#if os(macOS)
final class AppShellConfigurationParityTests: XCTestCase {

    func testImbibPresetMatchesFrozenTruthTable() {
        let c = AppShellConfiguration.imbib
        XCTAssertTrue(c.auxiliaryRoutes.contains(.submissionsInbox))
        XCTAssertNotEqual(c.recordKind(for: .flagged), .manuscript)
        XCTAssertNotEqual(c.recordKind(for: .dismissed), .manuscript)
        XCTAssertEqual(c.openBehavior(for: .manuscript), .appHandoff)
        XCTAssertNil(c.visibleSections, "imbib shows everything")
        XCTAssertEqual(c.defaultSection, .inbox)
        XCTAssertEqual(c.defaultDetailTab, .info)
    }

    func testImprintPresetMatchesFrozenTruthTable() {
        let c = AppShellConfiguration.imprint
        XCTAssertFalse(c.auxiliaryRoutes.contains(.submissionsInbox))
        XCTAssertEqual(c.recordKind(for: .flagged), .manuscript)
        XCTAssertEqual(c.recordKind(for: .dismissed), .manuscript)
        XCTAssertEqual(c.openBehavior(for: .manuscript), .window(id: "manuscript-editor"))
        XCTAssertEqual(
            c.visibleSections,
            [.manuscripts, .citedInManuscripts, .flagged, .dismissed]
        )
        XCTAssertEqual(c.defaultSection, .manuscripts)
        XCTAssertEqual(c.defaultDetailTab, .source)
    }

    /// Stage 2-B: the Figures section must never surface in imbib or imprint.
    /// imprint is excluded by visibleSections; imbib permits everything
    /// (visibleSections = nil), so the sidebar's `shouldShowSection(.figures)`
    /// applies the pragmatic appID gate (`appID == "implore"`) on top —
    /// asserted here at the config level, noted in the capability matrix.
    func testFiguresSectionHiddenOutsideImplore() {
        XCTAssertFalse(AppShellConfiguration.imprint.permits(.figures))
        XCTAssertNotEqual(AppShellConfiguration.imbib.appID, "implore")
        XCTAssertNotEqual(AppShellConfiguration.imprint.appID, "implore")
        XCTAssertEqual(AppShellConfiguration.implore.appID, "implore")
    }

    /// Only imbib may boot the external-search credential path: the ADS/SciX
    /// keychain items are ACL'd to imbib's code signature, so any sibling
    /// shell that permits `.search` would stall its launch on a SecurityAgent
    /// password prompt (TabContentView gates the credential read on this).
    func testOnlyImbibPermitsSearchSection() {
        XCTAssertTrue(AppShellConfiguration.imbib.permits(.search))
        XCTAssertFalse(AppShellConfiguration.imprint.permits(.search))
        XCTAssertFalse(AppShellConfiguration.implore.permits(.search))
        XCTAssertFalse(AppShellConfiguration.impart.permits(.search))
        XCTAssertFalse(AppShellConfiguration.impel.permits(.search))
    }

    func testOpenBehaviorFallsBackToDescriptorDefault() {
        // A shell with no override uses the descriptor's default.
        let bare = AppShellConfiguration(
            appID: "test",
            visibleSections: nil,
            defaultSection: .inbox,
            defaultDetailTab: .info
        )
        XCTAssertEqual(bare.openBehavior(for: .manuscript), .appHandoff)
        XCTAssertEqual(bare.openBehavior(for: .publication), .detailPane)
        XCTAssertEqual(bare.openBehavior(for: RecordKindID("unknown")), .detailPane)
    }
}
#endif
