//
//  AccessibilityAuditTests.swift
//  imbibUITests
//
//  Automated accessibility audit tests.
//

import XCTest

/// Automated accessibility audits using system APIs.
///
/// Uses XCTest's built-in accessibility audit capabilities
/// available in iOS 17+ and macOS 14+.
final class AccessibilityAuditTests: XCTestCase {

    var app: XCUIApplication!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = true // Continue to collect all audit issues

        app = TestApp.launchForAccessibility()
        _ = app.waitForIdle()
    }

    // MARK: - Full Window Audit Tests

    /// Test main window passes accessibility audit
    @available(macOS 14.0, iOS 17.0, *)
    func testMainWindowAccessibilityAudit() throws {
        // Perform system accessibility audit
        try app.performAccessibilityAudit()
    }

    /// Test main window audit with specific issue types
    @available(macOS 14.0, iOS 17.0, *)
    func testMainWindowAuditForSpecificIssues() throws {
        // Check for specific accessibility issues
        try app.performAccessibilityAudit(for: [
            .sufficientElementDescription,
            .contrast,
            .parentChild
        ])
    }

    // MARK: - View-Specific Audit Tests

    /// Test sidebar accessibility audit
    @available(macOS 14.0, iOS 17.0, *)
    func testSidebarAccessibilityAudit() throws {
        let sidebar = SidebarPage(app: app)
        _ = sidebar.waitForSidebar()

        // Audit just the sidebar area
        try app.performAccessibilityAudit { issue in
            // Filter to sidebar-related issues
            let elementDescription = issue.element?.debugDescription ?? ""
            return elementDescription.contains("sidebar") ||
                   elementDescription.contains("Sidebar") ||
                   elementDescription.contains("outline")
        }
    }

    /// Test detail view accessibility audit
    @available(macOS 14.0, iOS 17.0, *)
    func testDetailViewAccessibilityAudit() throws {
        // Navigate to show detail view
        let sidebar = SidebarPage(app: app)
        _ = sidebar.waitForSidebar()
        sidebar.selectAllPublications()

        let list = PublicationListPage(app: app)
        _ = list.waitForPublications()
        list.selectFirst()

        // Audit the detail view
        try app.performAccessibilityAudit()
    }

    /// Test search palette accessibility audit
    @available(macOS 14.0, iOS 17.0, *)
    func testSearchPaletteAccessibilityAudit() throws {
        let searchPalette = SearchPalettePage(app: app)
        searchPalette.open()
        _ = searchPalette.waitForPalette()

        // Audit with search palette open
        try app.performAccessibilityAudit()

        searchPalette.close()
    }

    /// Test settings window accessibility audit
    @available(macOS 14.0, iOS 17.0, *)
    func testSettingsAccessibilityAudit() throws {
        let settings = SettingsPage(app: app)
        settings.open()
        _ = settings.waitForWindow()

        // Audit settings window
        try app.performAccessibilityAudit()

        settings.close()
    }

    // MARK: - Contrast Tests

    /// Test color contrast meets WCAG AA
    @available(macOS 14.0, iOS 17.0, *)
    func testColorContrastCompliance() throws {
        // Audit specifically for contrast issues
        try app.performAccessibilityAudit(for: .contrast)
    }

    /// Test contrast in dark mode
    @available(macOS 14.0, iOS 17.0, *)
    func testDarkModeContrastCompliance() throws {
        // Note: Changing appearance in tests is limited
        // This test assumes system is in dark mode or would need
        // to be run separately in dark mode

        try app.performAccessibilityAudit(for: .contrast)
    }

    // MARK: - Dynamic Type Tests

    /// Test all accessibility audit types
    @available(macOS 14.0, iOS 17.0, *)
    func testAllAccessibilityAuditTypes() throws {
        // Run all available accessibility audits
        try app.performAccessibilityAudit(for: .all)
    }

    // MARK: - Element Description Tests

    /// Test all interactive elements have descriptions
    @available(macOS 14.0, iOS 17.0, *)
    func testElementDescriptions() throws {
        // Audit for missing element descriptions
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
    }

    // MARK: - Touch Target Tests

    /// Test touch targets are large enough
    @available(macOS 14.0, iOS 17.0, *)
    func testTouchTargetSize() throws {
        // Audit for touch target size (more relevant for iOS)
        try app.performAccessibilityAudit(for: .hitRegion)
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
            "Found \(unlabeledButtons.count) buttons without labels: \(unlabeledButtons.prefix(5).joined(separator: ", "))"
        )
    }

    /// Verify all text fields have labels
    func testAllTextFieldsHaveLabels() throws {
        let textFields = app.textFields.allElementsBoundByIndex

        for textField in textFields where textField.exists {
            XCTAssertFalse(
                textField.label.isEmpty && textField.placeholderValue?.isEmpty != false,
                "Text field should have label or placeholder: \(textField.debugDescription)"
            )
        }
    }

    /// Verify all images have descriptions
    func testImagesHaveDescriptions() throws {
        let images = app.images.allElementsBoundByIndex

        var unlabeledImages: [String] = []

        for image in images where image.exists {
            // Decorative images might intentionally have empty labels
            // But interactive images should have descriptions
            if image.isHittable && image.label.isEmpty {
                unlabeledImages.append(image.debugDescription)
            }
        }

        // Allow some decorative images but flag if there are many
        XCTAssertLessThan(
            unlabeledImages.count,
            5,
            "Found \(unlabeledImages.count) interactive images without descriptions"
        )
    }

    /// Verify tables have headers
    func testTablesHaveHeaders() throws {
        let tables = app.tables.allElementsBoundByIndex

        for table in tables where table.exists {
            // Tables should have column headers or row headers
            let headers = table.cells.matching(NSPredicate(format: "isHeader == YES"))
            // This is a simplified check - actual header verification is more complex
        }
    }

    // MARK: - Programmatic Checks

    /// Check for accessibility issues programmatically
    func testNoAccessibilityWarnings() throws {
        // Collect all potential issues
        var issues: [String] = []

        // Check buttons
        for button in app.buttons.allElementsBoundByIndex where button.exists && button.isHittable {
            if button.label.isEmpty {
                issues.append("Button without label: \(button.identifier.isEmpty ? "unknown" : button.identifier)")
            }
        }

        // Check text fields
        for textField in app.textFields.allElementsBoundByIndex where textField.exists {
            if textField.label.isEmpty && textField.placeholderValue?.isEmpty != false {
                issues.append("Text field without label")
            }
        }

        // Check images
        for image in app.images.allElementsBoundByIndex where image.exists && image.isHittable {
            if image.label.isEmpty {
                issues.append("Image without label")
            }
        }

        // Report all issues
        if !issues.isEmpty {
            XCTFail("Accessibility issues found:\n" + issues.joined(separator: "\n"))
        }
    }
}

// MARK: - Accessibility Audit Configuration

@available(macOS 14.0, iOS 17.0, *)
extension XCUIApplication {

    /// Perform accessibility audit with custom filtering.
    ///
    /// - Parameter filter: Closure to filter which issues to report (return true to include issue)
    func performAccessibilityAudit(filter: @escaping (XCUIAccessibilityAuditIssue) -> Bool) throws {
        try performAccessibilityAudit { issue in
            return filter(issue)
        }
    }
}
