//
//  LibraryDeduplicationTests.swift
//  PublicationManagerCoreTests
//
//  Tests for the library deduplication service.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

@MainActor
final class LibraryDeduplicationTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var context: NSManagedObjectContext!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.viewContext
    }

    override func tearDown() {
        persistenceController = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createLibrary(
        name: String,
        id: UUID = UUID(),
        dateCreated: Date = Date(),
        isDefault: Bool = false
    ) -> CDLibrary {
        let library = CDLibrary(context: context)
        library.id = id
        library.name = name
        library.dateCreated = dateCreated
        library.isDefault = isDefault
        library.isSystemLibrary = false
        library.isLocalOnly = false
        return library
    }

    private func createPublication(title: String) -> CDPublication {
        let pub = CDPublication(context: context)
        pub.id = UUID()
        pub.citeKey = title.lowercased().replacingOccurrences(of: " ", with: "_")
        pub.title = title
        pub.entryType = "article"
        pub.dateAdded = Date()
        pub.dateModified = Date()
        pub.citationCount = -1
        pub.referenceCount = -1
        return pub
    }

    private func createCollection(name: String, in library: CDLibrary) -> CDCollection {
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = name
        collection.library = library
        collection.isSmartCollection = false
        return collection
    }

    private func createSmartSearch(name: String, query: String, in library: CDLibrary) -> CDSmartSearch {
        let search = CDSmartSearch(context: context)
        search.id = UUID()
        search.name = name
        search.query = query
        search.library = library
        search.dateCreated = Date()
        return search
    }

    // MARK: - Canonical ID Deduplication Tests

    func testMergesLibrariesWithCanonicalID() async throws {
        // Given: Two libraries with the canonical default ID (simulating cross-device creation)
        let lib1 = createLibrary(
            name: "My Library",
            id: CDLibrary.canonicalDefaultLibraryID,
            dateCreated: Date().addingTimeInterval(-3600)  // 1 hour ago
        )
        let lib2 = createLibrary(
            name: "My Library",
            id: CDLibrary.canonicalDefaultLibraryID,
            dateCreated: Date()  // Now
        )

        // Add publications to each
        let pub1 = createPublication(title: "Paper 1")
        pub1.addToLibrary(lib1)
        let pub2 = createPublication(title: "Paper 2")
        pub2.addToLibrary(lib2)

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: Libraries should be merged
        XCTAssertEqual(results.count, 1, "Should have one merge result")

        let result = results.first!
        XCTAssertEqual(result.keptLibraryID, CDLibrary.canonicalDefaultLibraryID)
        XCTAssertEqual(result.publicationsMoved, 1)  // pub2 moved to lib1

        // Verify only one library remains
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isSystemLibrary == NO")
        let remainingLibraries = try context.fetch(request)
        XCTAssertEqual(remainingLibraries.count, 1)

        // Verify both publications are in the kept library
        let keptLibrary = remainingLibraries.first!
        XCTAssertEqual(keptLibrary.publications?.count, 2)
    }

    func testMergesNameBasedDuplicatesWithinTimeWindow() async throws {
        // Given: Two libraries with the same name created within 24 hours
        let baseTime = Date()
        let lib1 = createLibrary(
            name: "Research Papers",
            dateCreated: baseTime.addingTimeInterval(-3600)  // 1 hour ago
        )
        let lib2 = createLibrary(
            name: "Research Papers",
            dateCreated: baseTime  // Now
        )

        let pub1 = createPublication(title: "Paper 1")
        pub1.addToLibrary(lib1)
        let pub2 = createPublication(title: "Paper 2")
        pub2.addToLibrary(lib2)

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: Libraries should be merged (same name within 24h)
        XCTAssertEqual(results.count, 1, "Should merge libraries with same name within 24h")
    }

    func testDoesNotMergeNameBasedDuplicatesOutsideTimeWindow() async throws {
        // Given: Two libraries with the same name created more than 24 hours apart
        let baseTime = Date()
        let lib1 = createLibrary(
            name: "Research Papers",
            dateCreated: baseTime.addingTimeInterval(-100_000)  // ~28 hours ago
        )
        let lib2 = createLibrary(
            name: "Research Papers",
            dateCreated: baseTime  // Now
        )

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: Libraries should NOT be merged (outside 24h window)
        XCTAssertEqual(results.count, 0, "Should not merge libraries created > 24h apart")

        // Verify both libraries still exist
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isSystemLibrary == NO")
        let libraries = try context.fetch(request)
        XCTAssertEqual(libraries.count, 2)
    }

    func testDoesNotMergeDifferentlyNamedLibraries() async throws {
        // Given: Two libraries with different names
        _ = createLibrary(name: "Work Papers")
        _ = createLibrary(name: "Personal Papers")

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: No merge should occur
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Data Migration Tests

    func testMigratesPublicationsDuringMerge() async throws {
        // Given: Two libraries with publications
        let lib1 = createLibrary(name: "My Library", dateCreated: Date().addingTimeInterval(-3600))
        let lib2 = createLibrary(name: "My Library", dateCreated: Date())

        let pub1 = createPublication(title: "Paper 1")
        let pub2 = createPublication(title: "Paper 2")
        let pub3 = createPublication(title: "Paper 3")

        pub1.addToLibrary(lib1)
        pub2.addToLibrary(lib2)
        pub3.addToLibrary(lib2)

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: All publications should be in the kept library
        XCTAssertEqual(results.first?.publicationsMoved, 2)

        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "isSystemLibrary == NO")
        let libraries = try context.fetch(request)
        let keptLibrary = libraries.first!

        XCTAssertEqual(keptLibrary.publications?.count, 3)
    }

    func testMigratesCollectionsDuringMerge() async throws {
        // Given: Two libraries with collections
        let lib1 = createLibrary(name: "My Library", dateCreated: Date().addingTimeInterval(-3600))
        let lib2 = createLibrary(name: "My Library", dateCreated: Date())

        _ = createCollection(name: "Collection A", in: lib1)
        _ = createCollection(name: "Collection B", in: lib2)
        _ = createCollection(name: "Collection C", in: lib2)

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: All collections should be in the kept library
        XCTAssertEqual(results.first?.collectionsMoved, 2)
    }

    func testMigratesSmartSearchesDuringMerge() async throws {
        // Given: Two libraries with smart searches
        let lib1 = createLibrary(name: "My Library", dateCreated: Date().addingTimeInterval(-3600))
        let lib2 = createLibrary(name: "My Library", dateCreated: Date())

        _ = createSmartSearch(name: "Search A", query: "cosmology", in: lib1)
        _ = createSmartSearch(name: "Search B", query: "machine learning", in: lib2)

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: All smart searches should be in the kept library
        XCTAssertEqual(results.first?.smartSearchesMoved, 1)
    }

    // MARK: - Edge Cases

    func testNoDuplicates() async throws {
        // Given: Libraries with unique names
        _ = createLibrary(name: "Library A")
        _ = createLibrary(name: "Library B")
        _ = createLibrary(name: "Library C")

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: No merges should occur
        XCTAssertEqual(results.count, 0)
    }

    func testEmptyDatabase() async throws {
        // Given: No libraries
        // (empty in-memory store)

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: Should handle gracefully with no results
        XCTAssertEqual(results.count, 0)
    }

    func testIgnoresSystemLibraries() async throws {
        // Given: Two "Exploration" system libraries (from different devices in CloudKit)
        let lib1 = CDLibrary(context: context)
        lib1.id = UUID()
        lib1.name = "Exploration"
        lib1.dateCreated = Date().addingTimeInterval(-3600)
        lib1.isSystemLibrary = true
        lib1.isLocalOnly = true

        let lib2 = CDLibrary(context: context)
        lib2.id = UUID()
        lib2.name = "Exploration"
        lib2.dateCreated = Date()
        lib2.isSystemLibrary = true
        lib2.isLocalOnly = true

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: System libraries should not be merged
        XCTAssertEqual(results.count, 0, "Should not merge system libraries")
    }

    func testIgnoresLocalOnlyLibraries() async throws {
        // Given: Two local-only libraries with the same name
        let lib1 = createLibrary(name: "Local Work", dateCreated: Date().addingTimeInterval(-3600))
        lib1.isLocalOnly = true

        let lib2 = createLibrary(name: "Local Work", dateCreated: Date())
        lib2.isLocalOnly = true

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: Local-only libraries should not be merged
        XCTAssertEqual(results.count, 0, "Should not merge local-only libraries")
    }

    func testNameNormalization() async throws {
        // Given: Libraries with names that differ only in case/whitespace
        let lib1 = createLibrary(name: "My Library", dateCreated: Date().addingTimeInterval(-3600))
        let lib2 = createLibrary(name: "  my library  ", dateCreated: Date())

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: Should merge (names normalize to same string)
        XCTAssertEqual(results.count, 1, "Should merge libraries with equivalent names")
    }

    // MARK: - Merge Priority Tests

    func testKeepsOldestLibrary() async throws {
        // Given: Three libraries with the same name at different times
        let oldest = createLibrary(name: "Papers", dateCreated: Date().addingTimeInterval(-7200))
        let middle = createLibrary(name: "Papers", dateCreated: Date().addingTimeInterval(-3600))
        let newest = createLibrary(name: "Papers", dateCreated: Date())

        // Add distinct publications to verify merge direction
        let pubOldest = createPublication(title: "Oldest Paper")
        pubOldest.addToLibrary(oldest)

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: Should keep the oldest library
        XCTAssertEqual(results.first?.keptLibraryID, oldest.id)
        XCTAssertEqual(results.first?.mergedLibraryIDs.count, 2)
    }

    func testPrefersCanonicalIDOverAge() async throws {
        // Given: An older library and a newer one with canonical ID
        let older = createLibrary(
            name: "My Library",
            dateCreated: Date().addingTimeInterval(-7200)
        )
        let canonical = createLibrary(
            name: "My Library",
            id: CDLibrary.canonicalDefaultLibraryID,
            dateCreated: Date()  // Newer but has canonical ID
        )

        try context.save()

        // When: Running deduplication
        let service = LibraryDeduplicationService(persistenceController: persistenceController)
        let results = await service.deduplicateLibraries()

        // Then: Should keep the canonical ID library
        XCTAssertEqual(results.first?.keptLibraryID, CDLibrary.canonicalDefaultLibraryID)
    }
}
