//
//  PaperFetchServiceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class PaperFetchServiceTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var sourceManager: SourceManager!
    private var repository: PublicationRepository!
    private var fetchService: PaperFetchService!
    private var inboxManager: InboxManager!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview

        // Clean up at start to ensure fresh state
        await cleanupEntities()

        // Create real services - all using the same persistence controller
        sourceManager = SourceManager(credentialManager: CredentialManager.shared)
        repository = PublicationRepository(persistenceController: persistenceController)
        fetchService = PaperFetchService(
            sourceManager: sourceManager,
            repository: repository,
            persistenceController: persistenceController
        )

        // Use InboxManager.shared since that's what PaperFetchService uses internally
        inboxManager = await MainActor.run {
            InboxManager.shared
        }
    }

    override func tearDown() async throws {
        await cleanupEntities()

        inboxManager = nil
        fetchService = nil
        repository = nil
        sourceManager = nil
        try await super.tearDown()
    }

    private func cleanupEntities() async {
        await MainActor.run {
            let context = persistenceController.viewContext

            let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            let pubs = try? context.fetch(pubRequest)
            pubs?.forEach { context.delete($0) }

            let libRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
            let libs = try? context.fetch(libRequest)
            libs?.forEach { context.delete($0) }

            let ssRequest = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
            let sses = try? context.fetch(ssRequest)
            sses?.forEach { context.delete($0) }

            let muteRequest = NSFetchRequest<CDMutedItem>(entityName: "MutedItem")
            let mutes = try? context.fetch(muteRequest)
            mutes?.forEach { context.delete($0) }

            try? context.save()
        }
    }

    // MARK: - State Tests

    func testIsLoading_initiallyFalse() async {
        let isLoading = await fetchService.isLoading
        XCTAssertFalse(isLoading)
    }

    func testLastFetch_initiallyNil() async {
        let lastFetch = await fetchService.lastFetch
        XCTAssertNil(lastFetch)
    }

    // MARK: - FetchStatus Tests

    func testFetchStatus_idle() {
        let status = FetchStatus.idle
        switch status {
        case .idle:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected idle status")
        }
    }

    func testFetchStatus_loading() {
        let status = FetchStatus.loading
        switch status {
        case .loading:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected loading status")
        }
    }

    func testFetchStatus_completed() {
        let date = Date()
        let status = FetchStatus.completed(count: 5, date: date)
        switch status {
        case .completed(let count, let completedDate):
            XCTAssertEqual(count, 5)
            XCTAssertEqual(completedDate, date)
        default:
            XCTFail("Expected completed status")
        }
    }

    func testFetchStatus_failed() {
        let error = NSError(domain: "test", code: 1)
        let status = FetchStatus.failed(error)
        switch status {
        case .failed(let receivedError):
            XCTAssertEqual((receivedError as NSError).domain, "test")
        default:
            XCTFail("Expected failed status")
        }
    }

    // MARK: - Send To Inbox Tests

    func testSendToInbox_emptyResults_returnsZero() async {
        // When
        let count = await fetchService.sendToInbox(results: [])

        // Then
        XCTAssertEqual(count, 0)
    }

    func testSendToInbox_withResults_createsPapers() async {
        // Given - use unique ID and author to avoid interference from mute tests
        let uniqueID = "test-\(UUID().uuidString)"
        let result = createTestSearchResult(
            id: uniqueID,
            title: "Test Paper \(uniqueID)",
            authors: ["UniqueAuthor, A."]  // Don't use "Einstein" which is muted in other tests
        )

        // When
        let count = await fetchService.sendToInbox(results: [result])

        // Then - paper should be created (not deduplicated)
        XCTAssertEqual(count, 1)
    }

    func testSendToInbox_duplicateResults_deduplicates() async {
        // Given - same paper twice with unique ID
        let uniqueID = "dedup-\(UUID().uuidString)"
        let doi = "10.1234/dedup-\(UUID().uuidString)"
        let result1 = createTestSearchResult(
            id: uniqueID,
            title: "Test Paper",
            authors: ["DedupAuthor, A."],  // Don't use "Einstein" which is muted in other tests
            doi: doi
        )
        let result2 = createTestSearchResult(
            id: uniqueID,
            title: "Test Paper",
            authors: ["DedupAuthor, A."],
            doi: doi
        )

        // When - send first
        let count1 = await fetchService.sendToInbox(results: [result1])
        XCTAssertEqual(count1, 1)

        // When - send duplicate
        let count2 = await fetchService.sendToInbox(results: [result2])

        // Then - should be deduplicated
        XCTAssertEqual(count2, 0)
    }

    func testSendToInbox_mutedAuthor_filtersOut() async {
        // Given
        await MainActor.run {
            _ = inboxManager.mute(type: .author, value: "Einstein")
        }

        let result = createTestSearchResult(
            id: "2024ApJ...123..456E",
            title: "Test Paper",
            authors: ["Albert Einstein"]
        )

        // When
        let count = await fetchService.sendToInbox(results: [result])

        // Then - should be filtered out
        XCTAssertEqual(count, 0)
    }

    func testSendToInbox_mutedDOI_filtersOut() async {
        // Given
        await MainActor.run {
            _ = inboxManager.mute(type: .doi, value: "10.1234/muted")
        }

        let result = createTestSearchResult(
            id: "2024ApJ...123..456E",
            title: "Test Paper",
            authors: ["Smith, J."],
            doi: "10.1234/muted"
        )

        // When
        let count = await fetchService.sendToInbox(results: [result])

        // Then - should be filtered out
        XCTAssertEqual(count, 0)
    }

    func testSendToInbox_mutedVenue_filtersOut() async {
        // Given
        await MainActor.run {
            _ = inboxManager.mute(type: .venue, value: "Nature")
        }

        let result = createTestSearchResult(
            id: "2024ApJ...123..456E",
            title: "Test Paper",
            authors: ["Smith, J."],
            venue: "Nature Physics"
        )

        // When
        let count = await fetchService.sendToInbox(results: [result])

        // Then - should be filtered out
        XCTAssertEqual(count, 0)
    }

    func testSendToInbox_nonMutedPaper_passes() async {
        // Given - mute different author
        await MainActor.run {
            _ = inboxManager.mute(type: .author, value: "Einstein")
        }

        let result = createTestSearchResult(
            id: "2024ApJ...123..456E",
            title: "Different Paper",
            authors: ["Newton, I."]  // Not muted
        )

        // When
        let count = await fetchService.sendToInbox(results: [result])

        // Then - should pass through
        XCTAssertEqual(count, 1)
    }

    // MARK: - Fetch For Inbox Tests

    func testFetchForInbox_smartSearch_notFeedingInbox_returns0() async throws {
        // Given - smart search that doesn't feed to inbox
        let smartSearch = await MainActor.run { () -> CDSmartSearch in
            let lib = createTestLibrary(name: "Test")
            let ss = createTestSmartSearch(
                name: "Non-Inbox Search",
                query: "test",
                library: lib,
                feedsToInbox: false
            )
            persistenceController.save()
            return ss
        }

        // When
        let count = try await fetchService.fetchForInbox(smartSearch: smartSearch)

        // Then
        XCTAssertEqual(count, 0)
    }

    func testFetchForInbox_smartSearch_updatesLastFetchCount() async throws {
        // Given - smart search that feeds to inbox but won't find anything (no sources registered)
        let smartSearch = await MainActor.run { () -> CDSmartSearch in
            let lib = createTestLibrary(name: "Test")
            let ss = createTestSmartSearch(
                name: "Inbox Search",
                query: "nonexistent query xyz123",
                library: lib,
                feedsToInbox: true
            )
            persistenceController.save()
            return ss
        }

        // When
        let count = try await fetchService.fetchForInbox(smartSearch: smartSearch)

        // Then
        XCTAssertGreaterThanOrEqual(count, 0)

        // Verify last fetch count was updated
        await MainActor.run {
            XCTAssertEqual(smartSearch.lastFetchCount, Int16(count))
            XCTAssertNotNil(smartSearch.dateLastExecuted)
        }
    }

    // MARK: - Pipeline Tests

    func testProcessResults_multipleResults_createsAll() async {
        // Given - use unique IDs for each test run
        let batch = UUID().uuidString
        let results = [
            createTestSearchResult(
                id: "multi-a-\(batch)",
                title: "Paper A",
                authors: ["Author, A."]
            ),
            createTestSearchResult(
                id: "multi-b-\(batch)",
                title: "Paper B",
                authors: ["Author, B."]
            ),
            createTestSearchResult(
                id: "multi-c-\(batch)",
                title: "Paper C",
                authors: ["Author, C."]
            )
        ]

        // When
        let count = await fetchService.sendToInbox(results: results)

        // Then - all 3 should be created
        XCTAssertEqual(count, 3)
    }

    func testProcessResults_mixedMutedAndNonMuted_filtersCorrectly() async {
        // Given - mute one author
        await MainActor.run {
            _ = inboxManager.mute(type: .author, value: "BadAuthorMixed")
        }

        let batch = UUID().uuidString
        let results = [
            createTestSearchResult(
                id: "mixed-a-\(batch)",
                title: "Good Paper",
                authors: ["GoodAuthor, A."]
            ),
            createTestSearchResult(
                id: "mixed-b-\(batch)",
                title: "Muted Paper",
                authors: ["BadAuthorMixed, B."]  // Matches muted author
            ),
            createTestSearchResult(
                id: "mixed-c-\(batch)",
                title: "Another Good Paper",
                authors: ["GoodAuthor, C."]
            )
        ]

        // When
        let count = await fetchService.sendToInbox(results: results)

        // Then - only 2 should pass (1 filtered by mute)
        XCTAssertEqual(count, 2)
    }

    // MARK: - Helpers

    private func createTestSearchResult(
        id: String,
        title: String,
        authors: [String],
        doi: String? = nil,
        venue: String? = nil,
        arxivID: String? = nil
    ) -> SearchResult {
        SearchResult(
            id: id,
            sourceID: "test",
            title: title,
            authors: authors,
            year: 2024,
            venue: venue,
            abstract: "Test abstract",
            doi: doi,
            arxivID: arxivID
        )
    }

    @MainActor
    private func createTestLibrary(name: String) -> CDLibrary {
        let context = persistenceController.viewContext
        let lib = CDLibrary(context: context)
        lib.id = UUID()
        lib.name = name
        lib.isInbox = false
        lib.isDefault = false
        lib.dateCreated = Date()
        lib.sortOrder = 0
        return lib
    }

    @MainActor
    private func createTestSmartSearch(
        name: String,
        query: String,
        library: CDLibrary,
        feedsToInbox: Bool
    ) -> CDSmartSearch {
        let context = persistenceController.viewContext
        let ss = CDSmartSearch(context: context)
        ss.id = UUID()
        ss.name = name
        ss.query = query
        ss.library = library
        ss.feedsToInbox = feedsToInbox
        ss.autoRefreshEnabled = false
        ss.refreshIntervalSeconds = 3600
        ss.maxResults = 50
        ss.order = 0
        ss.dateCreated = Date()
        return ss
    }
}
