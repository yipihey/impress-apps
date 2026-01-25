//
//  SidebarPage.swift
//  imbibUITests
//
//  Page Object for the sidebar navigation.
//

import XCTest

/// Page Object for the sidebar navigation view.
///
/// Provides access to sidebar elements and common navigation actions.
struct SidebarPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// The sidebar outline view (List in SwiftUI)
    var sidebar: XCUIElement {
        // SwiftUI List renders as an outline on macOS
        app.outlines.firstMatch
    }

    /// The Inbox section header - look for "Inbox" text in sidebar
    var inboxRow: XCUIElement {
        // Try multiple approaches to find Inbox
        let byText = sidebar.staticTexts["Inbox"]
        if byText.exists { return byText }
        // Also try cells containing Inbox
        return sidebar.cells.containing(.staticText, identifier: "Inbox").firstMatch
    }

    /// The All Publications row - first "All Publications" text found
    var allPublicationsRow: XCUIElement {
        sidebar.staticTexts["All Publications"].firstMatch
    }

    /// The Search section - look for "Search" section header
    var searchSourcesRow: XCUIElement {
        // The section might be called "Search" not "Search Sources"
        let search = sidebar.staticTexts["Search"]
        if search.exists { return search }
        return sidebar.staticTexts["Search Sources"].firstMatch
    }

    /// All library rows
    var libraryRows: XCUIElementQuery {
        sidebar.cells
    }

    /// All collection rows
    var collectionRows: XCUIElementQuery {
        sidebar.cells
    }

    // MARK: - Wait Methods

    /// Wait for the sidebar to be visible and ready
    @discardableResult
    func waitForSidebar(timeout: TimeInterval = 5) -> Bool {
        sidebar.waitForExistence(timeout: timeout)
    }

    // MARK: - Navigation Actions

    /// Select the Inbox
    func selectInbox() {
        // Try to find and click Inbox
        let inbox = sidebar.staticTexts["Inbox"]
        if inbox.waitForExistence(timeout: 2) {
            inbox.click()
        } else {
            // Try clicking the first cell that contains "Inbox"
            let inboxCell = sidebar.cells.containing(.staticText, identifier: "Inbox").firstMatch
            inboxCell.click()
        }
    }

    /// Select All Publications (first library's All Publications)
    func selectAllPublications() {
        let allPubs = sidebar.staticTexts["All Publications"].firstMatch
        if allPubs.waitForExistence(timeout: 2) {
            allPubs.click()
        }
    }

    /// Select Search Sources / Search section
    func selectSearchSources() {
        // Try "Search" first, then "Search Sources"
        let search = sidebar.staticTexts["Search"]
        if search.waitForExistence(timeout: 2) {
            search.click()
        } else {
            let searchSources = sidebar.staticTexts["Search Sources"]
            if searchSources.waitForExistence(timeout: 2) {
                searchSources.click()
            }
        }
    }

    /// Select a library by name
    func selectLibrary(named name: String) {
        let libraryCell = sidebar.staticTexts[name]
        if libraryCell.waitForExistence(timeout: 2) {
            libraryCell.click()
        }
    }

    /// Select a collection by name
    func selectCollection(named name: String) {
        let collectionCell = sidebar.staticTexts[name]
        if collectionCell.waitForExistence(timeout: 2) {
            collectionCell.click()
        }
    }

    /// Select a smart search by name
    func selectSmartSearch(named name: String) {
        let searchCell = sidebar.staticTexts[name]
        if searchCell.waitForExistence(timeout: 2) {
            searchCell.click()
        }
    }

    // MARK: - Library Management

    /// Create a new library using the context menu
    func createNewLibrary() -> LibraryCreationSheet {
        // Right-click to open context menu
        sidebar.rightClick()

        // Click "New Library" menu item
        app.menuItems["New Library..."].click()

        return LibraryCreationSheet(app: app)
    }

    /// Create a new collection using the context menu
    func createNewCollection() -> CollectionCreationSheet {
        // Right-click to open context menu
        sidebar.rightClick()

        // Click "New Collection" menu item
        app.menuItems["New Collection..."].click()

        return CollectionCreationSheet(app: app)
    }

    /// Delete a library by name via context menu
    func deleteLibrary(named name: String) {
        let libraryCell = sidebar.staticTexts[name]
        libraryCell.rightClick()
        app.menuItems["Delete Library"].click()

        // Confirm deletion if alert appears
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 1) {
            deleteButton.click()
        }
    }

    /// Rename a library by name via context menu
    func renameLibrary(named oldName: String, to newName: String) {
        let libraryCell = sidebar.staticTexts[oldName]
        libraryCell.rightClick()
        app.menuItems["Rename..."].click()

        // Type the new name
        let textField = app.textFields.firstMatch
        textField.click()
        textField.typeKey("a", modifierFlags: .command) // Select all
        textField.typeText(newName)
        textField.typeKey(.return, modifierFlags: [])
    }

    // MARK: - Drag and Drop

    /// Drag a file URL to a library in the sidebar
    func dragFile(_ fileURL: URL, toLibrary libraryName: String) {
        // Note: XCUITest drag and drop is limited
        // This would require NSPasteboard manipulation in a real implementation
        let libraryCell = sidebar.staticTexts[libraryName]

        // For now, this serves as a placeholder for the drag action
        // In practice, you might need to use AppleScript or other techniques
        _ = libraryCell.waitForExistence(timeout: 2)
    }

    // MARK: - Assertions

    /// Assert that a library exists in the sidebar
    func assertLibraryExists(_ name: String, file: StaticString = #file, line: UInt = #line) {
        let libraryCell = sidebar.staticTexts[name]
        XCTAssertTrue(
            libraryCell.waitForExistence(timeout: 2),
            "Library '\(name)' should exist in sidebar",
            file: file,
            line: line
        )
    }

    /// Assert that a library does not exist in the sidebar
    func assertLibraryNotExists(_ name: String, file: StaticString = #file, line: UInt = #line) {
        let libraryCell = sidebar.staticTexts[name]
        XCTAssertFalse(
            libraryCell.exists,
            "Library '\(name)' should not exist in sidebar",
            file: file,
            line: line
        )
    }

    /// Assert that the inbox has a specific badge count
    func assertInboxBadge(_ count: Int, file: StaticString = #file, line: UInt = #line) {
        // Badge count is typically shown as a static text within the cell
        if count > 0 {
            let badgeText = inboxRow.staticTexts["\(count)"]
            XCTAssertTrue(
                badgeText.exists,
                "Inbox should show badge count of \(count)",
                file: file,
                line: line
            )
        }
    }

    /// Assert that a collection exists under a library
    func assertCollectionExists(_ collectionName: String, inLibrary libraryName: String, file: StaticString = #file, line: UInt = #line) {
        // First expand the library if needed
        selectLibrary(named: libraryName)

        let collectionCell = sidebar.staticTexts[collectionName]
        XCTAssertTrue(
            collectionCell.waitForExistence(timeout: 2),
            "Collection '\(collectionName)' should exist under '\(libraryName)'",
            file: file,
            line: line
        )
    }
}

// MARK: - Library Creation Sheet

/// Sheet for creating a new library.
struct LibraryCreationSheet {

    let app: XCUIApplication

    var sheet: XCUIElement {
        app.sheets.firstMatch
    }

    var nameTextField: XCUIElement {
        sheet.textFields["Library Name"]
    }

    var createButton: XCUIElement {
        sheet.buttons["Create"]
    }

    var cancelButton: XCUIElement {
        sheet.buttons["Cancel"]
    }

    /// Enter library details and create
    func create(name: String) {
        nameTextField.click()
        nameTextField.typeText(name)
        createButton.click()
    }

    /// Cancel library creation
    func cancel() {
        cancelButton.click()
    }
}

// MARK: - Collection Creation Sheet

/// Sheet for creating a new collection.
struct CollectionCreationSheet {

    let app: XCUIApplication

    var sheet: XCUIElement {
        app.sheets.firstMatch
    }

    var nameTextField: XCUIElement {
        sheet.textFields["Collection Name"]
    }

    var createButton: XCUIElement {
        sheet.buttons["Create"]
    }

    var cancelButton: XCUIElement {
        sheet.buttons["Cancel"]
    }

    /// Enter collection details and create
    func create(name: String) {
        nameTextField.click()
        nameTextField.typeText(name)
        createButton.click()
    }

    /// Cancel collection creation
    func cancel() {
        cancelButton.click()
    }
}
