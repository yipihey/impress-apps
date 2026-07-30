//
//  IOSSidebarPage.swift
//  imbib-iOSUITests
//
//  Page object for the iOS sidebar column: PMC's shared `RecordSidebarView`
//  (Stage 5a) hosted by imbib-iOS/Views/IOSSidebarHost.swift, plus the
//  IOSContentView sidebar toolbar.
//
//  Row anchors are the chassis's own `sidebar.node.<scopeKey>` identifiers
//  (`RecordSidebarScope.scopeKey`), which is why the library row is matched by
//  the `host.publication.library.` prefix rather than the app-side
//  `sidebar.library.<uuid>` the deleted hand-written sidebar emitted.
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

    /// The seeded library row. Matched by the chassis's scope-key prefix so the
    /// test doesn't need the runtime-assigned UUID.
    var seededLibraryRow: XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "sidebar.node.host.publication.library."))
            .firstMatch
    }

    /// A section header's disclosure control (`sidebar.section.<rawValue>`).
    func sectionHeader(_ rawValue: String) -> XCUIElement {
        app.descendants(matching: .any)["sidebar.section.\(rawValue)"].firstMatch
    }

    /// A sidebar row, by its chassis scope key (`RecordSidebarScope.scopeKey`).
    func node(_ scopeKey: String) -> XCUIElement {
        app.descendants(matching: .any)["sidebar.node.\(scopeKey)"].firstMatch
    }

    /// Scroll DOWN the sidebar until `element` is hittable, or give up.
    ///
    /// The sidebar is a lazy `List`: with the seeded fixture the Search section
    /// alone is nine rows, so Flagged and everything after it are not in the
    /// accessibility tree until scrolled to.
    ///
    /// Deliberately one-directional: `swipeDown()` at the top of the list is
    /// PULL-TO-REFRESH, not scrolling, and a bidirectional search fired a dozen
    /// refreshes in seconds (now also guarded app-side in
    /// `IOSSidebarHost.refresh()`).
    @discardableResult
    func scrollTo(_ element: XCUIElement, attempts: Int = 8) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// Bring the Flagged section's rows into view (`gray` is the last one).
    func revealFlaggedSection() {
        scrollTo(node("publication.flagged.gray"))
    }

    /// A collection row, by display name. Collection rows are
    /// `sidebar.node.publication.folder.<uuid>`, so the name is the stable
    /// anchor for a fixture whose id is assigned at seed time.
    func collectionRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.node."))
            .matching(NSPredicate(format: "label CONTAINS[c] %@", name))
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

    /// The Flagged row for `color`. Call `revealFlaggedSection()` first.
    func flagRow(_ color: String) -> XCUIElement {
        node("publication.flagged.\(color)")
    }
}
