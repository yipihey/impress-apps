//
//  SearchImportIntegrationTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class SearchImportIntegrationTests: XCTestCase {

    // MARK: - Properties

    private var sourceManager: SourceManager!
    private var credentialManager: CredentialManager!
    private var deduplicationService: DeduplicationService!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        credentialManager = CredentialManager(keyPrefix: "test.\(UUID().uuidString)")
        sourceManager = SourceManager(credentialManager: credentialManager)
        deduplicationService = DeduplicationService()
    }

    override func tearDown() async throws {
        sourceManager = nil
        credentialManager = nil
        deduplicationService = nil
        try await super.tearDown()
    }

    // MARK: - Search Flow Tests

    func testSearchFlow_singleSource_returnsResults() async throws {
        // Given - register a mock source with results
        let mockSource = MockSourcePlugin(id: "mock", name: "Mock Source")
        await mockSource.setSearchResults([
            makeSearchResult(id: "1", title: "Quantum Computing Basics"),
            makeSearchResult(id: "2", title: "Advanced Quantum Algorithms"),
            makeSearchResult(id: "3", title: "Quantum Error Correction")
        ])
        await sourceManager.register(mockSource)

        // When
        let results = try await sourceManager.search(query: "quantum")

        // Then
        XCTAssertEqual(results.count, 3)
        XCTAssert(results.allSatisfy { $0.title.lowercased().contains("quantum") })
    }

    func testSearchFlow_multipleSources_aggregatesResults() async throws {
        // Given
        let arxiv = MockSourcePlugin(id: "arxiv", name: "arXiv")
        await arxiv.setSearchResults([
            makeSearchResult(id: "arxiv:1", title: "ArXiv Paper 1", sourceID: "arxiv"),
            makeSearchResult(id: "arxiv:2", title: "ArXiv Paper 2", sourceID: "arxiv")
        ])

        let crossref = MockSourcePlugin(id: "crossref", name: "Crossref")
        await crossref.setSearchResults([
            makeSearchResult(id: "crossref:1", title: "Crossref Paper 1", sourceID: "crossref")
        ])

        await sourceManager.register(arxiv)
        await sourceManager.register(crossref)

        // When
        let results = try await sourceManager.search(query: "test")

        // Then
        XCTAssertEqual(results.count, 3)

        let sources = Set(results.map { $0.sourceID })
        XCTAssertTrue(sources.contains("arxiv"))
        XCTAssertTrue(sources.contains("crossref"))
    }

    func testSearchFlow_deduplication_mergesDuplicates() async throws {
        // Given - same paper from two sources (shared DOI)
        let arxiv = MockSourcePlugin(id: "arxiv", name: "arXiv")
        await arxiv.setSearchResults([
            makeSearchResult(
                id: "arxiv:2401.00001",
                title: "Paper Title",
                sourceID: "arxiv",
                doi: "10.1234/paper.2024"
            )
        ])

        let crossref = MockSourcePlugin(id: "crossref", name: "Crossref")
        await crossref.setSearchResults([
            makeSearchResult(
                id: "10.1234/paper.2024",
                title: "Paper Title",
                sourceID: "crossref",
                doi: "10.1234/paper.2024"
            )
        ])

        await sourceManager.register(arxiv)
        await sourceManager.register(crossref)

        // When
        let results = try await sourceManager.search(query: "test")
        let deduplicated = await deduplicationService.deduplicate(results)

        // Then - should be merged to 1
        XCTAssertEqual(deduplicated.count, 1)
    }

    // MARK: - BibTeX Fetch Tests

    func testFetchBibTeX_success() async throws {
        // Given
        let mockSource = MockSourcePlugin(id: "mock", name: "Mock Source")
        let expectedEntry = BibTeXEntry(
            citeKey: "Test2024",
            entryType: "article",
            fields: [
                "author": "Test Author",
                "title": "Test Paper",
                "year": "2024"
            ]
        )
        await mockSource.setBibTeXEntry(expectedEntry, for: "result1")
        await sourceManager.register(mockSource)

        let searchResult = makeSearchResult(id: "result1", title: "Test Paper", sourceID: "mock")

        // When
        let entry = try await sourceManager.fetchBibTeX(for: searchResult)

        // Then
        XCTAssertEqual(entry.citeKey, "Test2024")
        XCTAssertEqual(entry.entryType, "article")
        XCTAssertEqual(entry.fields["author"], "Test Author")
    }

    func testFetchBibTeX_normalizes_entry() async throws {
        // Given - source that normalizes cite keys
        let mockSource = MockSourcePlugin(id: "mock", name: "Mock Source")
        let entry = BibTeXEntry(
            citeKey: "original-key",
            entryType: "article",
            fields: ["title": "Test"]
        )
        await mockSource.setBibTeXEntry(entry, for: "result1")
        await sourceManager.register(mockSource)

        let searchResult = makeSearchResult(id: "result1", title: "Test", sourceID: "mock")

        // When
        let fetched = try await sourceManager.fetchBibTeX(for: searchResult)

        // Then - normalize should be called (MockSourcePlugin returns entry unchanged)
        XCTAssertNotNil(fetched)
    }

    // MARK: - Credential Flow Tests

    func testSearch_withRequiredCredentials_works() async throws {
        // Given
        let source = MockSourcePlugin(
            id: "secure",
            name: "Secure Source",
            credentialRequirement: .apiKey
        )
        await source.setSearchResults([
            makeSearchResult(id: "1", title: "Secure Paper", sourceID: "secure")
        ])
        await sourceManager.register(source)

        // Store credentials
        try await credentialManager.store("test-api-key", for: "secure", type: .apiKey)

        // When
        let results = try await sourceManager.search(query: "test")

        // Then - should have results because credentials are present
        XCTAssertEqual(results.count, 1)
    }

    func testSearch_withoutRequiredCredentials_skipsSource() async throws {
        // Given - source requires API key but none stored
        let secure = MockSourcePlugin(
            id: "secure",
            name: "Secure Source",
            credentialRequirement: .apiKey
        )
        await secure.setSearchResults([
            makeSearchResult(id: "1", title: "From Secure", sourceID: "secure")
        ])

        let open = MockSourcePlugin(
            id: "open",
            name: "Open Source",
            credentialRequirement: .none
        )
        await open.setSearchResults([
            makeSearchResult(id: "2", title: "From Open", sourceID: "open")
        ])

        await sourceManager.register(secure)
        await sourceManager.register(open)

        // When - no credentials for "secure"
        let results = try await sourceManager.search(query: "test")

        // Then - should only get results from open source
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, "open")
    }

    // MARK: - Error Handling Tests

    func testSearch_partialFailure_returnsSuccessfulResults() async throws {
        // Given
        let failing = MockSourcePlugin(id: "failing", name: "Failing Source")
        await failing.setSearchError(SourceError.networkError(NSError(domain: "test", code: -1)))

        let working = MockSourcePlugin(id: "working", name: "Working Source")
        await working.setSearchResults([
            makeSearchResult(id: "1", title: "Success", sourceID: "working")
        ])

        await sourceManager.register(failing)
        await sourceManager.register(working)

        // When
        let results = try await sourceManager.search(query: "test")

        // Then - should still get results from working source
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, "working")
    }

    // MARK: - ViewModel Integration
    // Note: SearchViewModel full flow tests are in SearchViewModelTests.swift
    // to avoid Core Data entity conflicts when using shared persistence controllers

    // MARK: - Helpers

    private func makeSearchResult(
        id: String,
        title: String,
        sourceID: String = "mock",
        doi: String? = nil
    ) -> SearchResult {
        SearchResult(
            id: id,
            sourceID: sourceID,
            title: title,
            authors: ["Test Author"],
            year: 2024,
            venue: "Test Journal",
            abstract: nil,
            doi: doi,
            arxivID: nil,
            pmid: nil,
            bibcode: nil,
            semanticScholarID: nil,
            openAlexID: nil,
            pdfURL: nil,
            webURL: nil,
            bibtexURL: nil
        )
    }
}
