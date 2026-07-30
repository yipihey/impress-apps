//
//  IOSSidebarNavigationUITests.swift
//  imbib-iOSUITests
//
//  Every section of the migrated sidebar reaches ITS content pane.
//
//  The Stage 5a migration replaced imbib-iOS's hand-written sidebar with PMC's
//  shared `RecordSidebarView`, which means selection now travels
//  row → `RecordSidebarScope` → `ImbibSidebarBindings.section(for:)` →
//  `IOSContentView.contentList`. A section that renders but routes nowhere
//  looks fine in a screenshot, so each case here asserts on the CONTENT pane.
//
//  Screenshots are attached (always, not just on failure) so the run is
//  reviewable evidence of the sidebar's appearance as well as its routing.
//

import XCTest

final class IOSSidebarNavigationUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = IOSTestApp.launchSeeded()
    }

    /// Attach the current screen under `name`.
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Return to the sidebar.
    ///
    /// Three shapes, all of which this suite runs on:
    ///   * COMPACT (iPhone): a selection PUSHES, so the sidebar is behind the
    ///     navigation bar's back button;
    ///   * REGULAR, sidebar pinned: it never left;
    ///   * REGULAR, sidebar OVERLAID (iPad portrait with `.balanced`): making a
    ///     selection dismisses the overlay, and there is no back button — the
    ///     way back is the system `ToggleSidebar` toolbar item.
    private func returnToSidebar(_ sidebar: IOSSidebarPage) {
        // In REGULAR width the sidebar and the content pane are on screen
        // together, so a content pane that raises the keyboard (the search
        // forms auto-focus their query field) covers the sidebar's lower half —
        // its rows exist but are not hittable. Put it away first.
        // Only the explicit dismiss button — never "tap something else to
        // dismiss": `app.staticTexts.firstMatch` can resolve to a zero-size
        // element with an infinite frame, and XCUITest then fails the whole
        // test with `kAXErrorCannotComplete … kAXScrollToVisibleAction`. On a
        // phone there is no such button and none is needed: the back button
        // tears the whole pane down, keyboard included.
        if app.keyboards.count > 0 {
            let hide = app.keyboards.buttons["Hide keyboard"].firstMatch
            if hide.exists, hide.isHittable { hide.tap() }
        }
        if sidebar.sectionHeader("libraries").isHittable { return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable, !sidebar.settingsButton.isHittable {
            back.tap()
        }
        if !sidebar.sectionHeader("libraries").waitForExistence(timeout: 5)
            || !sidebar.sectionHeader("libraries").isHittable
        {
            let toggle = app.buttons["ToggleSidebar"].firstMatch
            if toggle.exists, toggle.isHittable { toggle.tap() }
        }
        _ = sidebar.sectionHeader("libraries").waitForExistence(timeout: 10)
    }

    func test_eachSectionReachesItsContentPane() {
        let sidebar = IOSSidebarPage(app: app)
        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        capture("01-sidebar-preset-sections")

        // ---- Collection tree, expanded (seeded expanded on first build).
        // Asserted FIRST, while the Libraries section is still on screen: the
        // navigation below scrolls the lazy sidebar down to Flagged/Search.
        let nested = sidebar.collectionRow(named: IOSSeed.nestedCollectionName)
        XCTAssertTrue(
            nested.waitForExistence(timeout: 10),
            "The nested collection should be visible — folder trees seed EXPANDED")
        capture("02-collection-tree-expanded")

        // ---- Inbox: the section HEADER is a destination (macOS parity), so
        // tapping the title selects the inbox library rather than only
        // collapsing the section.
        let inboxHeader = app.descendants(matching: .any)["sidebar.sectionSelect.inbox"].firstMatch
        XCTAssertTrue(inboxHeader.waitForExistence(timeout: 10), "Inbox header should be selectable")
        inboxHeader.tap()
        XCTAssertTrue(
            app.staticTexts["Inbox Empty"].waitForExistence(timeout: 10)
                || app.staticTexts["Inbox"].waitForExistence(timeout: 5),
            "Inbox selection should show the inbox content pane")
        capture("02-inbox-content")
        returnToSidebar(sidebar)

        // ---- Library
        XCTAssertTrue(
            sidebar.seededLibraryRow.waitForExistence(timeout: 10),
            "Seeded library row should render")
        sidebar.seededLibraryRow.tap()
        let list = IOSPublicationListPage(app: app)
        XCTAssertTrue(
            list.waitForFirstPublication(), "Library selection should list its publications")
        capture("03-library-content")
        returnToSidebar(sidebar)

        // ---- Search: the section's rows are the SEARCH FORMS, which the
        // `.opaque` role alone could never produce (it yields ONE row).
        let scixForm = sidebar.node("host.publication.form.ads-modern")
        XCTAssertTrue(scixForm.waitForExistence(timeout: 10), "SciX Search form row should render")
        capture("04-search-form-rows")
        scixForm.tap()
        XCTAssertTrue(
            app.textFields.firstMatch.waitForExistence(timeout: 15)
                || app.staticTexts["SciX Search"].waitForExistence(timeout: 5),
            "A search-form row should show its form")
        capture("05-search-form-content")
        returnToSidebar(sidebar)

        // ---- Flagged (red) — the seed flags exactly one paper red.
        sidebar.revealFlaggedSection()
        let redFlag = sidebar.flagRow("red")
        XCTAssertTrue(sidebar.scrollTo(redFlag), "Red flag row should render")
        capture("06-flagged-colour-rows")
        redFlag.tap()
        XCTAssertTrue(
            app.staticTexts
                .matching(
                    NSPredicate(
                        format: "label CONTAINS[c] %@", IOSSeed.unfiledPublicationTitleFragment))
                .firstMatch.waitForExistence(timeout: 15),
            "The red-flagged paper should appear in the Flagged content pane")
        capture("07-flagged-content")
    }
}
