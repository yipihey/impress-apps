//
//  IOSSidebarUITests.swift
//  imbib-iOSUITests
//
//  Guards imbib-iOS's Stage 5a sidebar: PMC's shared `RecordSidebarView`
//  driven by `AppShellConfiguration.imbib` (see imbib-iOS/Views/
//  ImbibSidebarBindings.swift), which replaced a hand-written 15-arm section
//  switch that read no preset at all.
//
//  The point of these two tests is the thing the old sidebar could not be
//  tested for: that the SECTION LIST is the preset's, not a literal — so a
//  section imbib does not permit (or this host cannot render) is asserted
//  ABSENT, and a selection lands in the existing content routing.
//
//  Run against the seeded in-memory store (`--ui-testing --uitesting-seed`),
//  so they are deterministic and offline. Orientation is pinned: the split
//  view's collapse behaviour — and therefore whether the sidebar is on screen
//  at all — is size-class dependent (known iPad orientation sensitivity).
//

import XCTest

final class IOSSidebarUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// The section list is the `.imbib` preset's, gated by what THIS host can
    /// present and what the store actually holds — never a hardcoded list.
    ///
    /// Present with the seed: Inbox, Libraries, Search, Flagged.
    /// Absent, each for a DIFFERENT declared reason:
    ///   * `artifacts` — `presenting([.publication])`: no artifact surface here;
    ///   * `sharedWithMe` — no shared-library list on either platform yet;
    ///   * `scixLibraries` — no ADS credential in a UI-test run;
    ///   * `exploration` / `citedInManuscripts` / `dismissed` — empty;
    ///   * `reviewQueue` — this build has no review pane;
    ///   * `manuscripts` / `figures` / `mail` / `agents` — not in imbib's
    ///     `visibleSections` (the publications-only purification).
    func test_sidebar_sectionsComeFromTheImbibPreset() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")

        for section in ["inbox", "libraries", "search"] {
            XCTAssertTrue(
                sidebar.sectionHeader(section).waitForExistence(timeout: 10),
                "`\(section)` is in AppShellConfiguration.imbib and must render")
        }
        // Flagged is below the fold of a lazy List (the nine Search rows sit
        // above it), so it is scrolled to. Its ROWS are the subject of
        // `IOSSidebarNavigationUITests`; here it only has to exist.
        XCTAssertTrue(
            sidebar.scrollTo(sidebar.sectionHeader("flagged")),
            "`flagged` is in AppShellConfiguration.imbib and must render")

        for section in [
            "artifacts", "sharedWithMe", "scixLibraries", "exploration",
            "citedInManuscripts", "reviewQueue", "dismissed",
            "journal", "figures", "mail", "agents",
        ] {
            XCTAssertFalse(
                sidebar.sectionHeader(section).exists,
                "`\(section)` is gated off for this host/store and must not render")
        }

        // Flag rows are declaration-derived (`FlagColor.allCases`), so their
        // scope keys are stable — the one place the sidebar's rows can be
        // asserted EXACTLY rather than by prefix.
        // `FlagColor.allCases` raw values (ImpressFTUI): red / amber / blue /
        // gray — NOT the display names, and not "orange"/"grey".
        for color in ["red", "amber", "blue", "gray"] {
            XCTAssertTrue(
                sidebar.scrollTo(sidebar.node("publication.flagged.\(color)")),
                "Flagged section should offer a \(color) row")
        }
    }

    /// Selecting a collection in the sidebar updates the publication list —
    /// i.e. `RecordSidebarScope.folder` reaches `IOSContentView.contentList`
    /// through `ImbibSidebarBindings.section(for:)` and nothing else.
    ///
    /// The seeded tree is Test Library › Relativity (1 paper) › Special, and
    /// only the Einstein paper is filed in Relativity — so a passing test also
    /// proves the list is SCOPED and not just showing the whole library.
    func test_selectCollection_updatesPublicationList() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let list = IOSPublicationListPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")

        // Folder trees are seeded EXPANDED on first build, so the collection is
        // on screen without a disclosure tap.
        let collection = sidebar.collectionRow(named: IOSSeed.collectionName)
        XCTAssertTrue(
            collection.waitForExistence(timeout: 15),
            "Seeded collection '\(IOSSeed.collectionName)' should render under its library")
        collection.tap()

        XCTAssertTrue(
            list.waitForFirstPublication(),
            "The collection's one member should appear in the list")
        XCTAssertFalse(
            app.staticTexts
                .matching(
                    NSPredicate(
                        format: "label CONTAINS[c] %@", IOSSeed.unfiledPublicationTitleFragment)
                )
                .firstMatch.exists,
            "A paper that is NOT in the collection must not appear — the list is scoped")
    }
}
