//
//  IOSWatchedFolderUITests.swift
//  imbib-iOSUITests
//
//  ADR-0023 W2 — the live-drop proof, on the simulator.
//
//  ── What is real here, and the one thing that is not ────────────────────────
//
//  Real: the watched-folder row is emitted by `ImbibSidebarBindings`
//  through W1's `RecordSidebarSectionContent` seam, rendered by the chassis's
//  `RecordSidebarView` from a `WatchedFolderRowState` VERBATIM; the folder was
//  added by `WatchedFolderIngestCoordinator.addFolder(at:)` — the same call the
//  `fileImporter` makes; the entries were parsed and deduped by imbib's real
//  Rust importer; the provenance rows were written by the real store verbs.
//
//  Not real: the folder-PICKING gesture. iOS's `.fileImporter` presents the
//  system document browser, which an XCUITest cannot drive, and — the harder
//  constraint — a UI-test process has its own sandbox, so it cannot create a
//  directory the app is allowed to read. The app therefore mints the directory
//  itself under `--uitesting-watched-folder` and hands it to `addFolder(at:)`,
//  which is precisely where the picker's output goes. Everything downstream is
//  the shipping code path.
//
//  The same constraint shapes the live-update half: the file is EDITED by the
//  app on a relaunch flag rather than by this process. What that proves is
//  still the thing worth proving — imbib re-reads a `.bib` whose bytes moved,
//  through the hash-keyed re-scan, and the new entry arrives — but the write
//  itself is the harness's, and this comment is here so nobody later mistakes
//  it for an FSEvents assertion. The FSEvents path is covered where it can be
//  covered honestly: `FSEventsDirectoryWatcherTests` (real stream, unskipped)
//  and `WatchedFolderIngestCoordinatorTests` (the full loop, macOS).
//
//  Everything runs against the in-memory store `--ui-testing` selects — for
//  BOTH handles, `RustStoreAdapter` and `WatchedFolderStoreAdapter`. No user
//  data is reachable.
//

import XCTest

final class IOSWatchedFolderUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Launch

    private func launch(appendingEntry: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--uitesting-seed", "--uitesting-watched-folder",
        ]
        if appendingEntry { app.launchArguments.append("--uitesting-watched-folder-append") }
        app.launch()
        IOSTestApp.dismissPendingSystemAlert()
        return app
    }

    /// The watched-folder row, matched by the chassis scope-key prefix W1 fixed
    /// (`RecordSidebarScope.scopeKey` → `host.publication.watched-folder.<uuid>`).
    /// The uuid is minted at runtime, so the prefix is the anchor.
    private func watchedRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "sidebar.node.host.publication.watched-folder."))
            .firstMatch
    }

    /// Wait for the row, scrolling if the lazy `List` has not materialised it.
    ///
    /// Both, in that order: the folder is registered asynchronously after
    /// launch, so a scroll that runs before it is registered scrolls past
    /// nothing and reports failure for a row that arrives a second later.
    @discardableResult
    private func awaitWatchedRow(
        in app: XCUIApplication, sidebar: IOSSidebarPage, timeout: TimeInterval = 45
    ) -> XCUIElement {
        let row = watchedRow(in: app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.exists { break }
            _ = row.waitForExistence(timeout: 3)
            if !row.exists { _ = sidebar.scrollTo(sidebar.sectionHeader("libraries")) }
        }
        return row
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Tests

    /// The row appears, says what state it is in VERBATIM, and the entries the
    /// watched `.bib` contained are in the library.
    func test_watchedFolder_rowAppearsAndItsEntriesLand() {
        let app = launch()
        let sidebar = IOSSidebarPage(app: app)
        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")

        XCTAssertTrue(
            sidebar.sectionHeader("libraries").waitForExistence(timeout: 15),
            "watched folders are emitted under Libraries")

        let row = awaitWatchedRow(in: app, sidebar: sidebar)
        XCTAssertTrue(row.exists, "the watched folder must have a sidebar row")
        attachScreenshot(app, named: "watched-folder-row")

        // D6, rendered rather than paraphrased. iOS declares no live engine
        // (`FolderWatchAvailability.livePlatforms == [.macOS]`), so the honest
        // state is `scanOnDemand` and `WatchedFolderRowState` puts a degraded
        // state in the title — which is also why there is deliberately NO
        // badge: `scanOnDemand.countIsTrustworthy` is false, and a number that
        // might be stale must not be shown as a total.
        XCTAssertTrue(
            row.label.contains("Scan on demand"),
            "the row must show the state verbatim; got \(row.label)")

        // The entries landed. Two in the seeded file, and the seed library's
        // own two papers are unrelated to them.
        row.tap()
        attachScreenshot(app, named: "watched-folder-list")
        for title in ["Recherches sur les substances", "Invariante Variationsprobleme"] {
            XCTAssertTrue(
                app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS[c] %@", title)
                ).firstMatch.waitForExistence(timeout: 20),
                "'\(title)' came from the watched .bib and must be in the list")
        }
    }

    /// The live-drop: the file gains an entry, and the entry arrives.
    ///
    /// Generous timeouts throughout — the first pass runs a real BibTeX parse
    /// and a real whole-library dedup, on a simulator, behind a relaunch.
    func test_watchedFolder_liveUpdateAfterTheFileChanges() {
        // Pass 1: two entries, watched, imported.
        let first = launch()
        let firstSidebar = IOSSidebarPage(app: first)
        XCTAssertTrue(firstSidebar.waitUntilLoaded())
        let firstRow = awaitWatchedRow(in: first, sidebar: firstSidebar)
        XCTAssertTrue(
            firstRow.exists, "the watched folder row must exist before the file changes")
        firstRow.tap()
        XCTAssertFalse(
            first.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Analytical Engine")
            ).firstMatch.waitForExistence(timeout: 5),
            "the third entry is not in the file yet")
        attachScreenshot(first, named: "live-drop-before")
        first.terminate()

        // Pass 2: the SAME directory, one entry longer. The bookmark is
        // restored from `UserDefaults`, the folder row is re-registered, and
        // the re-scan has to notice a file whose content hash moved.
        let second = launch(appendingEntry: true)
        let secondSidebar = IOSSidebarPage(app: second)
        XCTAssertTrue(secondSidebar.waitUntilLoaded())
        let secondRow = awaitWatchedRow(in: second, sidebar: secondSidebar)
        XCTAssertTrue(
            secondRow.exists, "the folder must come back from its persisted bookmark")
        secondRow.tap()

        XCTAssertTrue(
            second.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Analytical Engine")
            ).firstMatch.waitForExistence(timeout: 45),
            "the entry added to the watched .bib must arrive without a manual import")
        attachScreenshot(second, named: "live-drop-after")

        // And the two originals are still there, once each — the re-import
        // deduped them rather than doubling them.
        for title in ["Recherches sur les substances", "Invariante Variationsprobleme"] {
            let matches = second.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", title))
            XCTAssertEqual(
                matches.count, 1,
                "'\(title)' must survive the re-import exactly once, not twice")
        }
    }
}
