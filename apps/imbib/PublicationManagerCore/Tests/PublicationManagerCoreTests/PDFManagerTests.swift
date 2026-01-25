//
//  PDFManagerTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class PDFManagerTests: XCTestCase {

    var pdfManager: PDFManager!
    var tempDirectory: URL!

    @MainActor
    override func setUp() {
        super.setUp()

        // Create a temp directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Use preview persistence controller to avoid Core Data entity conflicts in tests
        pdfManager = PDFManager(persistenceController: .preview)
    }

    override func tearDown() {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Filename Generation Tests

    @MainActor
    func testGenerateFilename_withAuthorAndYear() {
        // Given
        let entry = BibTeXEntry(
            citeKey: "Einstein1905",
            entryType: "article",
            fields: [
                "author": "Albert Einstein",
                "year": "1905",
                "title": "On the Electrodynamics of Moving Bodies"
            ]
        )

        // When
        let filename = pdfManager.generateFilename(from: entry)

        // Then
        XCTAssertEqual(filename, "Einstein_1905_OnTheElectrodynamicsOfMovingBodies.pdf")
    }

    @MainActor
    func testGenerateFilename_withMultipleAuthors() {
        // Given - BibTeX format uses "and" to separate authors
        let entry = BibTeXEntry(
            citeKey: "Watson1953",
            entryType: "article",
            fields: [
                "author": "James D. Watson and Francis H. C. Crick",
                "year": "1953",
                "title": "Molecular Structure of Nucleic Acids"
            ]
        )

        // When
        let filename = pdfManager.generateFilename(from: entry)

        // Then - Should use first author only
        XCTAssertEqual(filename, "Watson_1953_MolecularStructureOfNucleicAcids.pdf")
    }

    @MainActor
    func testGenerateFilename_withLastFirstFormat() {
        // Given - "Last, First" format
        let entry = BibTeXEntry(
            citeKey: "Feynman1948",
            entryType: "article",
            fields: [
                "author": "Feynman, Richard P.",
                "year": "1948",
                "title": "Space-Time Approach to Quantum Electrodynamics"
            ]
        )

        // When
        let filename = pdfManager.generateFilename(from: entry)

        // Then - Title is truncated to ~40 chars
        XCTAssertTrue(filename.hasPrefix("Feynman_1948_SpaceTime"))
        XCTAssertTrue(filename.hasSuffix(".pdf"))
    }

    @MainActor
    func testGenerateFilename_withNoAuthor() {
        // Given
        let entry = BibTeXEntry(
            citeKey: "Anonymous2020",
            entryType: "article",
            fields: [
                "year": "2020",
                "title": "Some Anonymous Paper"
            ]
        )

        // When
        let filename = pdfManager.generateFilename(from: entry)

        // Then
        XCTAssertEqual(filename, "Unknown_2020_SomeAnonymousPaper.pdf")
    }

    @MainActor
    func testGenerateFilename_withNoYear() {
        // Given
        let entry = BibTeXEntry(
            citeKey: "Smith",
            entryType: "article",
            fields: [
                "author": "John Smith",
                "title": "A Paper Without Year"
            ]
        )

        // When
        let filename = pdfManager.generateFilename(from: entry)

        // Then - "A " is removed as leading article
        XCTAssertEqual(filename, "Smith_NoYear_PaperWithoutYear.pdf")
    }

    @MainActor
    func testGenerateFilename_removesLeadingArticles() {
        // Given - Title with leading article
        let entry = BibTeXEntry(
            citeKey: "Test2020",
            entryType: "article",
            fields: [
                "author": "Test Author",
                "year": "2020",
                "title": "The Quick Brown Fox"
            ]
        )

        // When
        let filename = pdfManager.generateFilename(from: entry)

        // Then - "The " should be removed
        XCTAssertEqual(filename, "Author_2020_QuickBrownFox.pdf")
    }

    @MainActor
    func testGenerateFilename_truncatesLongTitles() {
        // Given - Very long title
        let entry = BibTeXEntry(
            citeKey: "Long2020",
            entryType: "article",
            fields: [
                "author": "Long Author",
                "year": "2020",
                "title": "A Very Long Title That Should Be Truncated Because It Exceeds The Maximum Length Allowed For Filenames In Our System"
            ]
        )

        // When
        let filename = pdfManager.generateFilename(from: entry)

        // Then - Should be truncated to ~40 chars of title
        XCTAssertTrue(filename.count < 100, "Filename should be reasonably short")
        XCTAssertTrue(filename.hasPrefix("Author_2020_"))
        XCTAssertTrue(filename.hasSuffix(".pdf"))
    }

    @MainActor
    func testGenerateFilename_sanitizesInvalidCharacters() {
        // Given - Title with invalid filename characters
        let entry = BibTeXEntry(
            citeKey: "Special2020",
            entryType: "article",
            fields: [
                "author": "Special Author",
                "year": "2020",
                "title": "What/Is:This*File?"
            ]
        )

        // When
        let filename = pdfManager.generateFilename(from: entry)

        // Then - Invalid characters should be removed
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(":"))
        XCTAssertFalse(filename.contains("*"))
        XCTAssertFalse(filename.contains("?"))
    }

    // MARK: - Bdsk-File Codec Tests

    func testBdskFileCodec_decode_validPlist() {
        // Given - A real Bdsk-File value (base64-encoded plist)
        // This is how BibDesk encodes file references
        let plist: [String: Any] = ["relativePath": "Papers/Einstein_1905.pdf"]
        let plistData = try! PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let base64Value = plistData.base64EncodedString()

        // When
        let decoded = BdskFileCodec.decode(base64Value)

        // Then
        XCTAssertEqual(decoded, "Papers/Einstein_1905.pdf")
    }

    func testBdskFileCodec_decode_invalidBase64() {
        // Given - Invalid base64
        let invalidValue = "not-valid-base64!!!"

        // When
        let decoded = BdskFileCodec.decode(invalidValue)

        // Then
        XCTAssertNil(decoded)
    }

    func testBdskFileCodec_encode_roundTrip() {
        // Given
        let relativePath = "Papers/Test_2020.pdf"

        // When
        guard let encoded = BdskFileCodec.encode(relativePath: relativePath) else {
            XCTFail("Encoding should succeed")
            return
        }
        let decoded = BdskFileCodec.decode(encoded)

        // Then
        XCTAssertEqual(decoded, relativePath)
    }

    // MARK: - Core Data Tests
    // Note: Core Data tests using multiple in-memory stores can cause
    // entity description conflicts. These tests use the shared persistence
    // controller or are designed to not create new stores.

    // Integration tests for import/link operations are in BibTeXIntegrationTests

    // MARK: - PDF Viewer Error Tests

    func testPDFViewerError_fileNotFound_hasDescription() {
        // Given
        let url = URL(fileURLWithPath: "/path/to/missing.pdf")
        let error = PDFViewerError.fileNotFound(url)

        // Then
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("missing.pdf"))
    }

    func testPDFViewerError_invalidPDF_hasDescription() {
        // Given
        let url = URL(fileURLWithPath: "/path/to/corrupt.pdf")
        let error = PDFViewerError.invalidPDF(url)

        // Then
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("corrupt.pdf"))
    }

    func testPDFViewerError_invalidData_hasDescription() {
        // Given
        let error = PDFViewerError.invalidData

        // Then
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Invalid"))
    }

    func testPDFViewerError_documentNotLoaded_hasDescription() {
        // Given
        let error = PDFViewerError.documentNotLoaded

        // Then
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not be loaded"))
    }

    func testPDFViewerError_loadFailed_includesUnderlyingError() {
        // Given
        struct TestError: LocalizedError {
            var errorDescription: String? { "test error message" }
        }
        let error = PDFViewerError.loadFailed(TestError())

        // Then
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("test error message"))
    }
}
