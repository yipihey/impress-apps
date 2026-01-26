//
//  WelcomePage.swift
//  imploreUITests
//
//  Page Object for the welcome screen.
//

import XCTest
import ImpressTestKit

/// Page Object for the welcome screen
struct WelcomePage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// Welcome container (the entire welcome view)
    var container: XCUIElement {
        app[ImploreAccessibilityID.Welcome.container]
    }

    /// Open dataset button - find by label since SwiftUI button IDs can be tricky
    var openButton: XCUIElement {
        // Try accessibility ID first, fall back to button label
        let byId = app.buttons.matching(identifier: ImploreAccessibilityID.Welcome.openButton).firstMatch
        if byId.exists {
            return byId
        }
        // Fall back to finding by button text
        return app.buttons["Open Dataset"].firstMatch
    }

    /// Welcome title text - search directly in app, not nested
    var title: XCUIElement {
        app.staticTexts["Welcome to implore"].firstMatch
    }

    /// Supported formats section header
    var supportedFormats: XCUIElement {
        app.staticTexts["Supported formats:"].firstMatch
    }

    // MARK: - State Checks

    /// Check if welcome screen is visible
    var isVisible: Bool {
        // Check for title text which is unique to welcome screen
        title.exists
    }

    // MARK: - Actions

    /// Click the Open Dataset button
    func clickOpen() {
        // Wait for button to exist first
        _ = openButton.waitForExistence(timeout: 5)
        openButton.click()
    }

    /// Open file using keyboard shortcut (Cmd+O)
    func openWithKeyboard() {
        app.typeKey("o", modifierFlags: .command)
    }

    // MARK: - Assertions

    /// Wait for welcome screen to appear
    @discardableResult
    func waitForWelcome(timeout: TimeInterval = 5) -> Bool {
        title.waitForExistence(timeout: timeout)
    }

    /// Assert welcome screen is visible
    func assertVisible(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            waitForWelcome(),
            "Welcome screen should be visible",
            file: file,
            line: line
        )
    }

    /// Assert open button exists
    func assertOpenButtonExists(file: StaticString = #file, line: UInt = #line) {
        _ = openButton.waitForExistence(timeout: 5)
        XCTAssertTrue(
            openButton.exists,
            "Open button should exist",
            file: file,
            line: line
        )
    }

    /// Assert supported formats are listed
    func assertFormatsListed(file: StaticString = #file, line: UInt = #line) {
        _ = supportedFormats.waitForExistence(timeout: 5)
        XCTAssertTrue(
            supportedFormats.exists,
            "Supported formats section should be visible",
            file: file,
            line: line
        )
    }
}
