//
//  IdentifierCacheTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class IdentifierCacheTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var cache: IdentifierCache!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview

        // Clean up entities
        await cleanupEntities()

        cache = IdentifierCache(persistenceController: persistenceController)
    }

    override func tearDown() async throws {
        await cleanupEntities()
        cache = nil
        try await super.tearDown()
    }

    private func cleanupEntities() async {
        await MainActor.run {
            let context = persistenceController.viewContext

            let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
            let pubs = try? context.fetch(pubRequest)
            pubs?.forEach { context.delete($0) }

            try? context.save()
        }
    }

    // MARK: - Initial State Tests

    func testInitialCache_isEmpty() async {
        // When - fresh cache without loading
        let doiCount = await cache.doiCount
        let arxivCount = await cache.arxivIDCount
        let bibcodeCount = await cache.bibcodeCount
        let ssCount = await cache.semanticScholarIDCount
        let oaCount = await cache.openAlexIDCount

        // Then
        XCTAssertEqual(doiCount, 0)
        XCTAssertEqual(arxivCount, 0)
        XCTAssertEqual(bibcodeCount, 0)
        XCTAssertEqual(ssCount, 0)
        XCTAssertEqual(oaCount, 0)
    }

    // MARK: - Load from Database Tests

    func testLoadFromDatabase_emptyDatabase_remainsEmpty() async {
        // Given - empty database

        // When
        await cache.loadFromDatabase()

        // Then
        let total = await cache.totalEntries
        XCTAssertEqual(total, 0)
    }

    func testLoadFromDatabase_withPublications_loadsIdentifiers() async {
        // Given - create publication with identifiers
        await MainActor.run {
            let context = persistenceController.viewContext
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "Test2024"
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.doi = "10.1234/test"
            pub.semanticScholarID = "ss12345"
            pub.openAlexID = "oa12345"
            pub.arxivIDNormalized = "2301.12345"
            pub.bibcodeNormalized = "2024APJ...123..456T"
            try? context.save()
        }

        // When
        await cache.loadFromDatabase()

        // Then
        let doiCount = await cache.doiCount
        let arxivCount = await cache.arxivIDCount
        let bibcodeCount = await cache.bibcodeCount
        let ssCount = await cache.semanticScholarIDCount
        let oaCount = await cache.openAlexIDCount

        XCTAssertEqual(doiCount, 1)
        XCTAssertEqual(arxivCount, 1)
        XCTAssertEqual(bibcodeCount, 1)
        XCTAssertEqual(ssCount, 1)
        XCTAssertEqual(oaCount, 1)
    }

    // MARK: - Exists Tests

    func testExists_matchingDOI_returnsTrue() async {
        // Given
        await MainActor.run {
            let context = persistenceController.viewContext
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "Test2024"
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.doi = "10.1234/existing"
            try? context.save()
        }
        await cache.loadFromDatabase()

        let result = SearchResult(
            id: "test",
            sourceID: "test",
            title: "Test Paper",
            authors: ["Author, A."],
            year: 2024,
            doi: "10.1234/existing"
        )

        // When
        let exists = await cache.exists(result)

        // Then
        XCTAssertTrue(exists)
    }

    func testExists_matchingArxivID_returnsTrue() async {
        // Given
        await MainActor.run {
            let context = persistenceController.viewContext
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "Test2024"
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.arxivIDNormalized = "2301.12345"
            try? context.save()
        }
        await cache.loadFromDatabase()

        let result = SearchResult(
            id: "test",
            sourceID: "test",
            title: "Test Paper",
            authors: ["Author, A."],
            year: 2024,
            arxivID: "2301.12345v2"  // With version suffix
        )

        // When
        let exists = await cache.exists(result)

        // Then
        XCTAssertTrue(exists)
    }

    func testExists_matchingBibcode_returnsTrue() async {
        // Given
        await MainActor.run {
            let context = persistenceController.viewContext
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "Test2024"
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.bibcodeNormalized = "2024APJ...123..456T"
            try? context.save()
        }
        await cache.loadFromDatabase()

        let result = SearchResult(
            id: "test",
            sourceID: "test",
            title: "Test Paper",
            authors: ["Author, A."],
            year: 2024,
            bibcode: "2024apj...123..456t"  // Lowercase
        )

        // When
        let exists = await cache.exists(result)

        // Then
        XCTAssertTrue(exists)
    }

    func testExists_noMatchingIdentifiers_returnsFalse() async {
        // Given
        await MainActor.run {
            let context = persistenceController.viewContext
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "Test2024"
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.doi = "10.1234/existing"
            try? context.save()
        }
        await cache.loadFromDatabase()

        let result = SearchResult(
            id: "test",
            sourceID: "test",
            title: "Test Paper",
            authors: ["Author, A."],
            year: 2024,
            doi: "10.1234/different"  // Different DOI
        )

        // When
        let exists = await cache.exists(result)

        // Then
        XCTAssertFalse(exists)
    }

    // MARK: - Add Tests

    func testAdd_publication_updatesCache() async {
        // Given
        await cache.loadFromDatabase()
        let initialCount = await cache.doiCount
        XCTAssertEqual(initialCount, 0)

        // Extract identifiers on main actor (thread-safe pattern)
        let doi: String? = await MainActor.run {
            let context = persistenceController.viewContext
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "Test2024"
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.doi = "10.1234/new"
            return pub.doi
        }

        // When - pass pre-extracted values to actor
        await cache.add(
            doi: doi,
            arxivID: nil,
            bibcode: nil,
            semanticScholarID: nil,
            openAlexID: nil
        )

        // Then
        let newCount = await cache.doiCount
        XCTAssertEqual(newCount, 1)
    }

    func testAddFromResult_preventsWithinBatchDuplicates() async {
        // Given
        await cache.loadFromDatabase()

        let result = SearchResult(
            id: "test",
            sourceID: "test",
            title: "Test Paper",
            authors: ["Author, A."],
            year: 2024,
            doi: "10.1234/batch"
        )

        // When - add from result (without creating publication)
        await cache.addFromResult(result)

        // Then - same result should now show as existing
        let exists = await cache.exists(result)
        XCTAssertTrue(exists)
    }

    // MARK: - Case Sensitivity Tests

    func testExists_DOI_caseInsensitive() async {
        // Given
        await MainActor.run {
            let context = persistenceController.viewContext
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "Test2024"
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.doi = "10.1234/UPPERCASE"
            try? context.save()
        }
        await cache.loadFromDatabase()

        let result = SearchResult(
            id: "test",
            sourceID: "test",
            title: "Test Paper",
            authors: ["Author, A."],
            year: 2024,
            doi: "10.1234/uppercase"  // Lowercase
        )

        // When
        let exists = await cache.exists(result)

        // Then
        XCTAssertTrue(exists)
    }
}
