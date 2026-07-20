//
//  IOSSettingsPage.swift
//  imbib-iOSUITests
//
//  Page object for the IOSSettingsView sheet.
//

import XCTest

struct IOSSettingsPage {

    let app: XCUIApplication

    /// The "API Keys" row (carries the `settings.tabs.sources` id) — a stable
    /// marker that the settings sheet rendered.
    var sourcesRow: XCUIElement {
        app.descendants(matching: .any)[IOSA11y.Settings.sourcesTab].firstMatch
    }

    var doneButton: XCUIElement {
        app.buttons[IOSA11y.Settings.doneButton].firstMatch
    }

    @discardableResult
    func waitForSheet(timeout: TimeInterval = 10) -> Bool {
        sourcesRow.waitForExistence(timeout: timeout)
    }

    func dismiss() {
        if doneButton.exists {
            doneButton.tap()
        }
    }
}
