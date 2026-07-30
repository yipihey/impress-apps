//
//  MailShellUITests.swift
//  impart-iOSUITests
//
//  Stage 5c's regression oracle for impart-iOS's chassis shell: the sidebar
//  built from `AppShellConfiguration.impart` + `MailSidebarSnapshot`, the message
//  list over `MessageRowData`, the shared `MessageDetailPane`, and the settings
//  screen rendered from `AppSettingsConfiguration.impart` with the four
//  `.macOSOnly()` rows filtered out.
//
//  Landscape throughout: in portrait a three-column `NavigationSplitView` on iPad
//  hides the sidebar behind a toggle, and on iPhone it is a stack — the same
//  reason imprint-iOSUITests pins `.landscapeLeft`.
//

import XCTest

final class MailShellUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = IOSTestApp.launchSeeded()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        // A still-terminating instance made imbib's second and third case in a
        // session die with "crashed with signal kill" while each passed alone.
        app?.terminate()
        app = nil
    }

    // MARK: - Sidebar

    func testSidebarShowsThePresetSectionAndTheSeededMailTree() {
        XCTAssertTrue(
            app.descendants(matching: .any)[ImpartA11y.mailSection].waitForExistence(timeout: 20),
            "the Mail section header should exist — it is the only section `.impart` permits")

        XCTAssertTrue(
            app.descendants(matching: .any)[ImpartA11y.allInboxesNode].waitForExistence(timeout: 10),
            "All Inboxes is the section's first row and the shell's landing route")

        // One account row (host scope) and its role-ordered folders.
        let accountRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", ImpartA11y.accountNodePrefix))
        XCTAssertGreaterThan(accountRows.count, 0, "the seeded mail-account row should render")
        XCTAssertTrue(app.staticTexts[ImpartSeed.accountName].exists)

        // Folders start expanded (`RecordSidebarView` seeds expansion so a
        // collapsed tree does not read as "no subfolders" on a touch device).
        let folderRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", ImpartA11y.folderNodePrefix))
        XCTAssertGreaterThanOrEqual(
            folderRows.count, 4, "four seeded mailboxes should be visible under the account")

        // Sections the preset does NOT permit must be absent — the declarative
        // replacement for a hand-written sidebar's fifteen-arm switch.
        for absent in ["sidebar.section.inbox", "sidebar.section.libraries",
                       "sidebar.section.flagged", "sidebar.section.dismissed"] {
            XCTAssertFalse(
                app.descendants(matching: .any)[absent].exists,
                "\(absent) is not in `AppShellConfiguration.impart.visibleSections`")
        }

        capture("sidebar")
    }

    // MARK: - List + detail

    func testMessageListRendersSeededRowsAndDetailShowsAMessage() {
        let allInboxes = app.descendants(matching: .any)[ImpartA11y.allInboxesNode]
        XCTAssertTrue(allInboxes.waitForExistence(timeout: 20))
        allInboxes.tap()

        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", ImpartA11y.messageRowPrefix))
        XCTAssertTrue(
            app.descendants(matching: .any)[ImpartA11y.messageList].waitForExistence(timeout: 15),
            "the mail list should render for All Inboxes")
        XCTAssertGreaterThan(rows.count, 0, "seeded inbox messages should render as rows")

        // Thread collapsing: the three-message thread stands in as ONE row
        // carrying a "(\(n))" badge, so the row count is below the message count.
        XCTAssertTrue(
            app.staticTexts["(\(ImpartSeed.threadMemberCount))"].exists,
            "the collapsed thread should carry its member-count badge")

        capture("list")

        // Selecting a row shows the SHARED chassis detail pane.
        let starred = app.staticTexts[ImpartSeed.starredSubject]
        XCTAssertTrue(starred.waitForExistence(timeout: 10))
        starred.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[ImpartA11y.messageDetail].waitForExistence(timeout: 15),
            "MessageDetailPane should appear in the detail column")
        // The pane's Info tab: subject, From, Date — from the descriptor's tabs.
        XCTAssertTrue(app.staticTexts["From"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Date"].exists)

        capture("detail")

        // Source tab renders the body the mirror stored as plain text.
        let sourceTab = app.buttons["Source"]
        if sourceTab.waitForExistence(timeout: 5) {
            sourceTab.tap()
            capture("detail-source")
        }
    }

    // MARK: - Settings

    func testSettingsScreenRendersTheAvailabilityFilteredPreset() {
        let gear = app.buttons[ImpartA11y.settingsButton]
        XCTAssertTrue(gear.waitForExistence(timeout: 20))
        gear.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "IOSSettingsScreen should present over `AppSettingsConfiguration.impart`")

        // The two rows Stage 5c made `.everywhere`.
        XCTAssertTrue(app.descendants(matching: .any)[ImpartA11y.settingsAccountsRow].exists)
        XCTAssertTrue(app.descendants(matching: .any)[ImpartA11y.settingsGeneralRow].exists)

        // The four that stay on the Mac. Asserted BEFORE any scrolling: a lazy
        // `List` releases off-screen rows, so `exists` reads false after a scroll
        // and the negative would pass for the wrong reason (imbib's note).
        for macOnly in ImpartA11y.settingsMacOnlyRows {
            XCTAssertFalse(
                app.descendants(matching: .any)[macOnly].exists,
                "\(macOnly) is `.macOSOnly()` in impart's preset")
        }

        capture("settings")

        app.descendants(matching: .any)[ImpartA11y.settingsGeneralRow].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.general.appearance"]
                .waitForExistence(timeout: 10),
            "the General pane's appearance picker should render")
        capture("settings-general")
    }

    // MARK: - Screenshots

    /// Attach to the result bundle AND write a PNG to the runner's temp dir, so
    /// evidence can be opened without unpacking an `.xcresult`. `.keepAlways`
    /// because the default discards attachments from PASSING tests — the case you
    /// most want to look at is the one that passed.
    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "impart-ios-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("impart-ios-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        return shot
    }
}
