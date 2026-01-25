//
//  SourceManagerTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class SourceManagerTests: XCTestCase {

    // MARK: - Properties

    private var sourceManager: SourceManager!
    private var credentialManager: CredentialManager!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        // Use unique prefix for test isolation
        credentialManager = CredentialManager(keyPrefix: "test.\(UUID().uuidString)")
        sourceManager = SourceManager(credentialManager: credentialManager)
    }

    override func tearDown() async throws {
        sourceManager = nil
        credentialManager = nil
        try await super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeSearchResult(
        id: String,
        title: String,
        sourceID: String,
        authors: [String] = ["Test Author"],
        year: Int? = 2024
    ) -> SearchResult {
        SearchResult(
            id: id,
            sourceID: sourceID,
            title: title,
            authors: authors,
            year: year,
            venue: "Test Journal",
            abstract: nil,
            doi: nil,
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

    // MARK: - Registration Tests

    func testRegister_addsPluginToAvailableSources() async {
        // Given
        let mockSource = MockSourcePlugin(id: "mock", name: "Mock Source")

        // When
        await sourceManager.register(mockSource)

        // Then
        let sources = await sourceManager.availableSources
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.id, "mock")
        XCTAssertEqual(sources.first?.name, "Mock Source")
    }

    func testRegister_multipleSources_allAvailable() async {
        // Given
        let source1 = MockSourcePlugin(id: "source1", name: "Source One")
        let source2 = MockSourcePlugin(id: "source2", name: "Source Two")
        let source3 = MockSourcePlugin(id: "source3", name: "Source Three")

        // When
        await sourceManager.register(source1)
        await sourceManager.register(source2)
        await sourceManager.register(source3)

        // Then
        let sources = await sourceManager.availableSources
        XCTAssertEqual(sources.count, 3)

        // Should be sorted by name
        XCTAssertEqual(sources[0].name, "Source One")
        XCTAssertEqual(sources[1].name, "Source Three")
        XCTAssertEqual(sources[2].name, "Source Two")
    }

    func testUnregister_removesPlugin() async {
        // Given
        let source1 = MockSourcePlugin(id: "source1", name: "Source One")
        let source2 = MockSourcePlugin(id: "source2", name: "Source Two")
        await sourceManager.register(source1)
        await sourceManager.register(source2)

        // When
        await sourceManager.unregister(id: "source1")

        // Then
        let sources = await sourceManager.availableSources
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.id, "source2")
    }

    func testPlugin_returnsRegisteredPlugin() async {
        // Given
        let mockSource = MockSourcePlugin(id: "mock", name: "Mock Source")
        await sourceManager.register(mockSource)

        // When
        let plugin = await sourceManager.plugin(for: "mock")

        // Then
        XCTAssertNotNil(plugin)
        XCTAssertEqual(plugin?.metadata.id, "mock")
    }

    func testPlugin_nonExistent_returnsNil() async {
        // When
        let plugin = await sourceManager.plugin(for: "nonexistent")

        // Then
        XCTAssertNil(plugin)
    }

    // MARK: - Search Tests

    func testSearch_returnsResultsFromAllSources() async throws {
        // Given
        let source1 = MockSourcePlugin(id: "source1", name: "Source One")
        await source1.setSearchResults([
            makeSearchResult(id: "result1", title: "Paper One", sourceID: "source1")
        ])

        let source2 = MockSourcePlugin(id: "source2", name: "Source Two")
        await source2.setSearchResults([
            makeSearchResult(id: "result2", title: "Paper Two", sourceID: "source2")
        ])

        await sourceManager.register(source1)
        await sourceManager.register(source2)

        // When
        let results = try await sourceManager.search(query: "test")

        // Then
        XCTAssertEqual(results.count, 2)
        XCTAssert(results.contains { $0.id == "result1" })
        XCTAssert(results.contains { $0.id == "result2" })
    }

    func testSearch_filtersSourcesByOption() async throws {
        // Given
        let source1 = MockSourcePlugin(id: "source1", name: "Source One")
        await source1.setSearchResults([
            makeSearchResult(id: "result1", title: "Paper One", sourceID: "source1")
        ])

        let source2 = MockSourcePlugin(id: "source2", name: "Source Two")
        await source2.setSearchResults([
            makeSearchResult(id: "result2", title: "Paper Two", sourceID: "source2")
        ])

        await sourceManager.register(source1)
        await sourceManager.register(source2)

        // When - only search source1
        let options = SearchOptions(sourceIDs: ["source1"])
        let results = try await sourceManager.search(query: "test", options: options)

        // Then
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "result1")
    }

    func testSearch_emptyQuery_stillSearches() async throws {
        // Given
        let mockSource = MockSourcePlugin(id: "mock", name: "Mock Source")
        await mockSource.setSearchResults([
            makeSearchResult(id: "result1", title: "Paper One", sourceID: "mock")
        ])
        await sourceManager.register(mockSource)

        // When
        let results = try await sourceManager.search(query: "")

        // Then
        XCTAssertEqual(results.count, 1)
    }

    func testSearch_noRegisteredSources_returnsEmpty() async throws {
        // When
        let results = try await sourceManager.search(query: "test")

        // Then
        XCTAssert(results.isEmpty)
    }

    func testSearch_sourceError_continuesWithOthers() async throws {
        // Given
        let failingSource = MockSourcePlugin(id: "failing", name: "Failing Source")
        await failingSource.setSearchError(SourceError.networkError(NSError(domain: "test", code: -1)))

        let workingSource = MockSourcePlugin(id: "working", name: "Working Source")
        await workingSource.setSearchResults([
            makeSearchResult(id: "result1", title: "Paper One", sourceID: "working")
        ])

        await sourceManager.register(failingSource)
        await sourceManager.register(workingSource)

        // When
        let results = try await sourceManager.search(query: "test")

        // Then - should get results from working source despite failing source error
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, "working")
    }

    func testSearch_maxResultsLimit_truncatesResults() async throws {
        // Given
        let mockSource = MockSourcePlugin(id: "mock", name: "Mock Source")
        await mockSource.setSearchResults(
            (1...100).map { makeSearchResult(id: "result\($0)", title: "Paper \($0)", sourceID: "mock") }
        )
        await sourceManager.register(mockSource)

        // When
        let options = SearchOptions(maxResults: 10)
        let results = try await sourceManager.search(query: "test", options: options)

        // Then
        XCTAssertEqual(results.count, 10)
    }

    func testSearch_specificSource_throwsForUnknownSource() async {
        // When/Then
        do {
            _ = try await sourceManager.search(query: "test", sourceID: "nonexistent")
            XCTFail("Expected error to be thrown")
        } catch {
            guard case SourceError.unknownSource = error else {
                XCTFail("Expected unknownSource error, got \(error)")
                return
            }
        }
    }

    // MARK: - Credential Tests

    func testHasValidCredentials_noRequirement_returnsTrue() async {
        // Given
        let source = MockSourcePlugin(
            id: "mock",
            name: "Mock Source",
            credentialRequirement: .none
        )
        await sourceManager.register(source)

        // When
        let hasCredentials = await sourceManager.hasValidCredentials(for: "mock")

        // Then
        XCTAssertTrue(hasCredentials)
    }

    func testHasValidCredentials_optionalApiKey_returnsTrue() async {
        // Given
        let source = MockSourcePlugin(
            id: "mock",
            name: "Mock Source",
            credentialRequirement: .apiKeyOptional
        )
        await sourceManager.register(source)

        // When - no API key stored
        let hasCredentials = await sourceManager.hasValidCredentials(for: "mock")

        // Then - optional means always valid
        XCTAssertTrue(hasCredentials)
    }

    func testHasValidCredentials_requiredApiKey_withoutKey_returnsFalse() async {
        // Given
        let source = MockSourcePlugin(
            id: "mock",
            name: "Mock Source",
            credentialRequirement: .apiKey
        )
        await sourceManager.register(source)

        // When - no API key stored
        let hasCredentials = await sourceManager.hasValidCredentials(for: "mock")

        // Then
        XCTAssertFalse(hasCredentials)
    }

    func testHasValidCredentials_requiredApiKey_withKey_returnsTrue() async throws {
        // Given
        let source = MockSourcePlugin(
            id: "mock",
            name: "Mock Source",
            credentialRequirement: .apiKey
        )
        await sourceManager.register(source)

        // Store API key
        try await credentialManager.store("test-api-key", for: "mock", type: .apiKey)

        // When
        let hasCredentials = await sourceManager.hasValidCredentials(for: "mock")

        // Then
        XCTAssertTrue(hasCredentials)
    }

    func testHasValidCredentials_unknownSource_returnsFalse() async {
        // When
        let hasCredentials = await sourceManager.hasValidCredentials(for: "unknown")

        // Then
        XCTAssertFalse(hasCredentials)
    }

    // MARK: - Credential Status Tests

    func testCredentialStatus_returnsStatusForAllSources() async {
        // Given
        let source1 = MockSourcePlugin(id: "source1", name: "Source One", credentialRequirement: .none)
        let source2 = MockSourcePlugin(id: "source2", name: "Source Two", credentialRequirement: .apiKey)
        let source3 = MockSourcePlugin(id: "source3", name: "Source Three", credentialRequirement: .apiKeyOptional)

        await sourceManager.register(source1)
        await sourceManager.register(source2)
        await sourceManager.register(source3)

        // When
        let status = await sourceManager.credentialStatus()

        // Then
        XCTAssertEqual(status.count, 3)

        // Sorted by name
        XCTAssertEqual(status[0].sourceName, "Source One")
        XCTAssertEqual(status[0].status, .notRequired)

        XCTAssertEqual(status[1].sourceName, "Source Three")
        XCTAssertEqual(status[1].status, .optionalMissing)

        XCTAssertEqual(status[2].sourceName, "Source Two")
        XCTAssertEqual(status[2].status, .missing)
    }

    // MARK: - BibTeX Fetch Tests

    func testFetchBibTeX_routesToCorrectSource() async throws {
        // Given
        let source1 = MockSourcePlugin(id: "source1", name: "Source One")
        let expectedEntry = BibTeXEntry(
            citeKey: "Test2024",
            entryType: "article",
            fields: ["title": "Test Paper"]
        )
        await source1.setBibTeXEntry(expectedEntry, for: "result1")

        await sourceManager.register(source1)

        let searchResult = makeSearchResult(
            id: "result1",
            title: "Test Paper",
            sourceID: "source1"
        )

        // When
        let entry = try await sourceManager.fetchBibTeX(for: searchResult)

        // Then
        XCTAssertEqual(entry.citeKey, "Test2024")
        XCTAssertEqual(entry.fields["title"], "Test Paper")
    }

    func testFetchBibTeX_unknownSource_throws() async {
        // Given
        let searchResult = makeSearchResult(
            id: "result1",
            title: "Test Paper",
            sourceID: "unknown"
        )

        // When/Then
        do {
            _ = try await sourceManager.fetchBibTeX(for: searchResult)
            XCTFail("Expected error to be thrown")
        } catch {
            guard case SourceError.unknownSource = error else {
                XCTFail("Expected unknownSource error")
                return
            }
        }
    }

    // MARK: - Built-in Sources Tests

    func testRegisterBuiltInSources_registersAllSources() async {
        // When
        await sourceManager.registerBuiltInSources()

        // Then
        let sources = await sourceManager.availableSources

        // Should have all built-in sources
        let sourceIDs = Set(sources.map { $0.id })
        XCTAssertTrue(sourceIDs.contains("arxiv"))
        XCTAssertTrue(sourceIDs.contains("crossref"))
        XCTAssertTrue(sourceIDs.contains("dblp"))
        XCTAssertTrue(sourceIDs.contains("ads"))
        XCTAssertTrue(sourceIDs.contains("semanticscholar"))
        XCTAssertTrue(sourceIDs.contains("openalex"))
    }
}

// MARK: - Search Tests with Credential Filtering

extension SourceManagerTests {

    func testSearch_skipsSourcesWithoutRequiredCredentials() async throws {
        // Given - one source requires API key, one doesn't
        let requiresKey = MockSourcePlugin(
            id: "requires-key",
            name: "Requires Key",
            credentialRequirement: .apiKey
        )
        await requiresKey.setSearchResults([
            makeSearchResult(id: "key-result", title: "From Key Source", sourceID: "requires-key")
        ])

        let noKey = MockSourcePlugin(
            id: "no-key",
            name: "No Key Required",
            credentialRequirement: .none
        )
        await noKey.setSearchResults([
            makeSearchResult(id: "nokey-result", title: "From NoKey Source", sourceID: "no-key")
        ])

        await sourceManager.register(requiresKey)
        await sourceManager.register(noKey)

        // When - no credentials stored
        let results = try await sourceManager.search(query: "test")

        // Then - should only have results from source that doesn't require credentials
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, "no-key")
    }
}
