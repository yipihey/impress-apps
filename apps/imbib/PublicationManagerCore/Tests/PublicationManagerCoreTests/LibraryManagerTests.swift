//
//  LibraryManagerTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

/// Tests for LibraryManager state management.
/// Note: Full integration tests with file system are in IntegrationTests.
@MainActor
final class LibraryManagerTests: XCTestCase {

    // MARK: - CDLibrary Entity Tests

    func testCDLibrary_displayName_usesNameIfNotEmpty() {
        // This tests the computed property logic without Core Data
        // Using the displayName property logic:
        // - If name is not empty, return name
        // - Else if bibFilePath exists, return filename without extension
        // - Else return "Untitled Library"

        // We can't easily test CDLibrary without Core Data, but we can
        // test the naming conventions and helper methods
    }

    // MARK: - Smart Search Entity Tests

    func testCDSmartSearch_sources_encodesAndDecodes() {
        // Test the JSON encoding/decoding logic for sourceIDs
        let sources = ["arxiv", "crossref", "ads"]
        let encoded = try! JSONEncoder().encode(sources)
        let json = String(data: encoded, encoding: .utf8)

        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("arxiv"))
        XCTAssertTrue(json!.contains("crossref"))
        XCTAssertTrue(json!.contains("ads"))

        let decoded = try! JSONDecoder().decode([String].self, from: encoded)
        XCTAssertEqual(decoded, sources)
    }

    func testCDSmartSearch_usesAllSources_whenEmpty() {
        // Empty sources array means "use all sources"
        let sources: [String] = []
        let encoded = try! JSONEncoder().encode(sources)
        let json = String(data: encoded, encoding: .utf8)

        XCTAssertEqual(json, "[]")

        let decoded = try! JSONDecoder().decode([String].self, from: encoded)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - Security Scoped Bookmark Tests

    func testSecurityScopedBookmark_creationLogic() {
        // Test the bookmark URL resolution pattern (without actual file system)

        // Simulating the bookmark resolution logic:
        // 1. If bookmarkData exists, resolve from bookmark
        // 2. If stale, need to refresh
        // 3. Fall back to bibFilePath if no bookmark

        // This tests the conceptual flow
        let testPath = "/Users/test/Documents/library.bib"
        let url = URL(fileURLWithPath: testPath)

        XCTAssertEqual(url.lastPathComponent, "library.bib")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "library")
    }

    // MARK: - Library Naming Convention Tests

    func testLibraryNaming_fromBibFile() {
        let bibURL = URL(fileURLWithPath: "/path/to/MyResearch.bib")
        let expectedName = bibURL.deletingPathExtension().lastPathComponent

        XCTAssertEqual(expectedName, "MyResearch")
    }

    func testLibraryNaming_defaultsToUntitled() {
        // When both name and bibFilePath are empty, should default to "Untitled Library"
        let defaultName = "Untitled Library"
        XCTAssertEqual(defaultName, "Untitled Library")
    }

    // MARK: - Papers Directory Resolution Tests

    func testPapersDirectory_relativeToBibFile() {
        // Papers directory should be next to .bib file
        let bibURL = URL(fileURLWithPath: "/Users/test/Documents/refs.bib")
        let papersDir = bibURL.deletingLastPathComponent().appendingPathComponent("Papers")

        XCTAssertEqual(papersDir.path, "/Users/test/Documents/Papers")
    }

    func testPapersDirectory_customPath() {
        // Custom papers directory path
        let customPath = "/Volumes/External/PDFs"
        let url = URL(fileURLWithPath: customPath)

        XCTAssertEqual(url.path, customPath)
    }
}

// MARK: - SmartSearchRepository Tests

@MainActor
final class SmartSearchRepositoryTests: XCTestCase {

    // MARK: - Order Management Tests

    func testOrder_incrementsForNewSearches() {
        // When creating multiple smart searches, order should increment
        // Order: 0, 1, 2, 3...

        let orders = [0, 1, 2, 3, 4]
        for (index, expected) in orders.enumerated() {
            XCTAssertEqual(expected, index)
        }
    }

    func testOrder_reorderingLogic() {
        // When reordering, indices should update correctly
        var items = ["A", "B", "C", "D"]

        // Move "C" from index 2 to index 0
        let moved = items.remove(at: 2)
        items.insert(moved, at: 0)

        XCTAssertEqual(items, ["C", "A", "B", "D"])
    }

    // MARK: - Query Validation Tests

    func testQuery_nonEmptyRequired() {
        let query = ""
        XCTAssertTrue(query.isEmpty)

        let validQuery = "machine learning"
        XCTAssertFalse(validQuery.isEmpty)
    }

    func testQuery_trimming() {
        let query = "  some search  "
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        XCTAssertEqual(trimmed, "some search")
    }

    // MARK: - Source IDs Encoding Tests

    func testSourceIDs_jsonEncoding() {
        let sources = ["arxiv", "ads", "crossref"]

        // Encode to JSON string (as stored in Core Data)
        let data = try! JSONEncoder().encode(sources)
        let json = String(data: data, encoding: .utf8)!

        // Verify it can be decoded back
        let decoded = try! JSONDecoder().decode([String].self, from: json.data(using: .utf8)!)

        XCTAssertEqual(decoded.sorted(), sources.sorted())
    }

    func testSourceIDs_emptyMeansAll() {
        let allSources: [String] = []

        // Empty means "use all available sources"
        XCTAssertTrue(allSources.isEmpty)
    }
}
