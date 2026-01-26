//
//  BaseTestCase.swift
//  ImpressTestKit
//
//  Common XCTestCase subclasses with setup/teardown patterns.
//

import XCTest

// MARK: - Shared App Test Case (Fast - Recommended)

/// Base test case that shares a single app instance across all tests in the class.
///
/// This is the recommended base class for most UI tests as it significantly
/// reduces test execution time by avoiding app relaunches between tests.
///
/// Usage:
/// ```swift
/// final class MyTests: SharedAppTestCase {
///     override class func setUp() {
///         super.setUp()
///         // Launch app once for all tests
///         launchApp { TestApp.launch() }
///     }
///
///     func testSomething() {
///         // Use `app` which is shared across tests
///     }
/// }
/// ```
open class SharedAppTestCase: XCTestCase {

    /// The shared application instance (class-level)
    public static var sharedApp: XCUIApplication!

    /// Convenience accessor for the shared app
    public var app: XCUIApplication {
        Self.sharedApp
    }

    // MARK: - Class-Level Lifecycle (Run Once Per Class)

    /// Launch the app once for all tests in this class.
    /// Call this from your `override class func setUp()`.
    ///
    /// - Parameter launcher: Closure that launches and returns the app
    public class func launchApp(_ launcher: () -> XCUIApplication) {
        sharedApp = launcher()
        _ = sharedApp.waitForIdle()
    }

    open override class func setUp() {
        super.setUp()
        // Subclasses should call launchApp() here
    }

    open override class func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    // MARK: - Test-Level Lifecycle (Run Before/After Each Test)

    open override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Reset to known state without relaunching
        resetAppState()
    }

    open override func tearDown() {
        // Take screenshot if test failed
        if let failureCount = testRun?.failureCount, failureCount > 0 {
            takeScreenshot(name: "Failure - \(name)")
        }
        super.tearDown()
    }

    // MARK: - State Management

    /// Reset app to a known state without relaunching.
    /// Override in subclasses to customize reset behavior.
    open func resetAppState() {
        // Activate the app
        app.activate()
        _ = app.waitForIdle()

        // Dismiss any sheets/alerts
        app.dismissPresentedContent()

        // Close any extra windows (keep main window)
        closeExtraWindows()

        // Focus the main window
        if let mainWindow = app.windows.allElementsBoundByIndex.first, mainWindow.exists {
            mainWindow.click()
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Close all windows except the main one
    public func closeExtraWindows() {
        var windows = app.windows.allElementsBoundByIndex
        while windows.count > 1 {
            let window = windows.last!
            if window.exists {
                // Focus the window first
                window.click()
                Thread.sleep(forTimeInterval: 0.1)

                // Try to close via Cmd+W
                app.typeKey("w", modifierFlags: .command)
                Thread.sleep(forTimeInterval: 0.3)

                // Handle "Don't Save" dialog if it appears
                handleSaveDialog()
            }
            // Refresh window list
            windows = app.windows.allElementsBoundByIndex
        }
    }

    /// Handle the save dialog that appears when closing a modified document
    public func handleSaveDialog() {
        // Check for save sheet/dialog
        let dontSaveButton = app.sheets.buttons["Don't Save"]
        if dontSaveButton.waitForExistence(timeout: 1) {
            dontSaveButton.click()
            Thread.sleep(forTimeInterval: 0.2)
            return
        }

        // Also check for dialog (non-sheet)
        let dialogDontSave = app.dialogs.buttons["Don't Save"]
        if dialogDontSave.exists {
            dialogDontSave.click()
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Navigate back to root/home state
    public func navigateToRoot() {
        // Press Escape multiple times to dismiss sheets
        for _ in 0..<3 {
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Utility Methods

    /// Wait for a condition with polling
    @discardableResult
    public func waitFor(
        timeout: TimeInterval = 5,
        interval: TimeInterval = 0.1,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return false
    }

    /// Take a screenshot and attach to the test report
    public func takeScreenshot(name: String = "Screenshot") {
        guard let app = Self.sharedApp else { return }
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Verify that a specific accessibility audit passes
    @available(macOS 14.0, iOS 17.0, *)
    public func assertAccessibilityAudit(
        for auditTypes: XCUIAccessibilityAuditType = .all,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        try app.performAccessibilityAudit(for: auditTypes)
    }
}

// MARK: - Fresh App Test Case (Slow - Use Sparingly)

/// Base test case that launches a fresh app instance for each test.
///
/// Use this only when tests truly require a fresh app state (e.g., onboarding,
/// first-launch behavior, state corruption tests).
///
/// For most tests, use `SharedAppTestCase` instead.
open class FreshAppTestCase: XCTestCase {

    /// The application under test (fresh instance per test)
    public var app: XCUIApplication!

    /// Override to customize app launch. Default uses TestApp.launch().
    open func launchApp() -> XCUIApplication {
        TestApp.launch()
    }

    open override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = launchApp()
        _ = app.waitForIdle()
    }

    open override func tearDown() {
        app?.dismissPresentedContent()

        if let failureCount = testRun?.failureCount, failureCount > 0 {
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "Failure Screenshot"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// Wait for a condition with polling
    @discardableResult
    public func waitFor(
        timeout: TimeInterval = 5,
        interval: TimeInterval = 0.1,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return false
    }

    /// Take a screenshot and attach to the test report
    public func takeScreenshot(name: String = "Screenshot") {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// MARK: - Legacy Alias

/// Alias for backward compatibility - maps to FreshAppTestCase
public typealias BaseTestCase = FreshAppTestCase

// MARK: - Accessibility Test Case

/// Base test case for accessibility-focused tests.
/// Uses fresh app launch with accessibility mode enabled.
open class AccessibilityTestCase: FreshAppTestCase {

    open override func launchApp() -> XCUIApplication {
        TestApp.launchForAccessibility()
    }

    open override func setUp() {
        super.setUp()
        // Continue after failure to collect all audit issues
        continueAfterFailure = true
    }
}

// MARK: - Integration Test Case

/// Base test case for integration tests with real services.
open class IntegrationTestCase: FreshAppTestCase {

    open override func launchApp() -> XCUIApplication {
        TestApp.launchForIntegration()
    }
}
