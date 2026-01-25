//
//  LibraryViewModelTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

/// Tests for LibraryViewModel selection and state management.
/// Note: Integration tests with actual Core Data are in IntegrationTests.
@MainActor
final class LibraryViewModelTests: XCTestCase {

    // MARK: - Sort Order Tests

    func testLibrarySortOrder_displayNames() {
        XCTAssertEqual(LibrarySortOrder.dateAdded.displayName, "Date Added")
        XCTAssertEqual(LibrarySortOrder.dateModified.displayName, "Date Modified")
        XCTAssertEqual(LibrarySortOrder.title.displayName, "Title")
        XCTAssertEqual(LibrarySortOrder.year.displayName, "Year")
        XCTAssertEqual(LibrarySortOrder.citeKey.displayName, "Cite Key")
        XCTAssertEqual(LibrarySortOrder.citationCount.displayName, "Citation Count")
    }

    func testLibrarySortOrder_sortKeys() {
        XCTAssertEqual(LibrarySortOrder.dateAdded.sortKey, "dateAdded")
        XCTAssertEqual(LibrarySortOrder.dateModified.sortKey, "dateModified")
        XCTAssertEqual(LibrarySortOrder.title.sortKey, "title")
        XCTAssertEqual(LibrarySortOrder.year.sortKey, "year")
        XCTAssertEqual(LibrarySortOrder.citeKey.sortKey, "citeKey")
        XCTAssertEqual(LibrarySortOrder.citationCount.sortKey, "citationCount")
    }

    func testLibrarySortOrder_allCases() {
        XCTAssertEqual(LibrarySortOrder.allCases.count, 6)
    }

    func testLibrarySortOrder_identifiable() {
        let order = LibrarySortOrder.title
        XCTAssertEqual(order.id, "title")
    }

    // MARK: - Initial State Tests

    func testViewModel_initialState() {
        let viewModel = LibraryViewModel()

        XCTAssertTrue(viewModel.publications.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
        XCTAssertEqual(viewModel.searchQuery, "")
        XCTAssertEqual(viewModel.sortOrder, .dateAdded)
        XCTAssertFalse(viewModel.sortAscending)
        XCTAssertTrue(viewModel.selectedPublications.isEmpty)
    }

    // MARK: - Selection State Tests

    func testSelectionState_clearSelection_emptiesSet() {
        let viewModel = LibraryViewModel()
        let testID = UUID()
        viewModel.selectedPublications.insert(testID)

        viewModel.clearSelection()

        XCTAssertTrue(viewModel.selectedPublications.isEmpty)
    }

    func testSelectionState_multipleInserts() {
        let viewModel = LibraryViewModel()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        viewModel.selectedPublications.insert(id1)
        viewModel.selectedPublications.insert(id2)
        viewModel.selectedPublications.insert(id3)

        XCTAssertEqual(viewModel.selectedPublications.count, 3)
        XCTAssertTrue(viewModel.selectedPublications.contains(id1))
        XCTAssertTrue(viewModel.selectedPublications.contains(id2))
        XCTAssertTrue(viewModel.selectedPublications.contains(id3))
    }

    func testSelectionState_removeWorks() {
        let viewModel = LibraryViewModel()
        let testID = UUID()
        viewModel.selectedPublications.insert(testID)

        viewModel.selectedPublications.remove(testID)

        XCTAssertFalse(viewModel.selectedPublications.contains(testID))
    }

    // MARK: - Property Change Tests

    func testSearchQuery_canBeSet() {
        let viewModel = LibraryViewModel()

        viewModel.searchQuery = "quantum"

        XCTAssertEqual(viewModel.searchQuery, "quantum")
    }

    func testSortOrder_canBeChanged() {
        let viewModel = LibraryViewModel()

        viewModel.sortOrder = .year

        XCTAssertEqual(viewModel.sortOrder, .year)
    }

    func testSortAscending_canBeToggled() {
        let viewModel = LibraryViewModel()
        XCTAssertFalse(viewModel.sortAscending)

        viewModel.sortAscending = true

        XCTAssertTrue(viewModel.sortAscending)
    }
}
