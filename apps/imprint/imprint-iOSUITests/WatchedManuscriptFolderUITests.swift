//
//  WatchedManuscriptFolderUITests.swift
//  imprint-iOSUITests
//
//  ADR-0023 W3 — the live-edit proof, on the simulator.
//
//  ── What is real here, and the one thing that is not ────────────────────────
//
//  Real: the folder row is emitted through the chassis seam W1 built and W3
//  wired (`RecordSidebarSectionContent.additionalNodes` →
//  `RecordSidebarView`), rendered from a `WatchedFolderRowState` VERBATIM; the
//  folder was added by `WatchedFolderIngestCoordinator.addFolder(at:)` — the
//  same call the `fileImporter` makes; the manuscript row was written by
//  imprint's real `upsertExternalManuscript` through W0's hash-keyed
//  `import_discovered`; the provenance tag and the folder's list scope are the
//  shipping ones.
//
//  Not real: the folder-PICKING gesture, for the reason imbib's W2 suite
//  records — iOS's `.fileImporter` presents the system document browser, which
//  an XCUITest cannot drive, and a UI-test process has its own sandbox and
//  cannot create a directory the app may read. So the app mints the directory
//  under `--uitesting-watched-folder` and hands it to `addFolder(at:)`, which
//  is precisely where the picker's output goes.
//
//  The EDIT is likewise the app's, on a relaunch flag. What it proves is still
//  the thing worth proving, and for a file-unit kind it proves MORE than the
//  entry-unit version did: the file IS the record here, so "the file changed"
//  and "the manuscript changed" are one event, and the assertion is that the
//  row's body follows the file rather than the store's older copy winning.
//
//  Everything runs against the ONE scratch database `--ui-testing` selects for
//  every handle in the process (W3 moved `ManuscriptStoreAdapter` onto it —
//  attribution is a cross-handle claim). No user data is reachable.
//

import XCTest

final class WatchedManuscriptFolderUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // Landscape for the same reason `LibraryShellUITests` uses it: in
        // portrait the 3-column split view keeps the sidebar behind a toggle.
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: - Launch

    private func launch(edited: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--uitesting-watched-folder"]
        if edited { app.launchArguments.append("--uitesting-watched-folder-append") }
        app.launch()
        return app
    }

    @discardableResult
    private func capture(_ app: XCUIApplication, _ name: String) -> XCUIScreenshot {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("imprint-watched-\(name).png"))
        return shot
    }

    /// The watched-folder row, matched by the chassis scope-key prefix W1 fixed
    /// (`RecordSidebarScope.scopeKey` → `host.manuscript.watched-folder.<uuid>`).
    /// The uuid is minted at runtime, so the prefix is the anchor — and the
    /// `manuscript` in the middle is the assertion that this row belongs to
    /// imprint's kind and not imbib's.
    private func folderRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "sidebar.node.host.manuscript.watched-folder."))
            .firstMatch
    }

    /// Wait for the row, SCROLLING if the lazy `List` has not materialised it.
    ///
    /// Both, in that order, and the order matters for the same reason imbib's
    /// W2 suite records: the folder is registered asynchronously after launch,
    /// so a scroll that runs before it is registered scrolls past nothing and
    /// reports failure for a row that arrives a second later. The row is also
    /// genuinely below the fold — it comes after All + six declared statuses +
    /// the user's folders, which is exactly where W3 put it (a folder the user
    /// adds must never reshuffle the rows above it).
    private func awaitFolderRow(
        in app: XCUIApplication, timeout: TimeInterval = 90
    ) -> XCUIElement {
        let row = folderRow(in: app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.exists { break }
            _ = row.waitForExistence(timeout: 3)
            if !row.exists { scrollSidebar(app) }
        }
        return row
    }

    private func scrollSidebar(_ app: XCUIApplication) {
        let scroller = app.collectionViews.firstMatch.exists
            ? app.collectionViews.firstMatch
            : app.tables.firstMatch
        if scroller.exists {
            scroller.swipeUp()
        } else {
            app.swipeUp()
        }
    }

    /// The external manuscript's row in the list. Its title is the FILE's name
    /// without the extension — an external manuscript takes its title from the
    /// file, because the file is what it indexes.
    private func manuscriptRow(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "Reionization Notes"))
            .firstMatch
    }

    // MARK: - Tests

    /// The row appears, states its D6 condition verbatim, and the `.md` file in
    /// the folder is listed as a manuscript.
    func test_watchedManuscriptFolder_rowAppearsAndTheFileIsListed() {
        let app = launch()

        let row = awaitFolderRow(in: app)
        XCTAssertTrue(row.exists, "the watched folder must have a sidebar row under Manuscripts")
        capture(app, "folder-row")

        // D6, rendered rather than paraphrased. iOS declares no live engine
        // (`FolderWatchAvailability.livePlatforms == [.macOS]`), so the honest
        // state is `scanOnDemand` — and therefore deliberately NO badge, since
        // `scanOnDemand.countIsTrustworthy` is false and a number that might be
        // stale must not be shown as a total.
        XCTAssertTrue(
            row.label.contains("Scan on demand"),
            "the row must show its state verbatim; got \(row.label)")

        row.tap()
        capture(app, "folder-list")

        XCTAssertTrue(
            manuscriptRow(in: app).waitForExistence(timeout: 45),
            "the .md file in the watched folder must be listed as a manuscript")
    }

    /// Selecting the external manuscript opens the REFERENCE pane, not an
    /// editor — the D4 no-write-back invariant, as the user meets it.
    func test_externalManuscript_opensReadOnlyWithBothAffordances() {
        let app = launch()
        let row = awaitFolderRow(in: app)
        XCTAssertTrue(row.exists)
        row.tap()

        let manuscript = manuscriptRow(in: app)
        XCTAssertTrue(manuscript.waitForExistence(timeout: 45))
        manuscript.tap()

        // D4's two affordances ARE the pane's signature — a container's
        // identifier is a rendering detail, these are the contract. Asserting
        // on them also proves the negative the test is really about: an EDITOR
        // has neither of these buttons.
        let importCopy = app.buttons["external-manuscript.import-copy"]
        XCTAssertTrue(
            importCopy.waitForExistence(timeout: 30),
            "an external manuscript must open the reference pane, never an editor")
        capture(app, "external-pane")
        XCTAssertTrue(
            app.buttons["external-manuscript.open-in-place"].exists,
            "the explicit handoff must be offered")
        // The pane must SAY which file it indexes. Matched by content rather
        // than by identifier: the path is `.textSelection(.enabled)`, which on
        // iOS 26 promotes the label out of `staticTexts`.
        XCTAssertTrue(
            app.descendants(matching: .any).containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Reionization Notes.md")
            ).firstMatch.waitForExistence(timeout: 10),
            "the pane must name the file it indexes")

        // And the body the file contained, read-only.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "neutral fraction")
            ).firstMatch.waitForExistence(timeout: 20),
            "the snapshot of the file's text must be shown")
    }

    /// The live-edit: the FILE's text changes on disk, and the manuscript row
    /// follows it. This is the hash-changed path (`import_discovered` →
    /// `changed` → imprint's fan-out re-reads and REPLACES the snapshot).
    func test_watchedManuscript_bodyFollowsAnExternalEditOfTheFile() {
        // Pass 1 — the original text.
        let first = launch()
        let firstRow = awaitFolderRow(in: first)
        XCTAssertTrue(firstRow.exists, "the folder row must exist before the file changes")
        firstRow.tap()
        let firstManuscript = manuscriptRow(in: first)
        XCTAssertTrue(firstManuscript.waitForExistence(timeout: 45))
        firstManuscript.tap()
        XCTAssertTrue(
            first.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "neutral fraction")
            ).firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(
            first.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Damping wings")
            ).firstMatch.waitForExistence(timeout: 5),
            "the second paragraph is not in the file yet")
        capture(first, "live-edit-before")
        first.terminate()

        // Pass 2 — the SAME path, different bytes. The bookmark is restored
        // from `UserDefaults`, the folder row is re-registered, and the re-scan
        // has to notice a file whose content hash moved. Nothing is imported
        // twice: the manuscript's id is derived from the path, so this is an
        // update of one row rather than a second row.
        let second = launch(edited: true)
        let secondRow = awaitFolderRow(in: second)
        XCTAssertTrue(
            secondRow.exists, "the folder must come back from its persisted bookmark")
        secondRow.tap()

        let secondManuscript = manuscriptRow(in: second)
        XCTAssertTrue(secondManuscript.waitForExistence(timeout: 45))

        // ONE row, not two — the path is the identity.
        XCTAssertEqual(
            second.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Reionization Notes")
            ).count,
            1,
            "an edited file must update its manuscript, not mint a second one")

        secondManuscript.tap()
        XCTAssertTrue(
            second.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Damping wings")
            ).firstMatch.waitForExistence(timeout: 45),
            "the text added to the watched file must reach the manuscript row without an import")
        capture(second, "live-edit-after")
    }
}
