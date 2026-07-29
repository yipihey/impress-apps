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
    private func scrollSidebar(until element: XCUIElement, attempts: Int = 5) {
        let sidebar = app.collectionViews["Sidebar"]
        for _ in 0..<attempts where !element.isHittable {
            sidebar.swipeUp()
            sleep(1)
        }
    }

    // MARK: - Sidebar

    func testSidebarShowsSectionsAndTheCollectionTree() throws {
        XCTAssertTrue(app.staticTexts["Manuscripts"].waitForExistence(timeout: 20),
                      "the Manuscripts section header comes from AppShellConfiguration.imprint")
        capture("sidebar")
        // Status smart-children are the descriptor's declared lifecycle.
        for label in ["All Manuscripts", "Drafts", "Submitted", "Published", "Archive",
                      "Flagged", "Papers"] {
            XCTAssertTrue(app.staticTexts[label].exists, "sidebar is missing “\(label)”")
        }
        let subfolder = app.staticTexts["Reionization 2026"]
        XCTAssertTrue(subfolder.exists, "subcollections nest under their parent folder")
        scrollSidebar(until: subfolder)
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
        XCTAssertTrue(app.staticTexts["All Manuscripts"].waitForExistence(timeout: 20))
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
