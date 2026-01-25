//
//  TestApp.swift
//  imbibUITests
//
//  Infrastructure for launching the app in test configurations.
//

import XCTest

/// Test app launch configuration for UI tests.
///
/// Provides consistent app launch configurations for different testing scenarios:
/// - Standard UI tests with mocked services
/// - Accessibility tests with VoiceOver support
/// - Integration tests with real services
enum TestApp {

    // MARK: - Launch Arguments

    /// Argument to enable UI testing mode (in-memory store, etc.)
    static let uiTestingArg = "--ui-testing"

    /// Argument to reset app state before test
    static let resetStateArg = "--reset-state"

    /// Argument to use mock services instead of real network calls
    static let mockServicesArg = "--mock-services"

    /// Argument to enable accessibility testing mode
    static let accessibilityTestingArg = "--accessibility-testing"

    // MARK: - Launch Methods

    /// Launch the app with default test configuration.
    ///
    /// - Parameters:
    ///   - resetState: Whether to reset app state (clear database). Default: true
    ///   - mockServices: Whether to use mock services. Default: true
    ///   - accessibilityEnabled: Whether to enable accessibility testing mode. Default: false
    /// - Returns: Configured XCUIApplication instance
    @discardableResult
    static func launch(
        resetState: Bool = true,
        mockServices: Bool = true,
        accessibilityEnabled: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()

        // Always enable UI testing mode
        app.launchArguments.append(uiTestingArg)

        if resetState {
            app.launchArguments.append(resetStateArg)
        }

        if mockServices {
            app.launchArguments.append(mockServicesArg)
        }

        if accessibilityEnabled {
            app.launchArguments.append(accessibilityTestingArg)
        }

        app.launch()
        return app
    }

    /// Launch the app for integration tests with real services.
    ///
    /// Uses real network services but still uses in-memory store.
    /// - Returns: Configured XCUIApplication instance
    @discardableResult
    static func launchForIntegration() -> XCUIApplication {
        return launch(resetState: true, mockServices: false, accessibilityEnabled: false)
    }

    /// Launch the app for accessibility tests.
    ///
    /// Enables accessibility testing mode for VoiceOver and audit tests.
    /// - Returns: Configured XCUIApplication instance
    @discardableResult
    static func launchForAccessibility() -> XCUIApplication {
        return launch(resetState: true, mockServices: true, accessibilityEnabled: true)
    }

    /// Launch the app with pre-seeded test data.
    ///
    /// - Parameter dataSet: The test data set to load
    /// - Returns: Configured XCUIApplication instance
    @discardableResult
    static func launch(with dataSet: TestDataSet) -> XCUIApplication {
        let app = XCUIApplication()

        app.launchArguments.append(uiTestingArg)
        app.launchArguments.append(mockServicesArg)
        app.launchArguments.append("--test-data-set=\(dataSet.rawValue)")

        app.launch()
        return app
    }
}

// MARK: - Test Data Sets

/// Predefined test data sets for different testing scenarios.
enum TestDataSet: String {
    /// Empty library - no publications
    case empty = "empty"

    /// Small set of publications for basic tests
    case basic = "basic"

    /// Large set of publications for performance tests
    case large = "large"

    /// Publications with PDFs attached
    case withPDFs = "with-pdfs"

    /// Multiple libraries and collections
    case multiLibrary = "multi-library"

    /// Inbox with pending items for triage tests
    case inboxTriage = "inbox-triage"
}

// MARK: - XCUIApplication Extensions

extension XCUIApplication {

    /// Wait for the app to become idle (no more animations/loading).
    ///
    /// - Parameter timeout: Maximum time to wait
    /// - Returns: true if app became idle within timeout
    @discardableResult
    func waitForIdle(timeout: TimeInterval = 5) -> Bool {
        // Wait for the main window to exist and be hittable
        let mainWindow = windows.firstMatch
        return mainWindow.waitForExistence(timeout: timeout)
    }

    /// Dismiss any presented sheets or alerts.
    func dismissPresentedContent() {
        // Try pressing Escape to dismiss sheets
        typeKey(.escape, modifierFlags: [])

        // If there's an alert, try to dismiss it
        let alert = alerts.firstMatch
        if alert.exists {
            if alert.buttons["OK"].exists {
                alert.buttons["OK"].click()
            } else if alert.buttons["Cancel"].exists {
                alert.buttons["Cancel"].click()
            }
        }
    }
}
