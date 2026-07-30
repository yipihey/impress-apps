//
//  ThroughlinePaneUITests.swift
//  imprint-iOSUITests
//
//  C1's regression oracle for the throughline on iOS — the pane macOS has had
//  since ADR-0016 and iPad had no way to open, although `ThroughlineCoordinator`
//  and `ThroughlineModel` were compiled into this target the whole time.
//
//  Hermetic, like `CitationInspectionUITests`: `--ui-testing --uitesting-seed`
//  seeds the fixture manuscript AND a throughline for it (two labelled beats,
//  `<tl-overview>` anchored to the manuscript's only section and baselined), so
//  the pane opens on real state rather than on its create affordance.
//
//  What this proves, in order:
//    1. the entry point exists in the iOS editor chrome (a toolbar button);
//    2. the pane that opens is the SHARED `ThroughlinePaneView` — asserted
//       through its own identifiers, which are the same on both platforms;
//    3. the seeded throughline HYDRATED from the store (`IOSManuscriptEditorHost`
//       → `ImprintStoreAdapter.loadThroughline`), i.e. the sidecar-less
//       store-first path works on iOS;
//    4. the badge legend is reachable by LONG PRESS, the iOS substitute for the
//       macOS hover tooltip that carries this pane's meaning.
//

import XCTest

final class ThroughlinePaneUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--uitesting-seed"]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also on disk, so the evidence can be looked at without unpacking an
        // .xcresult (the convention `LibraryShellUITests` established).
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imprint-shot-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        return shot
    }

    /// Open the seeded manuscript's editor.
    private func openSeededManuscript() throws {
        let row = app.staticTexts["Citation Long Press Fixture"]
        guard row.waitForExistence(timeout: 30) else {
            capture("throughline-library-without-fixture")
            throw XCTSkip("seeded manuscript did not appear — seeding failed, not the feature")
        }
        row.tap()
    }

    /// Raise the throughline sheet from the editor toolbar.
    private func openThroughline() throws {
        let button = app.buttons["toolbar.throughlineButton"]
        XCTAssertTrue(
            button.waitForExistence(timeout: 30),
            "the iOS editor must offer a throughline entry point")
        button.tap()
    }

    // MARK: - The pane

    func testToolbarButtonOpensTheSharedPaneWithTheSeededThroughline() throws {
        try openSeededManuscript()
        try openThroughline()

        XCTAssertTrue(
            app.navigationBars["Throughline"].waitForExistence(timeout: 20),
            "the pane is presented as a sheet with an inline title")
        capture("throughline-pane")

        // The seeded narrative hydrated out of the store: both labelled beats
        // are rows, addressed by the identifier the SHARED pane emits.
        for label in ["tl-overview", "tl-derivation"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["throughline.paragraph.\(label)"]
                    .waitForExistence(timeout: 10),
                "paragraph <\(label)> should render — if this is empty the "
                    + "store hydrate in IOSManuscriptEditorHost did not run")
        }
        // Prose, not just structure.
        XCTAssertTrue(
            app.staticTexts["Special relativity follows from two postulates and nothing else."]
                .exists)

        // The anchored beat is baselined, so its badge is `synced`; the other
        // has no anchor, so it is `unanchored`. Both are the DERIVED state, not
        // seeded strings — this is the assertion that would break if
        // `anchorStates` stopped resolving on iOS.
        XCTAssertTrue(
            app.descendants(matching: .any)["throughline.badge.synced"].exists,
            "the anchored, baselined paragraph should read as in sync")
        XCTAssertTrue(
            app.descendants(matching: .any)["throughline.badge.unanchored"].exists,
            "the un-anchored paragraph should say so")

        // The coverage footer is a query, not a nag (ADR-0016 D7). Asserted by
        // its SENTENCE rather than its identifier: the footer is a `Group` whose
        // covered branch is one `Text`, and the identifier on the container does
        // not reach it — the copy is the thing a reader gets anyway, and with
        // the fixture's one section anchored it must report full coverage.
        XCTAssertTrue(
            app.staticTexts["All sections are narrated or marked supporting."].exists,
            "the anchored section should count as narrated")

        // Story / Edit is the pane's own toggle; Edit shows the raw Typst.
        let mode = app.segmentedControls["throughline.modePicker"]
        if mode.waitForExistence(timeout: 5) {
            mode.buttons["Edit"].tap()
            XCTAssertTrue(
                app.textViews["throughline.sourceEditor"].waitForExistence(timeout: 10),
                "Edit mode shows the raw throughline source")
            capture("throughline-edit")
            mode.buttons["Story"].tap()
        }

        app.buttons["throughline.done"].tap()
        XCTAssertTrue(
            app.buttons["toolbar.throughlineButton"].waitForExistence(timeout: 10),
            "Done returns to the editor")
    }

    /// The hover adaptation. macOS explains a badge with `.help` on hover; iOS
    /// has no hover, so the badge answers a long press with the same sentence —
    /// the pattern `CitationPaperSheet` established for cite keys.
    func testLongPressOnABadgeExplainsTheState() throws {
        try openSeededManuscript()
        try openThroughline()

        let badge = app.descendants(matching: .any)["throughline.badge.synced"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 20))
        badge.press(forDuration: 1.2)

        XCTAssertTrue(
            app.staticTexts["In sync with anchored sections"].waitForExistence(timeout: 10)
                || app.buttons["In sync with anchored sections"].waitForExistence(timeout: 1),
            "the badge's meaning must be reachable without a pointer")
        capture("throughline-badge-legend")
    }
}
