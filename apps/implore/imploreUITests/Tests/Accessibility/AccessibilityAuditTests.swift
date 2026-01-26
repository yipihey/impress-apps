//
//  AccessibilityAuditTests.swift
//  imploreUITests
//
//  Automated accessibility audit tests for implore.
//  Uses fresh app launch since audits need clean state.
//

import XCTest
import ImpressTestKit

/// Automated accessibility audits for implore.
/// Uses FreshAppTestCase because accessibility audits need consistent, clean state.
final class AccessibilityAuditTests: FreshAppTestCase {

    // MARK: - Setup

    override func launchApp() -> XCUIApplication {
        ImploreTestApp.launchForAccessibility()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true // Collect all audit issues
    }

    // MARK: - Full Window Audit Tests

    /// Test main window passes accessibility audit
    @available(macOS 14.0, *)
    func testMainWindowAccessibilityAudit() throws {
        try app.performAccessibilityAudit()
    }

    /// Test main window audit with specific issue types
    @available(macOS 14.0, *)
    func testMainWindowAuditForSpecificIssues() throws {
        try app.performAccessibilityAudit(for: [
            .sufficientElementDescription,
            .contrast,
            .parentChild
        ])
    }

    // MARK: - View-Specific Audit Tests

    /// Test welcome screen accessibility audit
    @available(macOS 14.0, *)
    func testWelcomeScreenAccessibilityAudit() throws {
        let welcome = WelcomePage(app: app)
        _ = welcome.waitForWelcome()

        try app.performAccessibilityAudit()
    }

    /// Test visualization view accessibility audit
    @available(macOS 14.0, *)
    func testVisualizationAccessibilityAudit() throws {
        // Need to relaunch with sample dataset
        app.terminate()
        app = ImploreTestApp.launchWithSampleDataset()
        _ = app.waitForIdle()

        let viz = VisualizationPage(app: app)
        _ = viz.waitForVisualization()

        try app.performAccessibilityAudit()
    }

    /// Test selection grammar accessibility audit
    @available(macOS 14.0, *)
    func testSelectionGrammarAccessibilityAudit() throws {
        // Need to relaunch with sample dataset
        app.terminate()
        app = ImploreTestApp.launchWithSampleDataset()
        _ = app.waitForIdle()

        let selection = SelectionGrammarPage(app: app)
        selection.open()
        _ = selection.waitForSheet()

        try app.performAccessibilityAudit()

        selection.cancel()
    }

    /// Test settings window accessibility audit
    @available(macOS 14.0, *)
    func testSettingsAccessibilityAudit() throws {
        let settings = SettingsPage(app: app)
        settings.open()
        _ = settings.waitForWindow()

        try app.performAccessibilityAudit()

        settings.close()
    }

    // MARK: - Contrast Tests

    /// Test color contrast meets WCAG AA
    @available(macOS 14.0, *)
    func testColorContrastCompliance() throws {
        try app.performAccessibilityAudit(for: .contrast)
    }

    // MARK: - Element Description Tests

    /// Test all interactive elements have descriptions
    @available(macOS 14.0, *)
    func testElementDescriptions() throws {
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
    }

    // MARK: - Custom Audit Helpers

    /// Verify all buttons have accessibility labels
    func testAllButtonsHaveLabels() throws {
        let buttons = app.buttons.allElementsBoundByIndex

        var unlabeledButtons: [String] = []

        for button in buttons where button.exists && button.isHittable {
            if button.label.isEmpty && button.identifier.isEmpty {
                unlabeledButtons.append(button.debugDescription)
            }
        }

        XCTAssertTrue(
            unlabeledButtons.isEmpty,
            "Found \(unlabeledButtons.count) buttons without labels"
        )
    }
}
