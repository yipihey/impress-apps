//
//  TestApp.swift
//  ImpressTestKit
//
//  Generic app launcher with configurable arguments for UI testing.
//

import XCTest

/// Test app launch configuration for UI tests.
///
/// Provides consistent app launch configurations for different testing scenarios:
/// - Standard UI tests with mocked services
/// - Accessibility tests with VoiceOver support
/// - Integration tests with real services
public struct TestApp {

    // MARK: - Launch Arguments

    /// Argument to enable UI testing mode (in-memory store, etc.)
    public static let uiTestingArg = "--ui-testing"

    /// Argument to reset app state before test
    public static let resetStateArg = "--reset-state"

    /// Argument to use mock services instead of real network calls
    public static let mockServicesArg = "--mock-services"

    /// Argument to enable accessibility testing mode
    public static let accessibilityTestingArg = "--accessibility-testing"

    // MARK: - Launch Methods

    /// Launch the app with default test configuration.
    ///
    /// - Parameters:
    ///   - resetState: Whether to reset app state (clear database). Default: true
    ///   - mockServices: Whether to use mock services. Default: true
    ///   - accessibilityEnabled: Whether to enable accessibility testing mode. Default: false
    ///   - additionalArguments: Additional launch arguments to pass
    /// - Returns: Configured XCUIApplication instance
    @discardableResult
    public static func launch(
        resetState: Bool = true,
        mockServices: Bool = true,
        accessibilityEnabled: Bool = false,
        additionalArguments: [String] = []
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

        app.launchArguments.append(contentsOf: additionalArguments)

        app.launch()
        return app
    }

    /// Launch the app for integration tests with real services.
    ///
    /// Uses real network services but still uses in-memory store.
    /// - Returns: Configured XCUIApplication instance
    @discardableResult
    public static func launchForIntegration() -> XCUIApplication {
        return launch(resetState: true, mockServices: false, accessibilityEnabled: false)
    }

    /// Launch the app for accessibility tests.
    ///
    /// Enables accessibility testing mode for VoiceOver and audit tests.
    /// - Returns: Configured XCUIApplication instance
    @discardableResult
    public static func launchForAccessibility() -> XCUIApplication {
        return launch(resetState: true, mockServices: true, accessibilityEnabled: true)
    }
}

// MARK: - XCUIApplication Extensions

extension XCUIApplication {

    /// Wait for the app to become idle (no more animations/loading).
    ///
    /// - Parameter timeout: Maximum time to wait
    /// - Returns: true if app became idle within timeout
    @discardableResult
    public func waitForIdle(timeout: TimeInterval = 5) -> Bool {
        // Wait for the main window to exist and be hittable
        let mainWindow = windows.firstMatch
        return mainWindow.waitForExistence(timeout: timeout)
    }

    /// Dismiss any presented sheets or alerts.
    public func dismissPresentedContent() {
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

    /// Open settings window using Cmd+,
    public func openSettings() {
        typeKey(",", modifierFlags: .command)
    }

    /// Close all sheets by pressing Escape repeatedly
    public func closeAllSheets(maxAttempts: Int = 3) {
        for _ in 0..<maxAttempts {
            typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
