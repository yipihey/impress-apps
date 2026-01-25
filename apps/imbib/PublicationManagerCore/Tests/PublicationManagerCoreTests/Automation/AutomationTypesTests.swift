//
//  AutomationTypesTests.swift
//  PublicationManagerCoreTests
//
//  Tests for AutomationTypes (ADR-018).
//

import XCTest
@testable import PublicationManagerCore

final class AutomationTypesTests: XCTestCase {

    // MARK: - PaperIdentifier Tests

    func testPaperIdentifier_fromString_detectsDOI() {
        // Standard DOI
        let doi1 = PaperIdentifier.fromString("10.1038/nature12373")
        XCTAssertEqual(doi1, .doi("10.1038/nature12373"))

        // DOI with prefix
        let doi2 = PaperIdentifier.fromString("doi:10.1038/nature12373")
        XCTAssertEqual(doi2, .doi("10.1038/nature12373"))
    }

    func testPaperIdentifier_fromString_detectsArXiv() {
        // New format
        let arxiv1 = PaperIdentifier.fromString("2301.12345")
        XCTAssertEqual(arxiv1, .arxiv("2301.12345"))

        // New format with version
        let arxiv2 = PaperIdentifier.fromString("2301.12345v2")
        XCTAssertEqual(arxiv2, .arxiv("2301.12345v2"))

        // Old format
        let arxiv3 = PaperIdentifier.fromString("hep-th/9901001")
        XCTAssertEqual(arxiv3, .arxiv("hep-th/9901001"))
    }

    func testPaperIdentifier_fromString_detectsBibcode() {
        // Standard 19-char bibcode
        let bibcode = PaperIdentifier.fromString("2023ApJ...950L..22A")
        XCTAssertEqual(bibcode, .bibcode("2023ApJ...950L..22A"))
    }

    func testPaperIdentifier_fromString_detectsUUID() {
        let uuidString = "550E8400-E29B-41D4-A716-446655440000"
        let id = PaperIdentifier.fromString(uuidString)
        if case .uuid(let uuid) = id {
            XCTAssertEqual(uuid.uuidString.uppercased(), uuidString)
        } else {
            XCTFail("Expected UUID identifier")
        }
    }

    func testPaperIdentifier_fromString_defaultsToCiteKey() {
        // Any unrecognized string becomes a cite key
        let citeKey = PaperIdentifier.fromString("Einstein1905Photoelectric")
        XCTAssertEqual(citeKey, .citeKey("Einstein1905Photoelectric"))
    }

    func testPaperIdentifier_value_returnsCorrectString() {
        XCTAssertEqual(PaperIdentifier.citeKey("test").value, "test")
        XCTAssertEqual(PaperIdentifier.doi("10.1234/test").value, "10.1234/test")
        XCTAssertEqual(PaperIdentifier.arxiv("2301.12345").value, "2301.12345")
        XCTAssertEqual(PaperIdentifier.bibcode("2023ApJ...950L..22A").value, "2023ApJ...950L..22A")
    }

    func testPaperIdentifier_typeName_returnsCorrectName() {
        XCTAssertEqual(PaperIdentifier.citeKey("test").typeName, "citeKey")
        XCTAssertEqual(PaperIdentifier.doi("10.1234/test").typeName, "doi")
        XCTAssertEqual(PaperIdentifier.arxiv("2301.12345").typeName, "arXiv")
        XCTAssertEqual(PaperIdentifier.bibcode("code").typeName, "bibcode")
        XCTAssertEqual(PaperIdentifier.uuid(UUID()).typeName, "uuid")
        XCTAssertEqual(PaperIdentifier.pmid("12345678").typeName, "pmid")
        XCTAssertEqual(PaperIdentifier.semanticScholar("abc").typeName, "semanticScholar")
        XCTAssertEqual(PaperIdentifier.openAlex("W123").typeName, "openAlex")
    }

    func testPaperIdentifier_fromString_detectsPMID() {
        // Numeric string that looks like PMID
        let pmid = PaperIdentifier.fromString("12345678")
        XCTAssertEqual(pmid, .pmid("12345678"))
    }

    func testPaperIdentifier_fromString_detectsOpenAlex() {
        let openAlex = PaperIdentifier.fromString("W1234567890")
        XCTAssertEqual(openAlex, .openAlex("W1234567890"))
    }

    func testPaperIdentifier_codable() throws {
        let original = PaperIdentifier.doi("10.1038/nature12373")

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PaperIdentifier.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - SearchFilters Tests

    func testSearchFilters_initialization() {
        let filters = SearchFilters(
            yearFrom: 2020,
            yearTo: 2024,
            isRead: false,
            limit: 50
        )

        XCTAssertEqual(filters.yearFrom, 2020)
        XCTAssertEqual(filters.yearTo, 2024)
        XCTAssertEqual(filters.isRead, false)
        XCTAssertEqual(filters.limit, 50)
    }

    func testSearchFilters_codable() throws {
        let original = SearchFilters(
            yearFrom: 2020,
            authors: ["Einstein", "Bohr"],
            isRead: true,
            limit: 100
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SearchFilters.self, from: data)

        XCTAssertEqual(decoded.yearFrom, 2020)
        XCTAssertEqual(decoded.authors, ["Einstein", "Bohr"])
        XCTAssertEqual(decoded.isRead, true)
        XCTAssertEqual(decoded.limit, 100)
    }

    // MARK: - PaperResult Tests

    func testPaperResult_initialization() {
        let id = UUID()
        let result = PaperResult(
            id: id,
            citeKey: "Einstein1905",
            title: "Test Paper",
            authors: ["Einstein, A.", "Bohr, N."],
            year: 1905
        )

        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.citeKey, "Einstein1905")
        XCTAssertEqual(result.title, "Test Paper")
        XCTAssertEqual(result.authors.count, 2)
        XCTAssertEqual(result.year, 1905)
    }

    func testPaperResult_firstAuthorLastName_lastFirst() {
        let result = PaperResult(
            id: UUID(),
            citeKey: "test",
            title: "Test",
            authors: ["Einstein, Albert"]
        )

        XCTAssertEqual(result.firstAuthorLastName, "Einstein")
    }

    func testPaperResult_firstAuthorLastName_firstLast() {
        let result = PaperResult(
            id: UUID(),
            citeKey: "test",
            title: "Test",
            authors: ["Albert Einstein"]
        )

        XCTAssertEqual(result.firstAuthorLastName, "Einstein")
    }

    func testPaperResult_codable() throws {
        let original = PaperResult(
            id: UUID(),
            citeKey: "Test2024",
            title: "Test Paper",
            authors: ["Author One"],
            year: 2024,
            doi: "10.1234/test"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PaperResult.self, from: data)

        XCTAssertEqual(decoded.citeKey, "Test2024")
        XCTAssertEqual(decoded.title, "Test Paper")
        XCTAssertEqual(decoded.doi, "10.1234/test")
    }

    // MARK: - CollectionResult Tests

    func testCollectionResult_initialization() {
        let id = UUID()
        let result = CollectionResult(
            id: id,
            name: "My Collection",
            paperCount: 42,
            isSmartCollection: true
        )

        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.name, "My Collection")
        XCTAssertEqual(result.paperCount, 42)
        XCTAssertTrue(result.isSmartCollection)
    }

    // MARK: - AddPapersResult Tests

    func testAddPapersResult_totalProcessed() {
        let result = AddPapersResult(
            added: [
                PaperResult(id: UUID(), citeKey: "test1", title: "Test 1", authors: []),
                PaperResult(id: UUID(), citeKey: "test2", title: "Test 2", authors: [])
            ],
            duplicates: ["dup1"],
            failed: ["fail1": "Error"]
        )

        XCTAssertEqual(result.totalProcessed, 4)
    }

    func testAddPapersResult_allSucceeded_true() {
        let result = AddPapersResult(
            added: [PaperResult(id: UUID(), citeKey: "test", title: "Test", authors: [])],
            duplicates: [],
            failed: [:]
        )

        XCTAssertTrue(result.allSucceeded)
    }

    func testAddPapersResult_allSucceeded_false() {
        let result = AddPapersResult(
            added: [],
            duplicates: [],
            failed: ["test": "Error"]
        )

        XCTAssertFalse(result.allSucceeded)
    }

    // MARK: - DownloadResult Tests

    func testDownloadResult_totalProcessed() {
        let result = DownloadResult(
            downloaded: ["key1", "key2"],
            alreadyHad: ["key3"],
            failed: ["key4": "Error"]
        )

        XCTAssertEqual(result.totalProcessed, 4)
    }

    // MARK: - AutomationOperationError Tests

    func testAutomationOperationError_localizedDescription() {
        let paperNotFound = AutomationOperationError.paperNotFound("test123")
        XCTAssertTrue(paperNotFound.localizedDescription.contains("test123"))

        let collectionNotFound = AutomationOperationError.collectionNotFound(UUID())
        XCTAssertTrue(collectionNotFound.localizedDescription.contains("Collection not found"))

        let unauthorized = AutomationOperationError.unauthorized
        XCTAssertTrue(unauthorized.localizedDescription.contains("disabled"))
    }
}
