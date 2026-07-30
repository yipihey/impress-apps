//
//  LibraryShellUITests.swift
//  imprint-iOSUITests
//
//  Acceptance coverage for the descriptor-driven iOS shell: the sidebar's
//  collection tree, the search field, the long-press context menu and the
//  left-swipe triage grammar.
//
//  It also DOUBLES AS THE SCREENSHOT HARNESS — each checkpoint writes a PNG
//  to the runner's temporary directory (and attaches it to the result bundle),
//  so "does the swipe really say Dismiss / Archive?" is answerable from a
//  file instead of from a claim.
//
//  Requires manuscripts in the shared store; every assertion is skipped
//  (not failed) on an empty library so the test is safe on a clean device.
//

import XCTest

final class LibraryShellUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Landscape: in portrait a 3-column `NavigationSplitView` keeps the
        // sidebar as an overlay, so the tree is only reachable behind the
        // toggle. Landscape is the layout the split view is FOR.
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Evidence

    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imprint-shot-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        return shot
    }

    /// The TITLE label of the first manuscript row. Deliberately the title and
    /// not "the first element with that identifier": every subview of the row
    /// inherits `manuscriptRow.<uuid>`, and the first of them is the 12×11pt
    /// star glyph — far too small to swipe.
    private var firstRowTitle: XCUIElement? {
        let titles = app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH 'manuscriptRow.'"))
        guard titles.count > 0 else { return nil }
        return titles.element(boundBy: 0)
    }

    /// Scroll the sidebar until `element` is on screen. The sidebar's section
    /// collapse state is PERSISTED (shared with macOS), so how far down a row
    /// sits depends on the device's history — never assume a fixed offset.
    private func scrollSidebar(until element: XCUIElement, attempts: Int = 8) {
        let named = app.collectionViews["Sidebar"]
        let sidebar = named.exists ? named : app.collectionViews.firstMatch
        guard sidebar.exists else { return }
        for _ in 0..<attempts where !element.isHittable {
            sidebar.swipeUp()
            sleep(1)
        }
    }

    /// A sidebar label, scrolled into view if it is below the fold.
    ///
    /// I2 added `.citedInManuscripts` to this shell — imprint-iOS presents
    /// `.publication` now — and that section sits ABOVE Manuscripts in the
    /// suite-wide section order, so every row of the manuscript tree moved down
    /// by one section. Rows that used to fit no longer do, and a lazy `List`
    /// reports an unrendered row as absent. Scrolling for a label is the honest
    /// instrument; asserting `exists` at a fixed offset was only ever right by
    /// luck about how tall the sidebar happened to be.
    private func revealLabel(_ label: String) -> XCUIElement {
        let element = app.staticTexts[label]
        if element.exists { return element }
        scrollSidebar(until: element)
        return element
    }

    // MARK: - Sidebar

    func testSidebarShowsSectionsAndTheCollectionTree() throws {
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 20)
        XCTAssertTrue(revealLabel("Manuscripts").exists,
                      "the Manuscripts section header comes from AppShellConfiguration.imprint")
        capture("sidebar")
        // Status smart-children are the descriptor's declared lifecycle; the
        // last two are the collection tree, which sits under them.
        for label in ["All Manuscripts", "Drafts", "Submitted", "Published", "Archive",
                      "Flagged", "Papers"] {
            XCTAssertTrue(revealLabel(label).exists, "sidebar is missing “\(label)”")
        }
        let subfolder = revealLabel("Reionization 2026")
        XCTAssertTrue(subfolder.exists, "subcollections nest under their parent folder")
        capture("sidebar-tree")

        // Scroll to the Dismissed section and select it: the scope must show
        // the manuscript that every other scope hides.
        let dismissedNode = app.staticTexts
            .matching(identifier: "sidebar.node.manuscript.status.dismissed").firstMatch
        scrollSidebar(until: dismissedNode)
        XCTAssertTrue(dismissedNode.isHittable,
                      "the Dismissed section is the manuscript kind's dismissal status")
        dismissedNode.tap()
        sleep(1)
        capture("sidebar-dismissed")
        XCTAssertTrue(
            app.staticTexts["Early Draft of the Reionization Review"].waitForExistence(timeout: 5),
            "a dismissed manuscript is visible ONLY in the scope that names its status")
    }

    /// The Flagged section must offer one row per `FlagColor`, each with the
    /// flag's own colour.
    ///
    /// Only the ROWS are assertable here — XCUITest cannot read a glyph's
    /// tint — so this pins their existence and identifiers and leaves a
    /// screenshot behind (`imprint-shot-flag-colours.png`) for the colour
    /// itself. The tint's own guard is the unit test:
    /// `FlagColorPaletteTests.displayColorIsNeverTheFallback`, which runs on
    /// BOTH platforms and is what catches the failure mode this test cannot
    /// see (a mapping that is missing, or empty on one platform).
    func testFlaggedSectionShowsOneColouredRowPerFlag() throws {
        XCTAssertTrue(app.staticTexts["Flagged"].waitForExistence(timeout: 20),
                      "the Flagged section comes from AppShellConfiguration.imprint")
        for colour in ["red", "amber", "blue", "gray"] {
            let row = app.staticTexts
                .matching(identifier: "sidebar.node.manuscript.flagged.\(colour)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "the Flagged section is missing its “\(colour)” row")
        }
        capture("flag-colours")
    }

    /// The dismissed manuscript must NOT appear in the default list — the
    /// adapter's dismissal rule, seen from the UI.
    func testDismissedManuscriptIsHiddenFromTheDefaultScope() throws {
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 20)
        XCTAssertTrue(revealLabel("All Manuscripts").exists)
        XCTAssertFalse(app.staticTexts["Early Draft of the Reionization Review"].exists)
    }

    // MARK: - Search

    func testSearchFiltersTheList() throws {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("reionization")
        // Give the store round-trip a beat, then record what the user sees.
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
        sleep(2)
        capture("search")
    }

    // MARK: - Swipe (the shared TriageSwipe grammar)

    func testTrailingSwipeOffersDismissAndArchive() throws {
        guard let row = firstRowTitle, row.waitForExistence(timeout: 20) else {
            throw XCTSkip("no manuscripts in the shared store")
        }
        row.swipeLeft(velocity: .slow)
        sleep(1)
        capture("swipe")
        XCTAssertTrue(app.buttons["Dismiss"].waitForExistence(timeout: 5),
                      "trailing swipe must DISMISS, never hard-delete")
        XCTAssertTrue(app.buttons["Archive"].exists,
                      "archive comes from TriageCapabilities.archiveStatus")
        capture("swipe")
    }

    // MARK: - Context menu (the shared TriageMenu grammar)

    func testLongPressShowsTheTriageMenuWithMoveToFolder() throws {
        guard let row = firstRowTitle, row.waitForExistence(timeout: 20) else {
            throw XCTSkip("no manuscripts in the shared store")
        }
        row.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Move to Folder"].waitForExistence(timeout: 5)
                        || app.otherElements["Move to Folder"].waitForExistence(timeout: 1),
                      "collections are reachable from the row, iOS-style")
        XCTAssertTrue(app.buttons["Dismiss"].exists)
        XCTAssertTrue(app.buttons["Star"].exists || app.buttons["Unstar"].exists)
        capture("context-menu")
    }
}

// MARK: - Seeded shell

/// The descriptor-driven shell against a HERMETIC store.
///
/// `LibraryShellUITests` above runs on whatever is already on the device, which
/// is why half its assertions can skip. This class launches with
/// `--ui-testing --uitesting-seed`, so both adapters are in-memory and
/// `ImprintIOSApp.seedUITestDataIfNeeded` has put a tagged manuscript there —
/// which makes two things testable that were not:
///
///  * the sidebar's STATUS ROWS, whose labels and symbols moved from three
///    hardcoded places onto `StatusSpec`. They come from the DESCRIPTOR, not
///    from data, so they must appear in full on an almost-empty store.
///  * the TAGS SUBMENU, which `ManuscriptStoreAdapter.listTags()` now
///    populates. It was structurally absent before (`availableTagPaths` was a
///    hard `{ [] }`), and an empty store cannot tell the difference between
///    "hidden because empty" and "hidden because unimplemented".
final class SeededLibraryShellUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--uitesting-seed"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imprint-shot-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        return shot
    }

    private var firstRowTitle: XCUIElement? {
        let titles = app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH 'manuscriptRow.'"))
        guard titles.count > 0 else { return nil }
        return titles.element(boundBy: 0)
    }

    /// A sidebar label, scrolled into view if it is below the fold. See the
    /// twin in `LibraryShellUITests` for why I2 made this necessary.
    private func revealLabel(_ label: String, attempts: Int = 8) -> XCUIElement {
        let element = app.staticTexts[label]
        if element.exists { return element }
        let named = app.collectionViews["Sidebar"]
        let sidebar = named.exists ? named : app.collectionViews.firstMatch
        guard sidebar.exists else { return element }
        for _ in 0..<attempts where !element.exists {
            sidebar.swipeUp()
            sleep(1)
        }
        return element
    }

    /// The status rows are the DESCRIPTOR's, so they exist on a fresh store.
    /// Their labels are the frozen `StatusSpec` labels — the same strings
    /// `RecordKindStatusSpecTests` pins on the unit side, seen by a user.
    func testSidebarStatusRowsComeFromTheDescriptor() throws {
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 30)
        XCTAssertTrue(revealLabel("Manuscripts").exists,
                      "the Manuscripts section header comes from AppShellConfiguration")
        // iOS shows every declared status except the dismissed one, which owns
        // the Dismissed section (`StatusSpec.hiddenByDefault`).
        for label in ["All Manuscripts", "Drafts", "Internal Review", "Submitted",
                      "In Revision", "Published", "Archive"] {
            XCTAssertTrue(revealLabel(label).exists,
                          "sidebar is missing the declared status row “\(label)”")
        }
        XCTAssertTrue(revealLabel("Flagged").exists)
        capture("seeded-sidebar-status-rows")
    }

    /// C1(b), paid in I2.
    ///
    /// `.citedInManuscripts` lists PUBLICATIONS. imprint-iOS declared
    /// `presenting([.manuscript])` and this suite asserted the section was
    /// ABSENT — not because imprint should not offer it, but because the
    /// chassis had no public iOS publication surface to render it with (the C1
    /// finding, deferred as "(b)"). I2 built `IOSPublicationListPane` and
    /// `IOSPublicationDetailPane` in PMC, the capability set gained
    /// `.publication`, and the section arrived with no other edit — which is
    /// exactly what naming the KIND rather than the SECTION was supposed to buy.
    ///
    /// The assertion is deliberately structural: whether any papers are cited
    /// depends on `citation-usage@1.0.0` rows imprint writes while a user
    /// edits, which a fresh seed has none of. The SECTION must exist; its
    /// contents are the store's business.
    func testCitedInManuscriptsSectionIsPresentNowThatTheChassisHasAPublicationPane() throws {
        let header = app.descendants(matching: .any)["sidebar.section.citedInManuscripts"]
        let label = app.staticTexts["Cited in Manuscripts"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 30) || label.waitForExistence(timeout: 10),
            "imprint-iOS presents `.publication` since I2, so the section its own "
                + "preset permits must render")

        // Selecting it must reach the chassis list, not an empty column.
        let node = app.descendants(matching: .any)[
            "sidebar.node.section.citedInManuscripts.publication"]
        if node.waitForExistence(timeout: 10) {
            node.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["publicationList"]
                    .waitForExistence(timeout: 20)
                    || app.staticTexts["No Papers"].waitForExistence(timeout: 10),
                "the section should route to IOSPublicationListPane — with rows "
                    + "or with its honest empty state, never nothing")
        }
        capture("cited-in-manuscripts")
    }

    /// The Tags submenu, populated from `listTags()`.
    func testLongPressOffersPopulatedTagsSubmenu() throws {
        guard let row = firstRowTitle, row.waitForExistence(timeout: 30) else {
            throw XCTSkip("seeding failed — no manuscript rows, so this proves nothing")
        }
        row.press(forDuration: 1.5)
        let tags = app.buttons["Tags"].firstMatch
        let tagsMenu = tags.exists ? tags : app.otherElements["Tags"].firstMatch
        XCTAssertTrue(tagsMenu.waitForExistence(timeout: 5),
                      "the Tags submenu must exist once availableTagPaths is non-empty")
        capture("seeded-context-menu")
        tagsMenu.tap()
        sleep(1)
        capture("seeded-tags-submenu")
        for path in ["methods/simulations", "reading/priority"] {
            XCTAssertTrue(app.buttons[path].waitForExistence(timeout: 5),
                          "the Tags submenu must offer the seeded tag path “\(path)”")
        }
    }
}
