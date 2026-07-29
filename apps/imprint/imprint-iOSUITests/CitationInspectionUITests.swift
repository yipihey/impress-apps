//
//  CitationInspectionUITests.swift
//  imprint-iOSUITests
//
//  imprint's citation-inspection affordance on iOS: long-press a `@citeKey` in
//  the source editor and the cited paper appears.
//
//  Unlike `LibraryShellUITests`, this suite is HERMETIC. It launches with
//  `--ui-testing --uitesting-seed`, which puts both store adapters on in-memory
//  databases and seeds a manuscript that cites one paper that exists
//  (`@Einstein1905`) and one that does not (`@Missing2099`) — so the assertions
//  do not depend on what happens to be on the developer's simulator.
//
//  Both trigger paths are covered, because both are shipped:
//    - the gesture (long press at the citation's coordinate);
//    - the programmatic entry point (`imprint://inspect/citation/{key}`), which
//      is how an agent drives this on a device that runs no HTTP server.
//

import XCTest

final class CitationInspectionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--uitesting-seed"]
        app.launch()
    }

    // MARK: - Helpers

    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot
    }

    /// Open the seeded manuscript and return its source editor.
    private func openSeededManuscript() throws -> XCUIElement {
        let row = app.staticTexts["Citation Long Press Fixture"]
        guard row.waitForExistence(timeout: 30) else {
            capture("library-without-fixture")
            throw XCTSkip("seeded manuscript did not appear — seeding failed, not the feature")
        }
        row.tap()

        // Which pane is showing is an `@AppStorage` preference that SURVIVES
        // relaunch, so a run whose predecessor left the editor on Preview opens
        // on Preview. Select Source explicitly rather than assume.
        let sourceTab = app.segmentedControls["editor.panePicker"].buttons["Source"]
        if sourceTab.waitForExistence(timeout: 20), !sourceTab.isSelected {
            sourceTab.tap()
        }

        let editor = app.textViews["editor.sourceTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "the source editor must open")
        return editor
    }

    /// A point inside the first line's `@Einstein1905` token.
    ///
    /// The editor's `textContainerInset` is 16pt and its face is a 16pt
    /// monospaced system font (~9.6pt per character), so the 13-character token
    /// spans roughly x ∈ [16, 141] on the first line. 70pt in is comfortably
    /// mid-token, and 26pt down is the middle of the first line.
    private func firstLineCitation(in editor: XCUIElement) -> XCUICoordinate {
        editor
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 70, dy: 26))
    }

    // MARK: - The gesture

    func testLongPressOnACitationShowsTheCitedPaper() throws {
        let editor = try openSeededManuscript()
        capture("editor-before-long-press")

        firstLineCitation(in: editor).press(forDuration: 1.0)

        let sheet = app.otherElements["citationPaper.sheet.resolved"]
        let title = app.staticTexts["citationPaper.title"]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 10) || title.waitForExistence(timeout: 5),
            "long-pressing @Einstein1905 must raise the resolved paper sheet")
        capture("citation-paper-sheet-resolved")

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'Elektrodynamik'")
            ).firstMatch.exists,
            "the sheet must show the paper's title, not just the cite key")
        XCTAssertTrue(
            app.buttons["citationPaper.openInImbib"].exists,
            "the macOS panel's 'open in imbib' exit must be here too")
    }

    func testLongPressOnOrdinaryProseDoesNotRaiseTheSheet() throws {
        let editor = try openSeededManuscript()

        // Far to the right of the first line's citation — ordinary words. The
        // recognizer must decline the touch entirely so text selection still
        // works everywhere that is not a citation.
        editor
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 260, dy: 26))
            .press(forDuration: 1.0)

        XCTAssertFalse(
            app.staticTexts["citationPaper.title"].waitForExistence(timeout: 3),
            "a long press on prose must not be read as a citation")
    }

    // MARK: - The programmatic entry point

    func testDeepLinkInspectsACitationWithoutATouch() throws {
        _ = try openSeededManuscript()

        // The surface an agent uses: imprint-iOS holds no
        // `com.apple.security.network.server` entitlement, so there is no HTTP
        // route to call.
        app.open(URL(string: "imprint://inspect/citation/Einstein1905")!)

        XCTAssertTrue(
            app.staticTexts["citationPaper.title"].waitForExistence(timeout: 10),
            "imprint://inspect/citation/{key} must raise the same sheet the gesture does")
        capture("citation-paper-sheet-via-url")
    }

    // MARK: - The unresolved cases

    func testAnAbsentCiteKeyIsReportedAsUnknownNotAsAnEmptyLibrary() throws {
        _ = try openSeededManuscript()
        app.open(URL(string: "imprint://inspect/citation/Missing2099")!)

        let unknown = app.otherElements["citationPaper.unknownKey"]
        let unknownText = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] 'No paper with this cite key'"))
            .firstMatch
        XCTAssertTrue(
            unknown.waitForExistence(timeout: 10) || unknownText.waitForExistence(timeout: 5),
            "a key the library does not have must say exactly that")
        capture("citation-paper-sheet-unknown-key")

        // The library HAS papers here, so the empty-library copy would be a lie.
        XCTAssertFalse(
            app.staticTexts
                .containing(NSPredicate(format: "label CONTAINS[c] 'no papers on this device'"))
                .firstMatch.exists,
            "a populated library must never be described as empty")
    }
}
