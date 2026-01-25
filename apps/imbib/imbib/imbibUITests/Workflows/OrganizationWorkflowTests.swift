//
//  OrganizationWorkflowTests.swift
//  imbibUITests
//
//  End-to-end tests for organization workflows (libraries, collections).
//

import XCTest

/// Tests for organizing publications into libraries and collections.
final class OrganizationWorkflowTests: XCTestCase {

    var app: XCUIApplication!
    var sidebar: SidebarPage!
    var list: PublicationListPage!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = TestApp.launch(with: .multiLibrary)
        sidebar = SidebarPage(app: app)
        list = PublicationListPage(app: app)

        _ = sidebar.waitForSidebar()
    }

    // MARK: - Library Management Tests

    /// Test creating a new library
    func testCreateNewLibrary() throws {
        // When: I create a new library
        let sheet = sidebar.createNewLibrary()
        sheet.create(name: "New Test Library")

        // Then: The library should appear in the sidebar
        sidebar.assertLibraryExists("New Test Library")
    }

    /// Test renaming a library
    func testRenameLibrary() throws {
        // Given: A library exists
        sidebar.assertLibraryExists("Physics")

        // When: I rename it
        sidebar.renameLibrary(named: "Physics", to: "Physics Papers")

        // Then: The new name should appear
        sidebar.assertLibraryExists("Physics Papers")
        sidebar.assertLibraryNotExists("Physics")
    }

    /// Test deleting a library
    func testDeleteLibrary() throws {
        // Given: A library exists
        sidebar.assertLibraryExists("Mathematics")

        // When: I delete it
        sidebar.deleteLibrary(named: "Mathematics")

        // Then: The library should be removed
        sidebar.assertLibraryNotExists("Mathematics")
    }

    // MARK: - Collection Management Tests

    /// Test creating a new collection
    func testCreateNewCollection() throws {
        // Given: A library is selected
        sidebar.selectLibrary(named: "Physics")

        // When: I create a new collection
        let sheet = sidebar.createNewCollection()
        sheet.create(name: "Quantum Mechanics")

        // Then: The collection should appear
        sidebar.assertCollectionExists("Quantum Mechanics", inLibrary: "Physics")
    }

    /// Test moving publications to a collection
    func testMovePublicationToCollection() throws {
        // Given: Publications exist and a collection exists
        sidebar.selectLibrary(named: "Physics")
        _ = list.waitForPublications()
        list.selectFirst()

        // When: I use Cmd+L to add to collection
        app.typeKey("l", modifierFlags: .command)

        // Then: A collection picker should appear
        let picker = app.sheets.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 2), "Collection picker should appear")

        // Cancel for now
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Test removing publication from collection
    func testRemovePublicationFromCollection() throws {
        // Given: A publication is in a collection
        sidebar.selectCollection(named: "Important Physics")
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        XCTAssertGreaterThan(initialCount, 0, "Collection should have publications")

        list.selectFirst()

        // When: I remove from collection (Cmd+Shift+L)
        app.typeKey("l", modifierFlags: [.command, .shift])

        // Then: The publication should be removed from the collection
        list.assertPublicationCount(initialCount - 1)
    }

    // MARK: - Smart Collection Tests

    /// Test creating a smart collection
    func testCreateSmartCollection() throws {
        // Given: I'm in a library
        sidebar.selectLibrary(named: "Physics")

        // When: I create a smart collection via menu
        // (This would need menu navigation)

        // Then: A configuration sheet should appear
    }

    /// Test smart collection updates automatically
    func testSmartCollectionAutoUpdates() throws {
        // Given: A smart collection filtering by year exists

        // When: A new publication matching the criteria is added

        // Then: The smart collection should include the new publication
    }

    // MARK: - Drag and Drop Organization Tests

    /// Test dragging publication between libraries
    func testDragPublicationBetweenLibraries() throws {
        // Given: Publications exist in one library
        sidebar.selectLibrary(named: "Physics")
        _ = list.waitForPublications()

        // When: I drag a publication to another library
        // (XCUITest drag-and-drop is limited)

        // Then: The publication should be in the target library
    }

    /// Test dragging publication to collection
    func testDragPublicationToCollection() throws {
        // Given: Publications and collections exist

        // When: I drag a publication to a collection

        // Then: It should be added to the collection
    }

    // MARK: - Copy/Paste Organization Tests

    /// Test copying publications between libraries
    func testCopyPublicationsBetweenLibraries() throws {
        // Given: Publications exist in Physics library
        sidebar.selectLibrary(named: "Physics")
        _ = list.waitForPublications()
        list.selectFirst()

        // Copy
        list.copySelected()

        // Switch to Computer Science library
        sidebar.selectLibrary(named: "Computer Science")
        let initialCount = list.rows.count

        // When: I paste
        list.paste()

        // Then: The publication should be added
        list.assertPublicationCount(greaterThan: initialCount)
    }

    // MARK: - Bulk Organization Tests

    /// Test moving multiple publications at once
    func testBulkMovePublications() throws {
        // Given: Multiple publications are selected
        sidebar.selectLibrary(named: "Physics")
        _ = list.waitForPublications()
        list.selectAll()

        // When: I move them to a collection
        app.typeKey("l", modifierFlags: .command)

        let picker = app.sheets.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 2), "Picker should appear for bulk move")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Delete Tests

    /// Test deleting a publication
    func testDeletePublication() throws {
        // Given: A publication is selected
        sidebar.selectLibrary(named: "Physics")
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        list.selectFirst()

        // When: I delete it
        list.deleteSelected()

        // Confirm deletion if dialog appears
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 1) {
            deleteButton.click()
        }

        // Then: The publication should be removed
        list.assertPublicationCount(initialCount - 1)
    }

    /// Test bulk delete publications
    func testBulkDeletePublications() throws {
        // Given: Multiple publications are selected
        sidebar.selectLibrary(named: "Physics")
        _ = list.waitForPublications()

        let initialCount = list.rows.count
        XCTAssertGreaterThan(initialCount, 2, "Need multiple publications")

        list.selectPublication(at: 0)
        list.selectPublication(at: 1) // Would need shift-click

        // When: I delete them
        list.deleteSelected()

        // Confirm deletion
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 1) {
            deleteButton.click()
        }

        // Then: Publications should be removed
        list.assertPublicationCount(lessThan: initialCount)
    }

    // MARK: - Sort Tests

    /// Test sorting publications by different criteria
    func testSortPublications() throws {
        // Given: Publications are displayed
        sidebar.selectLibrary(named: "Physics")
        _ = list.waitForPublications()

        // When: I change the sort order via toolbar menu
        // (Would need to access sort menu)

        // Then: Publications should be reordered
    }
}

// MARK: - Helper Extensions

extension PublicationListPage {
    func assertPublicationCount(lessThan count: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertLessThan(
            rows.count,
            count,
            "Expected fewer than \(count) publications, found \(rows.count)",
            file: file,
            line: line
        )
    }
}
