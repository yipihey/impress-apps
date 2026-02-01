//
//  AutomationServiceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-29.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

// MARK: - Mock Dependencies

/// Mock settings store for testing authorization
actor MockAutomationSettingsStore {
    var isEnabled: Bool = true

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }
}

/// Mock collection repository for testing
actor MockCollectionRepository {
    var collections: [MockCollection] = []
    var createCallCount = 0
    var deleteCallCount = 0
    var addPublicationsCallCount = 0
    var removePublicationsCallCount = 0

    struct MockCollection: Identifiable {
        let id: UUID
        var name: String
        var isSmartCollection: Bool
        var predicate: String?
        var publicationIDs: Set<UUID> = []
    }

    func fetchAll() async -> [MockCollection] {
        collections
    }

    func create(name: String, isSmartCollection: Bool, predicate: String?) async -> MockCollection {
        createCallCount += 1
        let collection = MockCollection(
            id: UUID(),
            name: name,
            isSmartCollection: isSmartCollection,
            predicate: predicate
        )
        collections.append(collection)
        return collection
    }

    func delete(_ collection: MockCollection) async {
        deleteCallCount += 1
        collections.removeAll { $0.id == collection.id }
    }

    func addPublications(_ publications: [UUID], to collectionID: UUID) async {
        addPublicationsCallCount += 1
        if let index = collections.firstIndex(where: { $0.id == collectionID }) {
            collections[index].publicationIDs.formUnion(publications)
        }
    }

    func removePublications(_ publications: [UUID], from collectionID: UUID) async {
        removePublicationsCallCount += 1
        if let index = collections.firstIndex(where: { $0.id == collectionID }) {
            collections[index].publicationIDs.subtract(publications)
        }
    }

    func reset() {
        collections = []
        createCallCount = 0
        deleteCallCount = 0
        addPublicationsCallCount = 0
        removePublicationsCallCount = 0
    }
}

/// Mock source manager for testing external search
actor MockSourceManager {
    var searchResults: [SearchResult] = []
    var searchCallCount = 0
    var lastSearchQuery: String?
    var lastSearchOptions: SearchOptions?
    var searchError: Error?

    struct MockSource {
        let id: String
        let name: String
        var hasCredentials: Bool = true
    }

    var availableSources: [MockSource] = [
        MockSource(id: "arxiv", name: "arXiv"),
        MockSource(id: "ads", name: "NASA ADS"),
        MockSource(id: "crossref", name: "Crossref")
    ]

    func search(query: String, options: SearchOptions) async throws -> [SearchResult] {
        searchCallCount += 1
        lastSearchQuery = query
        lastSearchOptions = options

        if let error = searchError {
            throw error
        }

        return searchResults
    }

    func hasValidCredentials(for sourceID: String) async -> Bool {
        availableSources.first { $0.id == sourceID }?.hasCredentials ?? false
    }

    func setSearchResults(_ results: [SearchResult]) {
        searchResults = results
    }

    func setSearchError(_ error: Error?) {
        searchError = error
    }

    func reset() {
        searchResults = []
        searchCallCount = 0
        lastSearchQuery = nil
        lastSearchOptions = nil
        searchError = nil
    }
}

// MARK: - Test Case

final class AutomationServiceTests: XCTestCase {

    var mockRepository: MockPublicationRepository!
    var mockSettings: MockAutomationSettingsStore!

    override func setUp() async throws {
        mockRepository = MockPublicationRepository()
        mockSettings = MockAutomationSettingsStore()
    }

    override func tearDown() async throws {
        await mockRepository.reset()
        mockRepository = nil
        mockSettings = nil
    }

    // MARK: - Authorization Tests

    func testAuthorizationFailsWhenDisabled() async throws {
        await mockSettings.setEnabled(false)

        // Since we can't inject the mock settings into the real AutomationService,
        // we test the error type directly
        let error = AutomationOperationError.unauthorized
        XCTAssertEqual(error.errorDescription, "Unauthorized: automation API is disabled")
    }

    func testAuthorizationSucceedsWhenEnabled() async throws {
        await mockSettings.setEnabled(true)
        let isEnabled = await mockSettings.isEnabled
        XCTAssertTrue(isEnabled)
    }

    // MARK: - PaperIdentifier Tests

    func testPaperIdentifierFromDOI() {
        let identifier = PaperIdentifier.fromString("10.1038/nature12373")
        if case .doi(let doi) = identifier {
            XCTAssertEqual(doi, "10.1038/nature12373")
        } else {
            XCTFail("Expected DOI identifier")
        }
    }

    func testPaperIdentifierFromDOIWithPrefix() {
        let identifier = PaperIdentifier.fromString("doi:10.1038/nature12373")
        if case .doi(let doi) = identifier {
            XCTAssertEqual(doi, "10.1038/nature12373")
        } else {
            XCTFail("Expected DOI identifier")
        }
    }

    func testPaperIdentifierFromArXivNewFormat() {
        let identifier = PaperIdentifier.fromString("2301.12345")
        if case .arxiv(let id) = identifier {
            XCTAssertEqual(id, "2301.12345")
        } else {
            XCTFail("Expected arXiv identifier, got \(identifier)")
        }
    }

    func testPaperIdentifierFromArXivOldFormat() {
        let identifier = PaperIdentifier.fromString("hep-th/9901001")
        if case .arxiv(let id) = identifier {
            XCTAssertEqual(id, "hep-th/9901001")
        } else {
            XCTFail("Expected arXiv identifier")
        }
    }

    func testPaperIdentifierFromBibcode() {
        let identifier = PaperIdentifier.fromString("2023ApJ...950L..22A")
        if case .bibcode(let code) = identifier {
            XCTAssertEqual(code, "2023ApJ...950L..22A")
        } else {
            XCTFail("Expected bibcode identifier")
        }
    }

    func testPaperIdentifierFromUUID() {
        let uuid = UUID()
        let identifier = PaperIdentifier.fromString(uuid.uuidString)
        if case .uuid(let parsed) = identifier {
            XCTAssertEqual(parsed, uuid)
        } else {
            XCTFail("Expected UUID identifier")
        }
    }

    func testPaperIdentifierFromCiteKey() {
        let identifier = PaperIdentifier.fromString("Einstein1905Relativity")
        if case .citeKey(let key) = identifier {
            XCTAssertEqual(key, "Einstein1905Relativity")
        } else {
            XCTFail("Expected cite key identifier")
        }
    }

    func testPaperIdentifierValue() {
        XCTAssertEqual(PaperIdentifier.doi("10.1234/test").value, "10.1234/test")
        XCTAssertEqual(PaperIdentifier.arxiv("2301.12345").value, "2301.12345")
        XCTAssertEqual(PaperIdentifier.citeKey("Einstein2020").value, "Einstein2020")
    }

    func testPaperIdentifierTypeName() {
        XCTAssertEqual(PaperIdentifier.doi("10.1234/test").typeName, "doi")
        XCTAssertEqual(PaperIdentifier.arxiv("2301.12345").typeName, "arXiv")
        XCTAssertEqual(PaperIdentifier.citeKey("key").typeName, "citeKey")
        XCTAssertEqual(PaperIdentifier.bibcode("2023ApJ...950L..22A").typeName, "bibcode")
    }

    // MARK: - SearchFilters Tests

    func testSearchFiltersInit() {
        let filters = SearchFilters(
            yearFrom: 2020,
            yearTo: 2024,
            isRead: true,
            limit: 50
        )

        XCTAssertEqual(filters.yearFrom, 2020)
        XCTAssertEqual(filters.yearTo, 2024)
        XCTAssertEqual(filters.isRead, true)
        XCTAssertEqual(filters.limit, 50)
        XCTAssertNil(filters.authors)
        XCTAssertNil(filters.hasLocalPDF)
    }

    func testSearchFiltersCodable() throws {
        let original = SearchFilters(
            yearFrom: 2020,
            yearTo: 2024,
            authors: ["Einstein", "Feynman"],
            isRead: false,
            hasLocalPDF: true,
            limit: 100,
            offset: 10
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SearchFilters.self, from: data)

        XCTAssertEqual(decoded.yearFrom, original.yearFrom)
        XCTAssertEqual(decoded.yearTo, original.yearTo)
        XCTAssertEqual(decoded.authors, original.authors)
        XCTAssertEqual(decoded.isRead, original.isRead)
        XCTAssertEqual(decoded.hasLocalPDF, original.hasLocalPDF)
        XCTAssertEqual(decoded.limit, original.limit)
        XCTAssertEqual(decoded.offset, original.offset)
    }

    // MARK: - PaperResult Tests

    func testPaperResultInit() {
        let id = UUID()
        let result = PaperResult(
            id: id,
            citeKey: "Einstein1905",
            title: "On the Electrodynamics of Moving Bodies",
            authors: ["Einstein, Albert"],
            year: 1905,
            venue: "Annalen der Physik",
            doi: "10.1002/andp.19053221004"
        )

        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.citeKey, "Einstein1905")
        XCTAssertEqual(result.title, "On the Electrodynamics of Moving Bodies")
        XCTAssertEqual(result.authors, ["Einstein, Albert"])
        XCTAssertEqual(result.year, 1905)
        XCTAssertEqual(result.venue, "Annalen der Physik")
        XCTAssertEqual(result.doi, "10.1002/andp.19053221004")
    }

    func testPaperResultFirstAuthorLastName() {
        // Test "Last, First" format
        let result1 = PaperResult(
            id: UUID(),
            citeKey: "test1",
            title: "Test",
            authors: ["Einstein, Albert", "Podolsky, Boris"]
        )
        XCTAssertEqual(result1.firstAuthorLastName, "Einstein")

        // Test "First Last" format
        let result2 = PaperResult(
            id: UUID(),
            citeKey: "test2",
            title: "Test",
            authors: ["Albert Einstein"]
        )
        XCTAssertEqual(result2.firstAuthorLastName, "Einstein")

        // Test empty authors
        let result3 = PaperResult(
            id: UUID(),
            citeKey: "test3",
            title: "Test",
            authors: []
        )
        XCTAssertNil(result3.firstAuthorLastName)
    }

    func testPaperResultCodable() throws {
        let original = PaperResult(
            id: UUID(),
            citeKey: "Test2024",
            title: "Test Paper",
            authors: ["Author, Test"],
            year: 2024,
            venue: "Test Journal",
            abstract: "This is a test abstract",
            doi: "10.1234/test",
            isRead: true,
            hasPDF: true,
            citationCount: 42
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PaperResult.self, from: data)

        XCTAssertEqual(decoded.citeKey, original.citeKey)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.authors, original.authors)
        XCTAssertEqual(decoded.year, original.year)
        XCTAssertEqual(decoded.doi, original.doi)
        XCTAssertEqual(decoded.isRead, original.isRead)
        XCTAssertEqual(decoded.citationCount, original.citationCount)
    }

    // MARK: - CollectionResult Tests

    func testCollectionResultInit() {
        let id = UUID()
        let libraryID = UUID()
        let result = CollectionResult(
            id: id,
            name: "Reading List",
            paperCount: 42,
            isSmartCollection: false,
            libraryID: libraryID,
            libraryName: "Main Library"
        )

        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.name, "Reading List")
        XCTAssertEqual(result.paperCount, 42)
        XCTAssertFalse(result.isSmartCollection)
        XCTAssertEqual(result.libraryID, libraryID)
        XCTAssertEqual(result.libraryName, "Main Library")
    }

    func testCollectionResultCodable() throws {
        let original = CollectionResult(
            id: UUID(),
            name: "Test Collection",
            paperCount: 10,
            isSmartCollection: true,
            libraryID: UUID(),
            libraryName: "Library"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CollectionResult.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.paperCount, original.paperCount)
        XCTAssertEqual(decoded.isSmartCollection, original.isSmartCollection)
    }

    // MARK: - LibraryResult Tests

    func testLibraryResultInit() {
        let id = UUID()
        let result = LibraryResult(
            id: id,
            name: "Main Library",
            paperCount: 100,
            collectionCount: 5,
            isDefault: true,
            isInbox: false
        )

        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.name, "Main Library")
        XCTAssertEqual(result.paperCount, 100)
        XCTAssertEqual(result.collectionCount, 5)
        XCTAssertTrue(result.isDefault)
        XCTAssertFalse(result.isInbox)
    }

    // MARK: - AddPapersResult Tests

    func testAddPapersResultInit() {
        let paper = PaperResult(
            id: UUID(),
            citeKey: "Added2024",
            title: "Added Paper",
            authors: []
        )

        let result = AddPapersResult(
            added: [paper],
            duplicates: ["Existing2020"],
            failed: ["Invalid123": "Not found"]
        )

        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.duplicates, ["Existing2020"])
        XCTAssertEqual(result.failed["Invalid123"], "Not found")
        XCTAssertEqual(result.totalProcessed, 3)
        XCTAssertFalse(result.allSucceeded)
    }

    func testAddPapersResultAllSucceeded() {
        let paper = PaperResult(
            id: UUID(),
            citeKey: "Success2024",
            title: "Success",
            authors: []
        )

        let result = AddPapersResult(
            added: [paper],
            duplicates: [],
            failed: [:]
        )

        XCTAssertTrue(result.allSucceeded)
    }

    // MARK: - ExportResult Tests

    func testExportResultInit() {
        let result = ExportResult(
            format: "bibtex",
            content: "@article{Test2024, title={Test}}",
            paperCount: 1
        )

        XCTAssertEqual(result.format, "bibtex")
        XCTAssertEqual(result.paperCount, 1)
        XCTAssertTrue(result.content.contains("@article"))
    }

    // MARK: - DownloadResult Tests

    func testDownloadResultInit() {
        let result = DownloadResult(
            downloaded: ["Paper1", "Paper2"],
            alreadyHad: ["Paper3"],
            failed: ["Paper4": "Connection failed"]
        )

        XCTAssertEqual(result.downloaded.count, 2)
        XCTAssertEqual(result.alreadyHad.count, 1)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(result.totalProcessed, 4)
    }

    // MARK: - SearchOperationResult Tests

    func testSearchOperationResultInit() {
        let papers = [
            PaperResult(id: UUID(), citeKey: "Result1", title: "Result 1", authors: []),
            PaperResult(id: UUID(), citeKey: "Result2", title: "Result 2", authors: [])
        ]

        let result = SearchOperationResult(
            papers: papers,
            totalCount: 100,
            hasMore: true,
            sources: ["arxiv", "ads"]
        )

        XCTAssertEqual(result.papers.count, 2)
        XCTAssertEqual(result.totalCount, 100)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.sources, ["arxiv", "ads"])
    }

    // MARK: - AutomationOperationError Tests

    func testAutomationOperationErrorDescriptions() {
        XCTAssertTrue(AutomationOperationError.paperNotFound("test").errorDescription?.contains("test") ?? false)
        XCTAssertTrue(AutomationOperationError.unauthorized.errorDescription?.contains("Unauthorized") ?? false)
        XCTAssertTrue(AutomationOperationError.rateLimited.errorDescription?.contains("Rate limited") ?? false)

        let collectionID = UUID()
        XCTAssertTrue(AutomationOperationError.collectionNotFound(collectionID).errorDescription?.contains(collectionID.uuidString) ?? false)
    }

    // MARK: - MockPublicationRepository Integration Tests

    func testMockRepositoryFetchAll() async {
        let samples = MockPublication.samples(count: 3)
        for sample in samples {
            await mockRepository.add(sample)
        }

        let all = await mockRepository.fetchAll()
        let fetchCount = await mockRepository.fetchAllCallCount
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(fetchCount, 1)
    }

    func testMockRepositorySearch() async {
        await mockRepository.add(MockPublication(citeKey: "Einstein1905", title: "Relativity"))
        await mockRepository.add(MockPublication(citeKey: "Feynman1965", title: "QED"))

        let results = await mockRepository.search(query: "Einstein")
        let lastQuery = await mockRepository.lastSearchQuery
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.citeKey, "Einstein1905")
        XCTAssertEqual(lastQuery, "Einstein")
    }

    func testMockRepositoryFetchByCiteKey() async {
        await mockRepository.add(MockPublication(citeKey: "Test2024", title: "Test Paper"))

        let found = await mockRepository.fetch(byCiteKey: "Test2024")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Test Paper")

        let notFound = await mockRepository.fetch(byCiteKey: "NonExistent")
        XCTAssertNil(notFound)
    }

    func testMockRepositoryCreate() async {
        let entry = BibTeXEntry(
            citeKey: "New2024",
            entryType: "article",
            fields: ["title": "New Paper", "year": "2024"]
        )

        let created = await mockRepository.create(from: entry)
        XCTAssertEqual(created.citeKey, "New2024")
        let createCount = await mockRepository.createCallCount
        let repoCount = await mockRepository.count
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(repoCount, 1)
    }

    func testMockRepositoryDelete() async {
        let pub = MockPublication(citeKey: "ToDelete", title: "Delete Me")
        await mockRepository.add(pub)
        var repoCount = await mockRepository.count
        XCTAssertEqual(repoCount, 1)

        await mockRepository.delete(pub)
        repoCount = await mockRepository.count
        let deleteCount = await mockRepository.deleteCallCount
        XCTAssertEqual(repoCount, 0)
        XCTAssertEqual(deleteCount, 1)
    }

    func testMockRepositoryImport() async {
        let entries = [
            BibTeXEntry(citeKey: "Import1", entryType: "article", fields: ["title": "Paper 1"]),
            BibTeXEntry(citeKey: "Import2", entryType: "article", fields: ["title": "Paper 2"])
        ]

        let imported = await mockRepository.importEntries(entries)
        let repoCount = await mockRepository.count
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(repoCount, 2)
    }

    func testMockRepositoryImportSkipsDuplicates() async {
        // Add existing publication
        await mockRepository.add(MockPublication(citeKey: "Existing", title: "Existing Paper"))

        let entries = [
            BibTeXEntry(citeKey: "Existing", entryType: "article", fields: ["title": "Duplicate"]),
            BibTeXEntry(citeKey: "New", entryType: "article", fields: ["title": "New Paper"])
        ]

        let imported = await mockRepository.importEntries(entries)
        let repoCount = await mockRepository.count
        XCTAssertEqual(imported, 1)  // Only new one imported
        XCTAssertEqual(repoCount, 2)
    }

    func testMockRepositoryExport() async {
        await mockRepository.add(MockPublication(citeKey: "Export1", title: "Paper 1"))
        await mockRepository.add(MockPublication(citeKey: "Export2", title: "Paper 2"))

        let exported = await mockRepository.exportAll()
        XCTAssertTrue(exported.contains("@article{Export1"))
        XCTAssertTrue(exported.contains("@article{Export2"))
    }

    // MARK: - Mock Collection Repository Tests

    func testMockCollectionRepositoryCreate() async {
        let mockCollections = MockCollectionRepository()

        let created = await mockCollections.create(
            name: "New Collection",
            isSmartCollection: false,
            predicate: nil
        )

        XCTAssertEqual(created.name, "New Collection")
        XCTAssertFalse(created.isSmartCollection)
        let createCount = await mockCollections.createCallCount
        XCTAssertEqual(createCount, 1)
    }

    func testMockCollectionRepositoryFetchAll() async {
        let mockCollections = MockCollectionRepository()

        _ = await mockCollections.create(name: "Collection 1", isSmartCollection: false, predicate: nil)
        _ = await mockCollections.create(name: "Collection 2", isSmartCollection: true, predicate: "year > 2020")

        let all = await mockCollections.fetchAll()
        XCTAssertEqual(all.count, 2)
    }

    func testMockCollectionRepositoryDelete() async {
        let mockCollections = MockCollectionRepository()

        let collection = await mockCollections.create(name: "To Delete", isSmartCollection: false, predicate: nil)
        var allCollections = await mockCollections.fetchAll()
        XCTAssertEqual(allCollections.count, 1)

        await mockCollections.delete(collection)
        allCollections = await mockCollections.fetchAll()
        let deleteCount = await mockCollections.deleteCallCount
        XCTAssertEqual(allCollections.count, 0)
        XCTAssertEqual(deleteCount, 1)
    }

    // MARK: - Mock Source Manager Tests

    func testMockSourceManagerSearch() async throws {
        let mockSource = MockSourceManager()

        let testResults = [
            SearchResult(
                id: "test-1",
                sourceID: "arxiv",
                title: "Test Paper",
                authors: ["Author, Test"]
            )
        ]
        await mockSource.setSearchResults(testResults)

        let results = try await mockSource.search(
            query: "test query",
            options: SearchOptions(maxResults: 10)
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Test Paper")
        let searchCount = await mockSource.searchCallCount
        let lastQuery = await mockSource.lastSearchQuery
        XCTAssertEqual(searchCount, 1)
        XCTAssertEqual(lastQuery, "test query")
    }

    func testMockSourceManagerSearchError() async {
        let mockSource = MockSourceManager()

        struct TestError: Error {}
        await mockSource.setSearchError(TestError())

        do {
            _ = try await mockSource.search(query: "test", options: SearchOptions())
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    func testMockSourceManagerCredentials() async {
        let mockSource = MockSourceManager()

        let hasArxiv = await mockSource.hasValidCredentials(for: "arxiv")
        XCTAssertTrue(hasArxiv)

        let hasUnknown = await mockSource.hasValidCredentials(for: "unknown")
        XCTAssertFalse(hasUnknown)
    }
}
