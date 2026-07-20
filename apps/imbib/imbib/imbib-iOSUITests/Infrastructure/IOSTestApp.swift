//
//  IOSTestApp.swift
//  imbib-iOSUITests
//
//  Launch configuration for the iOS UI tests. Mirrors the macOS
//  `imbibUITests/Infrastructure/TestApp.swift` launcher but targets the
//  seeded in-memory store path used by imbib-iOS.
//

import XCTest

enum IOSTestApp {

    /// Routes `RustStoreAdapter.shared` to an in-memory store (no user data).
    static let uiTestingArg = "--ui-testing"

    /// Makes `imbibApp.seedUITestDataIfNeeded()` seed the deterministic
    /// fixture library ("Test Library" + two publications).
    static let seedArg = "--uitesting-seed"

    /// Launch the app with an in-memory store seeded with deterministic data.
    ///
    /// The app suppresses onboarding and the notification-permission request
    /// under `--ui-testing`, but a simulator may still have a *pending*
    /// notification alert queued from a prior (un-guarded) launch. We dismiss
    /// any such system alert defensively so it never blocks the session.
    @discardableResult
    static func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [uiTestingArg, seedArg]
        app.launch()
        dismissPendingSystemAlert()
        return app
    }

    /// Dismiss a springboard permission alert if one is showing.
    static func dismissPendingSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don't Allow", "Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 4) {
                button.tap()
                return
            }
        }
    }
}
