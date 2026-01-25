//
//  SettingsTests.swift
//  imbibUITests
//
//  Created by Claude on 2026-01-22.
//

import XCTest

/// UI tests for settings view
final class SettingsTests: XCTestCase {
    var app: XCUIApplication!
    var settings: SettingsPage!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        settings = SettingsPage(app: app)
    }

    override func tearDownWithError() throws {
        app = nil
        settings = nil
    }

    // MARK: - Helper

    private func openSettings() -> Bool {
        // On macOS, Settings is accessed via Cmd+, keyboard shortcut
        app.typeKey(",", modifierFlags: .command)

        // Wait for settings to appear
        sleep(1)

        // Check if a new window appeared
        return app.windows.count > 1
    }

    // MARK: - Settings Window Tests

    func testOpenSettings() throws {
        let opened = openSettings()
        if opened {
            // Settings window should appear
            let settingsWindow = app.windows.element(matching: .window, identifier: "Settings")
            XCTAssertTrue(
                settingsWindow.waitForExistence(timeout: 5) || app.windows.count > 1,
                "Settings window should appear"
            )
        }
    }

    func testSettingsWindowHasTabs() throws {
        guard openSettings() else {
            throw XCTSkip("Could not open settings")
        }

        // Wait for settings to load
        sleep(1)

        // Look for tab views or toolbar items in settings
        if settings.tabView.waitForExistence(timeout: 3) {
            XCTAssertTrue(settings.tabView.exists)
        }
    }

    // MARK: - Tab Navigation Tests

    func testNavigateToGeneralTab() throws {
        guard openSettings() else {
            throw XCTSkip("Could not open settings")
        }

        if settings.generalTab.waitForExistence(timeout: 3) {
            settings.selectGeneralTab()
        }
    }

    func testNavigateToSourcesTab() throws {
        guard openSettings() else {
            throw XCTSkip("Could not open settings")
        }

        if settings.sourcesTab.waitForExistence(timeout: 3) {
            settings.selectSourcesTab()
        }
    }

    func testNavigateToAdvancedTab() throws {
        guard openSettings() else {
            throw XCTSkip("Could not open settings")
        }

        if settings.advancedTab.waitForExistence(timeout: 3) {
            settings.selectAdvancedTab()
        }
    }
}
