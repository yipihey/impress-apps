//
//  SearchViewModelTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

/// Tests for SearchViewModel using MockSourcePlugin for isolated testing.
///
/// ADR-016: SearchViewModel now auto-imports results to the active library's
/// "Last Search" collection. These tests verify the auto-import behavior.
@MainActor
final class SearchViewModelTests: XCTestCase {

    private var sourceManager: SourceManager!
    private var mockSource: MockSourcePlugin!
    private var viewModel: SearchViewModel!
    private var libraryManager: LibraryManager!
    private var persistenceController: PersistenceController!

    override func setUp() async throws {
        try await super.setUp()

        // Clear session cache from previous tests
        await SessionCache.shared.clearAll()

        // Use preview persistence controller to avoid Core Data entity conflicts
        persistenceController = .preview

        // Setup library manager - this creates a default library if none exists
        libraryManager = LibraryManager(persistenceController: persistenceController)

        // Clear any existing Last Search results from previous tests
        libraryManager.clearLastSearchCollection()

        // Setup source manager with mock plugin (no credentials needed)
        let credentialManager = CredentialManager(keyPrefix: "test.\(UUID().uuidString)")
        sourceManager = SourceManager(credentialManager: credentialManager)
        mockSource = MockSourcePlugin(id: "mock", name: "Mock Source")
        await sourceManager.register(mockSource)

        // Create view model with source manager and library manager
        viewModel = SearchViewModel(
            sourceManager: sourceManager,
            deduplicationService: DeduplicationService(),
            repository: PublicationRepository(persistenceController: persistenceController),
            libraryManager: libraryManager
        )
    }

    override func tearDown() async throws {
        viewModel = nil
        mockSource = nil
        sourceManager = nil
        libraryManager = nil
        persistenceController = nil
        try await super.tearDown()
    }

    // MARK: - Initial State Tests

    func testViewModel_initialState() {
        XCTAssertTrue(viewModel.publications.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertNil(viewModel.error)
        XCTAssertEqual(viewModel.query, "")
        XCTAssertTrue(viewModel.selectedSourceIDs.isEmpty)
        XCTAssertTrue(viewModel.selectedPublicationIDs.isEmpty)
    }

    // MARK: - Search Tests

    func testSearch_withResults_autoImportsToCollection() async {
        // Given
        let mockResults = MockSourcePlugin.sampleSearchResults(count: 3, sourceID: "mock")
        await mockSource.setSearchResults(mockResults)
        viewModel.query = "quantum"

        // When
        await viewModel.search()

        // Then
        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.publications.count, 3)
        XCTAssertNil(viewModel.error)

        // Verify publications are CDPublication entities
        for pub in viewModel.publications {
            XCTAssertNotNil(pub.title)
            XCTAssertEqual(pub.originalSourceID, "mock")
        }
    }

    func testSearch_emptyQuery_doesNothing() async {
        // Given
        viewModel.query = ""

        // When
        await viewModel.search()

        // Then
        XCTAssertTrue(viewModel.publications.isEmpty)
        XCTAssertFalse(viewModel.isSearching)
    }

    func testSearch_whitespaceOnlyQuery_doesNothing() async {
        // Given
        viewModel.query = "   "

        // When
        await viewModel.search()

        // Then
        XCTAssertTrue(viewModel.publications.isEmpty)
    }

    func testSearch_callsSourceManager() async {
        // Given
        await mockSource.setSearchResults([])
        viewModel.query = "machine learning"

        // When
        await viewModel.search()

        // Then
        let searchCount = await mockSource.searchCallCount
        XCTAssertEqual(searchCount, 1)

        let lastQuery = await mockSource.lastSearchQuery
        XCTAssertEqual(lastQuery, "machine learning")
    }

    func testSearch_deduplicatesResults() async {
        // Given - Results with same DOI
        let result1 = SearchResult(
            id: "mock-1",
            sourceID: "mock",
            title: "Quantum Computing Survey",
            authors: ["Alice Chen"],
            year: 2024,
            venue: "Nature",
            abstract: nil,
            doi: "10.1234/shared-doi",
            arxivID: nil, pmid: nil, bibcode: nil,
            semanticScholarID: nil, openAlexID: nil,
            pdfURL: nil, webURL: nil, bibtexURL: nil
        )
        let result2 = SearchResult(
            id: "mock-2",
            sourceID: "mock",
            title: "Quantum Computing Survey",
            authors: ["Alice Chen"],
            year: 2024,
            venue: "Nature",
            abstract: nil,
            doi: "10.1234/shared-doi",
            arxivID: nil, pmid: nil, bibcode: nil,
            semanticScholarID: nil, openAlexID: nil,
            pdfURL: nil, webURL: nil, bibtexURL: nil
        )
        await mockSource.setSearchResults([result1, result2])
        viewModel.query = "quantum"

        // When
        await viewModel.search()

        // Then - Should be deduplicated to 1 result
        XCTAssertEqual(viewModel.publications.count, 1)
    }

    func testSearch_replacesLastSearchResults() async {
        // Given - First search
        await mockSource.setSearchResults(MockSourcePlugin.sampleSearchResults(count: 3, sourceID: "mock"))
        viewModel.query = "first search"
        await viewModel.search()
        XCTAssertEqual(viewModel.publications.count, 3)

        // When - Second search with different results
        await mockSource.setSearchResults(MockSourcePlugin.sampleSearchResults(count: 2, sourceID: "mock"))
        viewModel.query = "second search"
        await viewModel.search()

        // Then - Previous results are replaced
        XCTAssertEqual(viewModel.publications.count, 2)
    }

    // MARK: - Selection Tests

    func testToggleSelection_selectsPublication() async {
        // Given
        await mockSource.setSearchResults(MockSourcePlugin.sampleSearchResults(count: 1, sourceID: "mock"))
        viewModel.query = "test"
        await viewModel.search()
        let publication = viewModel.publications.first!

        // When
        viewModel.toggleSelection(publication)

        // Then
        XCTAssertTrue(viewModel.selectedPublicationIDs.contains(publication.id))

        // When - Toggle again
        viewModel.toggleSelection(publication)

        // Then
        XCTAssertFalse(viewModel.selectedPublicationIDs.contains(publication.id))
    }

    func testSelectAll_selectsAllPublications() async {
        // Given
        await mockSource.setSearchResults(MockSourcePlugin.sampleSearchResults(count: 5, sourceID: "mock"))
        viewModel.query = "test"
        await viewModel.search()

        // When
        viewModel.selectAll()

        // Then
        XCTAssertEqual(viewModel.selectedPublicationIDs.count, 5)
    }

    func testClearSelection_removesAllSelections() async {
        // Given
        await mockSource.setSearchResults(MockSourcePlugin.sampleSearchResults(count: 5, sourceID: "mock"))
        viewModel.query = "test"
        await viewModel.search()
        viewModel.selectAll()

        // When
        viewModel.clearSelection()

        // Then
        XCTAssertTrue(viewModel.selectedPublicationIDs.isEmpty)
    }

    // MARK: - Source Selection Tests

    func testToggleSource_togglesSourceSelection() async {
        // When - Select source
        viewModel.toggleSource("mock")

        // Then
        XCTAssertTrue(viewModel.selectedSourceIDs.contains("mock"))

        // When - Deselect source
        viewModel.toggleSource("mock")

        // Then
        XCTAssertFalse(viewModel.selectedSourceIDs.contains("mock"))
    }

    func testSelectAllSources_selectsAllAvailable() async {
        // Given
        let mockSource2 = MockSourcePlugin(id: "mock2", name: "Mock 2")
        await sourceManager.register(mockSource2)

        // When
        await viewModel.selectAllSources()

        // Then
        XCTAssertTrue(viewModel.selectedSourceIDs.contains("mock"))
        XCTAssertTrue(viewModel.selectedSourceIDs.contains("mock2"))
    }

    func testClearSourceSelection_removesAllSourceSelections() async {
        // Given
        viewModel.selectedSourceIDs = ["mock", "mock2"]

        // When
        viewModel.clearSourceSelection()

        // Then
        XCTAssertTrue(viewModel.selectedSourceIDs.isEmpty)
    }

    // MARK: - Available Sources Tests

    func testAvailableSources_returnsRegisteredSources() async {
        // When
        let sources = await viewModel.availableSources

        // Then
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(sources.contains { $0.id == "mock" })
    }
}
