//
//  ImpressShellUITests.swift
//  impress-iOSUITests
//
//  The regression oracle for impress-iOS: the sidebar built from
//  `AppShellConfiguration.impress` narrowed by `presenting([.message, .figure,
//  .task])`, three lists over `RecordListHost`, three CHASSIS detail panes (two
//  of which were `#if os(macOS)` until this shell wanted them), and the
//  settings screen rendered from `AppSettingsConfiguration.impress`.
//
//  Landscape throughout: in portrait a three-column `NavigationSplitView` hides
//  the sidebar behind a toggle on iPad and is a stack on iPhone — the same
//  reason imprint-iOSUITests and impart-iOSUITests pin `.landscapeLeft`.
//

import XCTest

final class ImpressShellUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = IOSTestApp.launchSeeded()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        app = nil
    }

    // MARK: - Sidebar: what the preset permits AND this host can present

    func testSidebarShowsExactlyTheSectionsThisHostCanPresent() {
        let any = app.descendants(matching: .any)

        XCTAssertTrue(
            any[ImpressA11y.mailSection].waitForExistence(timeout: 30),
            "Mail is permitted by the preset and `.message` is presentable here")
        XCTAssertTrue(any[ImpressA11y.figuresSection].exists, "Figures should render")
        XCTAssertTrue(any[ImpressA11y.agentsSection].exists, "Agents should render")

        // The landing rows the builder DERIVES from each kind's descriptor —
        // no host supplied a single node.
        XCTAssertTrue(any[ImpressA11y.allMessagesNode].exists)
        XCTAssertTrue(any[ImpressA11y.allFiguresNode].exists)
        XCTAssertTrue(any[ImpressA11y.allTasksNode].exists)

        // DECLARED ABSENT, not empty. Every one of these is a section the
        // impress PRESET permits — they are gone because this BUILD says it has
        // no pane for their kind, which is the `presentableKinds` contract.
        for absent in ImpressA11y.declaredAbsentSections {
            XCTAssertFalse(
                any[absent].exists,
                "\(absent) is permitted by the preset but its kind is not in "
                    + "`presentableKinds` — it must be absent, never an empty section")
        }

        capture("sidebar")
    }

    // MARK: - Mail: list + the shared chassis detail pane

    func testSelectingAMailMessageShowsTheChassisDetailPane() {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(
            select(ImpressA11y.allMessagesNode, expecting: ImpressA11y.messageList),
            "RecordListHost should render the mail list")
        let rows = any.matching(NSPredicate(format: "identifier BEGINSWITH %@", "messageRow."))
        XCTAssertGreaterThan(rows.count, 0, "seeded inbox messages should render as rows")
        capture("mail-list")

        let starred = app.staticTexts[ImpressSeed.starredSubject]
        XCTAssertTrue(starred.waitForExistence(timeout: 15))
        starred.tap()

        XCTAssertTrue(
            any[ImpressA11y.messageDetail].waitForExistence(timeout: 20),
            "MessageDetailPane — the SHARED pane, unchanged — should fill the detail column")
        // The Info tab's rows come from the descriptor's declared tabs.
        XCTAssertTrue(app.staticTexts["From"].waitForExistence(timeout: 15))
        capture("mail-detail")
    }

    // MARK: - The mixed-kind claim: three kinds, one shell

    func testFiguresAndTasksRenderThroughTheirNewlyCrossPlatformChassisPanes() {
        let any = app.descendants(matching: .any)

        XCTAssertTrue(
            select(ImpressA11y.allFiguresNode, expecting: ImpressA11y.figureList),
            "the Figures list should render")
        capture("figure-list")
        let figure = app.staticTexts[ImpressSeed.figureTitle]
        XCTAssertTrue(figure.waitForExistence(timeout: 15))
        figure.tap()
        XCTAssertTrue(
            any[ImpressA11y.figureDetail].waitForExistence(timeout: 20),
            "FigureDetailPane was macOS-only until D9 un-gated it; this is the proof it runs")
        capture("figure-detail")

        XCTAssertTrue(
            select(ImpressA11y.allTasksNode, expecting: ImpressA11y.taskList),
            "the Agents (Tasks) list should render")
        let task = app.staticTexts[ImpressSeed.taskTitle]
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        task.tap()
        XCTAssertTrue(
            any[ImpressA11y.taskDetail].waitForExistence(timeout: 20),
            "AgentRecordDetailPane, likewise")
        capture("task-detail")
    }

    // MARK: - Settings

    func testSettingsRendersTheAvailabilityFilteredPreset() {
        let gear = app.buttons[ImpressA11y.settingsButton]
        XCTAssertTrue(gear.waitForExistence(timeout: 30))
        gear.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 15),
            "IOSSettingsScreen should present over `AppSettingsConfiguration.impress`")

        let any = app.descendants(matching: .any)
        XCTAssertTrue(any[ImpressA11y.settingsAppearanceRow].exists,
                      "Appearance is `.everywhere` and comes from the chassis builtin")

        // Asserted BEFORE any scrolling: a lazy List releases off-screen rows,
        // so a negative after a scroll would pass for the wrong reason.
        for macOnly in ImpressA11y.settingsMacOnlyRows {
            XCTAssertFalse(
                any[macOnly].exists,
                "\(macOnly) requires a capability iOS never grants")
        }
        capture("settings")

        any[ImpressA11y.settingsAppearanceRow].tap()
        XCTAssertTrue(
            app.navigationBars.element.waitForExistence(timeout: 15))
        capture("settings-appearance")
    }

    // MARK: - Selection

    /// Tap a sidebar node and wait for its list.
    ///
    /// Retries the tap ONCE: the seed posts a structural store mutation, which
    /// bumps `dataVersion` and makes `RecordSidebarView` rebuild its rows, and a
    /// tap landing during that rebuild can hit a row that is being replaced.
    /// (It is NOT what made the first cold-install run fail — that was the seed
    /// silently failing to open a store whose directory did not exist yet. The
    /// retry stayed because the race it covers is real and one extra tap is
    /// cheaper than a flaky lane.)
    private func select(_ nodeID: String, expecting listID: String) -> Bool {
        let any = app.descendants(matching: .any)
        let node = any[nodeID]
        guard node.waitForExistence(timeout: 30) else { return false }
        node.tap()
        if any[listID].waitForExistence(timeout: 15) { return true }
        node.tap()
        return any[listID].waitForExistence(timeout: 15)
    }

    // MARK: - Screenshots

    /// Attach to the result bundle AND write a PNG to the runner's temp dir, so
    /// evidence can be opened without unpacking an `.xcresult`. `.keepAlways`
    /// because the default discards attachments from PASSING tests.
    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "impress-ios-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("impress-ios-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        return shot
    }
}
