//
//  IOSSidebarPage.swift
//  imbib-iOSUITests
//
//  Page object for the iOS sidebar column (IOSSidebarView + the
//  IOSContentView sidebar toolbar).
//

import XCTest

struct IOSSidebarPage {

    let app: XCUIApplication

    // MARK: - Elements

    /// The gear button in the sidebar toolbar that opens Settings.
    var settingsButton: XCUIElement {
        app.buttons[IOSA11y.Sidebar.settingsButton].firstMatch
    }

    /// The "New Library" button.
    var newLibraryButton: XCUIElement {
        app.buttons[IOSA11y.Sidebar.newLibraryButton].firstMatch
    }

    /// The seeded library row. Matched by the `sidebar.library.<uuid>`
    /// identifier prefix so the test doesn't need the runtime-assigned UUID.
    var seededLibraryRow: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.library."))
            .firstMatch
    }

    /// The seeded library, matched by its (known) display name — a fallback
    /// anchor if the row's own element isn't directly hittable.
    var seededLibraryText: XCUIElement {
        app.staticTexts[IOSSeed.libraryName].firstMatch
    }

    // MARK: - Waits

    @discardableResult
    func waitUntilLoaded(timeout: TimeInterval = 30) -> Bool {
        settingsButton.waitForExistence(timeout: timeout)
    }

    // MARK: - Actions

    func openSettings() {
        settingsButton.tap()
    }

    /// Select the seeded library so its publications appear in the content column.
    func openSeededLibrary() {
        if seededLibraryRow.waitForExistence(timeout: 15), seededLibraryRow.isHittable {
            seededLibraryRow.tap()
        } else if seededLibraryText.waitForExistence(timeout: 15) {
            seededLibraryText.tap()
        }
    }
}
