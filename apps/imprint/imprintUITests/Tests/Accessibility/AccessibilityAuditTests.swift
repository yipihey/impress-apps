//
//  AccessibilityAuditTests.swift
//  imprintUITests
//
//  Automated accessibility audit tests for imprint.
//  Uses fresh app launch since audits need clean state.
//

import XCTest
import ImpressTestKit

/// Automated accessibility audits for imprint.
/// Uses FreshAppTestCase because accessibility audits need consistent, clean state.
final class AccessibilityAuditTests: FreshAppTestCase {

    // MARK: - Setup

    override func launchApp() -> XCUIApplication {
        let app = ImprintTestApp.launch(
            resetState: true,
            mockServices: true,
            skipOnboarding: true,
            sampleDocument: true
        )
        _ = app.windows.firstMatch.waitForExistence(timeout: 5)
        return app
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

    /// Test source editor accessibility audit
    @available(macOS 14.0, *)
    func testSourceEditorAccessibilityAudit() throws {
        let content = ContentPage(app: app)
        content.selectEditMode(.splitView)
        _ = content.waitForContent()

        try app.performAccessibilityAudit()
    }

    /// Test citation picker accessibility audit
    @available(macOS 14.0, *)
    func testCitationPickerAccessibilityAudit() throws {
        let content = ContentPage(app: app)

        guard content.openCitationPickerAndWait() else {
            XCTFail("Citation picker should open")
            return
        }

        try app.performAccessibilityAudit()

        let citationPicker = CitationPickerPage(app: app)
        citationPicker.cancel()
        _ = citationPicker.waitForClose()
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

    /// Verify all text fields have labels
    func testAllTextFieldsHaveLabels() throws {
        let textFields = app.textFields.allElementsBoundByIndex

        for textField in textFields where textField.exists {
            XCTAssertFalse(
                textField.label.isEmpty && textField.placeholderValue?.isEmpty != false,
                "Text field should have label or placeholder"
            )
        }
    }
}
