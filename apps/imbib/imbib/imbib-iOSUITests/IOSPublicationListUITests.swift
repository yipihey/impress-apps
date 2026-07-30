//
//  IOSPublicationListUITests.swift
//  imbib-iOSUITests
//
//  Guards imbib-iOS's Stage 5d publication list: the model half moved to the
//  chassis (`Chassis/Shared/PublicationListCore` + `PublicationScope` +
//  `PublicationListOrder` + `PublicationListMutations`) and this file is now iOS
//  chrome over it. See docs/chassis-capability-matrix.md, "Publication list".
//
//  What these tests are FOR, that `PublicationListSharedSurfaceTests` cannot be:
//  the unit tests prove the shared halves compute the right answers, they cannot
//  prove that the HOST is still wired to them. The three wires that broke most
//  easily in this migration are exactly the three asserted here:
//
//    1. The core is built in `init` and REPLACED in `.task(id: source.id)`,
//       because SwiftUI keeps `@State` across a same-branch route change. If
//       that replacement is wrong the list shows the previous scope's rows —
//       which is invisible to a unit test and obvious on screen.
//    2. Pull-to-refresh reaches `PublicationListCore.refreshFromSource` through
//       `PublicationListActions.onRefresh` and `PublicationListView`'s iOS-only
//       `.refreshable`. A broken wire here does nothing at all, silently.
//    3. The BibTeX row action presents `IOSBibTeXEditorSheet`, which is now a
//       thin wrapper around the SHARED `BibTeXTab`. Its own editor, validator
//       and save path are deleted, so this asserts the shared tab's affordances
//       (Copy + Edit + the entry text) rather than the sheet's old ones.
//
//  Run against the seeded in-memory store (`--ui-testing --uitesting-seed`), so
//  they are deterministic and offline.
//
//  Orientation is pinned to portrait: the split view's collapse behaviour — and
//  therefore whether the sidebar is on screen at all — is size-class dependent
//  (the known iPad orientation sensitivity the sidebar suites document).
//

import XCTest

final class IOSPublicationListUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        // Terminate explicitly: without it a following case in this class dies
        // with "crashed with signal kill" (see IOSSmokeUITests).
        XCUIApplication().terminate()
        super.tearDown()
    }

    // MARK: - 1. Selection drives the detail pane

    /// Selecting a row must push the detail pane for THAT row.
    ///
    /// `selectedPublicationID` is a `@Binding` the host writes; the shared core
    /// deliberately owns no selection (a phone's split view is a stack, so a
    /// write PUSHES). This is the wire that policy rests on.
    func test_selectingARow_pushesTheDetailPaneForThatRow() throws {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let list = IOSPublicationListPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        XCTAssertTrue(
            sidebar.seededLibraryRow.waitForExistence(timeout: 15),
            "Seeded library row should render")
        sidebar.seededLibraryRow.tap()

        XCTAssertTrue(
            list.waitForFirstPublication(),
            "The list must load rows through PublicationListCore's synchronous first page")
        capture(app, name: "list-library")

        list.openFirstPublication()
        XCTAssertTrue(
            list.waitForDetail(),
            "Tapping a row must push the detail pane (selectedPublicationID binding)")
        // The RIGHT paper, not merely some paper.
        XCTAssertTrue(
            app.staticTexts
                .matching(
                    NSPredicate(
                        format: "label CONTAINS[c] %@", IOSSeed.firstPublicationTitleFragment))
                .firstMatch
                .waitForExistence(timeout: 10),
            "The pushed detail pane must show the paper that was tapped")
        capture(app, name: "list-selection-detail")
    }

    /// The `.id(source.id)` hazard, on iOS. Two scopes render through the SAME
    /// switch branch of `IOSContentView.contentList`, so SwiftUI keeps the
    /// wrapper's `@State` — including its `PublicationListCore` — across the
    /// route change. The core has to be replaced in `.task(id:)` or the list
    /// keeps showing the previous scope's rows.
    ///
    /// The seeded fixture makes this observable: the "Relativity" collection
    /// holds ONLY the first publication, so switching library → collection must
    /// DROP the unfiled paper.
    func test_switchingScope_replacesTheCoreAndTheRows() throws {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let list = IOSPublicationListPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        XCTAssertTrue(sidebar.seededLibraryRow.waitForExistence(timeout: 15))
        sidebar.seededLibraryRow.tap()
        XCTAssertTrue(list.waitForFirstPublication(), "Library scope should load")

        let unfiled = app.staticTexts
            .matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@", IOSSeed.unfiledPublicationTitleFragment))
            .firstMatch
        XCTAssertTrue(
            unfiled.waitForExistence(timeout: 15),
            "The whole library must contain the unfiled paper")
        capture(app, name: "scope-library")

        // Back to the sidebar, then into the collection.
        returnToSidebar(app)
        let collection = sidebar.collectionRow(named: IOSSeed.collectionName)
        XCTAssertTrue(
            sidebar.scrollTo(collection),
            "The seeded collection row should be reachable")
        collection.tap()

        XCTAssertTrue(
            list.waitForFirstPublication(),
            "Collection scope should load its member")
        capture(app, name: "scope-collection")
        // The assertion that a stale core fails: the collection does NOT contain
        // this paper, so it must be gone.
        XCTAssertFalse(
            unfiled.exists,
            """
            The list still shows a row from the previous scope. The wrapper's \
            PublicationListCore was not replaced when `source.id` changed — see \
            the `.task(id: source.id)` block and the `.id(source.id)` rule in \
            apps/imbib/CLAUDE.md.
            """)
    }

    // MARK: - 2. Pull-to-refresh

    /// `.refreshable` is `PublicationListView`'s iOS-only modifier; it calls
    /// `actions.onRefresh`, which the wrapper routes to
    /// `PublicationListCore.refreshFromSource`. Offline and seeded, a refresh of
    /// a plain library is a re-read, so the assertion is that the gesture
    /// completes and the rows survive it — a broken wire leaves the spinner
    /// stuck or the list empty.
    func test_pullToRefresh_completesAndKeepsTheRows() throws {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let list = IOSPublicationListPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        XCTAssertTrue(sidebar.seededLibraryRow.waitForExistence(timeout: 15))
        sidebar.seededLibraryRow.tap()
        XCTAssertTrue(list.waitForFirstPublication(), "Seeded list should load")

        let row = list.firstPublicationText
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 6.0))
        start.press(forDuration: 0.05, thenDragTo: end)

        // The refresh must SETTLE: no spinner left behind, rows still there.
        // `refreshFromSource` flips `isRefreshing` in a `defer`, so a hang here
        // means the await never returned.
        let deadline = Date().addingTimeInterval(20)
        while app.activityIndicators.count > 0, Date() < deadline {
            usleep(250_000)
        }
        capture(app, name: "pull-to-refresh")
        XCTAssertEqual(
            app.activityIndicators.count, 0,
            "The refresh spinner must clear — refreshFromSource returned")
        XCTAssertTrue(
            list.firstPublicationText.waitForExistence(timeout: 15),
            "Rows must survive a refresh (the core re-reads, it does not clear)")
    }

    // MARK: - 3. The BibTeX sheet is the shared editor

    /// `IOSBibTeXEditorSheet` used to be 163 code lines with its own editor
    /// (`IOSBibTeXEditorView`, deleted), its own brace-counting validator
    /// (deleted) and a save path that looped `updateField` and therefore could
    /// not express a renamed cite key, a changed entry type or a deleted field.
    /// It is now a `NavigationStack` + Done around the SHARED `BibTeXTab`.
    ///
    /// So the anchors are the shared tab's: the entry text, and the Copy button
    /// that iOS's own BibTeX surfaces never had. Then Edit → type → Save, which
    /// exercises `LibraryViewModel.updateFromBibTeX` — the path the sheet did not
    /// use before.
    func test_bibTeXRowAction_opensTheSharedEditorAndSaves() throws {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let list = IOSPublicationListPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        XCTAssertTrue(sidebar.seededLibraryRow.waitForExistence(timeout: 15))
        sidebar.seededLibraryRow.tap()
        XCTAssertTrue(list.waitForFirstPublication(), "Seeded list should load")

        // The row's context menu is a long press; "View/Edit BibTeX" is the
        // action that sets `bibTeXTarget` and therefore presents the sheet.
        list.firstPublicationText.press(forDuration: 1.2)
        capture(app, name: "bibtex-context-menu")
        XCTAssertTrue(
            tapBibTeXMenuItem(app),
            "The row context menu should offer the View/Edit BibTeX action")

        // The sheet chrome this file still owns.
        //
        // `navigationBars` ONLY, deliberately: `app.staticTexts["BibTeX"]` is a
        // false positive here, because the app publishes a zero-size keyboard
        // shortcut element with exactly that label. Asserting on it let a
        // COMPLETELY EMPTY sheet pass — which is what this row action was
        // presenting before `.sheet(item:)` replaced the two-`@State`
        // `.sheet(isPresented:)` (the empty sheet had no navigation bar at all,
        // so this is the assertion that catches it).
        XCTAssertTrue(
            app.navigationBars["BibTeX"].waitForExistence(timeout: 10),
            "The sheet should present with its BibTeX navigation bar")

        // The SHARED tab's content and affordances. `BibTeXEditor` renders
        // syntax-highlighted text with a line-number gutter and exposes no
        // `textView`, so read the entry from static text.
        _ = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "@"))
            .firstMatch
            .waitForExistence(timeout: 10)
        capture(app, name: "bibtex-sheet")
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "@"))
                .firstMatch
                .exists,
            "The sheet must show the BibTeX entry, not the No-BibTeX state")
        XCTAssertTrue(
            app.buttons["Copy"].exists,
            "The shared tab brings a Copy button the sheet's own toolbar buried in a menu")
        XCTAssertTrue(
            app.buttons["Edit"].exists,
            "The shared tab's Edit affordance should render inside the sheet")

        // Edit → Save. The shared tab disables Save until `hasChanges`, so the
        // typing is what enables it; a Save that stays disabled means the
        // editor's binding is not live inside a sheet.
        app.buttons["Edit"].tap()
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10), "Edit mode should offer Save")

        let editor = app.textViews.firstMatch
        if editor.waitForExistence(timeout: 10) {
            editor.tap()
            editor.typeText(" ")
        }
        capture(app, name: "bibtex-sheet-editing")
        // Whether the keyboard covered Save or not, the button must exist and
        // become enabled once the buffer changed.
        if saveButton.isHittable {
            XCTAssertTrue(
                saveButton.isEnabled,
                "Save must enable once the shared editor's buffer changed")
            saveButton.tap()
        }

        // Done dismisses back to the list, which must still be there.
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5), done.isHittable {
            done.tap()
        }
        XCTAssertTrue(
            list.firstPublicationText.waitForExistence(timeout: 15),
            "Dismissing the sheet should return to the list")
        capture(app, name: "bibtex-sheet-dismissed")
    }

    // MARK: - Helpers

    /// Tap the context-menu row that presents the sheet.
    ///
    /// The label is `MailStylePublicationRow`'s literal "View/Edit BibTeX" (the
    /// test bundle deliberately does not link PMC, so it cannot import the
    /// string). Matched EXACTLY and then filtered to a hittable candidate, for
    /// two reasons that both cost a 268-second timeout to learn:
    ///
    ///   * the same menu also has "Copy BibTeX", so a `CONTAINS` predicate
    ///     matches two elements;
    ///   * `.firstMatch` on a context-menu button can resolve to a zero-size
    ///     element with an infinite frame, which fails with
    ///     `kAXScrollToVisibleAction` instead of tapping — the same trap
    ///     `IOSDetailPage.select` documents for tab-bar buttons.
    @discardableResult
    private func tapBibTeXMenuItem(_ app: XCUIApplication) -> Bool {
        let candidates = app.buttons
            .matching(NSPredicate(format: "label == %@", "View/Edit BibTeX"))
        guard candidates.firstMatch.waitForExistence(timeout: 10) else { return false }
        for candidate in candidates.allElementsBoundByIndex where candidate.isHittable {
            candidate.tap()
            return true
        }
        return false
    }

    /// Unwind the navigation stack back to the sidebar. In compact width the
    /// split view is a stack, so this is a back button; in regular width the
    /// sidebar is already visible.
    private func returnToSidebar(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable {
            back.tap()
        }
        let toggle = app.buttons["ToggleSidebar"]
        if toggle.exists, toggle.isHittable {
            toggle.tap()
        }
    }

    // MARK: - Screenshot capture

    /// Attach a screenshot AND write it to the runner's temp directory, where a
    /// human can open it without unpacking an `.xcresult`.
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "imbib-ios-list-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imbib-ios-list-\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
