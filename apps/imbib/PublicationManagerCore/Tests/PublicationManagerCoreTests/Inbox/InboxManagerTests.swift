//
//  InboxManagerTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

@MainActor
final class InboxManagerTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var inboxManager: InboxManager!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview
        inboxManager = InboxManager(persistenceController: persistenceController)
    }

    override func tearDown() async throws {
        // Clean up any created entities
        let context = persistenceController.viewContext

        // Delete all publications
        let pubRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
        let pubs = try? context.fetch(pubRequest)
        pubs?.forEach { context.delete($0) }

        // Delete all libraries
        let libRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
        let libs = try? context.fetch(libRequest)
        libs?.forEach { context.delete($0) }

        // Delete all muted items
        let muteRequest = NSFetchRequest<CDMutedItem>(entityName: "MutedItem")
        let mutes = try? context.fetch(muteRequest)
        mutes?.forEach { context.delete($0) }

        try? context.save()

        inboxManager = nil
        try await super.tearDown()
    }

    // MARK: - Inbox Library Management Tests

    func testGetOrCreateInbox_createsNewInbox_whenNoneExists() {
        // Given: No inbox exists yet (fresh manager)

        // When
        let inbox = inboxManager.getOrCreateInbox()

        // Then
        XCTAssertNotNil(inbox)
        XCTAssertTrue(inbox.isInbox)
        XCTAssertEqual(inbox.name, "Inbox")
        XCTAssertEqual(inbox.sortOrder, -1) // Always at top
    }

    func testGetOrCreateInbox_returnsSameInbox_onSubsequentCalls() {
        // Given
        let firstInbox = inboxManager.getOrCreateInbox()

        // When
        let secondInbox = inboxManager.getOrCreateInbox()

        // Then
        XCTAssertEqual(firstInbox.id, secondInbox.id)
    }

    func testInboxLibrary_hasIsInboxFlag_setToTrue() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()

        // Then
        XCTAssertTrue(inbox.isInbox)
        XCTAssertFalse(inbox.isDefault)
    }

    // MARK: - Unread Count Tests

    func testUpdateUnreadCount_countsUnreadPapers() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let pub1 = createTestPublication(citeKey: "Test2024a")
        let pub2 = createTestPublication(citeKey: "Test2024b")
        pub1.addToLibrary(inbox)
        pub2.addToLibrary(inbox)
        pub1.isRead = false
        pub2.isRead = false
        persistenceController.save()

        // When
        inboxManager.updateUnreadCount()

        // Then
        XCTAssertEqual(inboxManager.unreadCount, 2)
    }

    func testMarkAsRead_decrementsUnreadCount() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let pub = createTestPublication(citeKey: "Test2024")
        pub.addToLibrary(inbox)
        pub.isRead = false
        persistenceController.save()
        inboxManager.updateUnreadCount()
        XCTAssertEqual(inboxManager.unreadCount, 1)

        // When
        inboxManager.markAsRead(pub)

        // Then
        XCTAssertEqual(inboxManager.unreadCount, 0)
        XCTAssertTrue(pub.isRead)
    }

    func testMarkAllAsRead_setsUnreadCountToZero() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let pub1 = createTestPublication(citeKey: "Test2024a")
        let pub2 = createTestPublication(citeKey: "Test2024b")
        pub1.addToLibrary(inbox)
        pub2.addToLibrary(inbox)
        pub1.isRead = false
        pub2.isRead = false
        persistenceController.save()
        inboxManager.updateUnreadCount()
        XCTAssertEqual(inboxManager.unreadCount, 2)

        // When
        inboxManager.markAllAsRead()

        // Then
        XCTAssertEqual(inboxManager.unreadCount, 0)
        XCTAssertTrue(pub1.isRead)
        XCTAssertTrue(pub2.isRead)
    }

    // MARK: - Mute Filtering Tests

    func testShouldFilter_author_matchesPartialName() {
        // Given
        _ = inboxManager.mute(type: .author, value: "Einstein")

        // When/Then
        XCTAssertTrue(inboxManager.shouldFilter(
            id: "test",
            authors: ["Albert Einstein", "Max Planck"],
            doi: nil,
            venue: nil,
            arxivID: nil
        ))
    }

    func testShouldFilter_author_caseInsensitive() {
        // Given
        _ = inboxManager.mute(type: .author, value: "EINSTEIN")

        // When/Then
        XCTAssertTrue(inboxManager.shouldFilter(
            id: "test",
            authors: ["albert einstein"],
            doi: nil,
            venue: nil,
            arxivID: nil
        ))
    }

    func testShouldFilter_doi_exactMatch() {
        // Given
        _ = inboxManager.mute(type: .doi, value: "10.1234/test.2024")

        // When/Then
        XCTAssertTrue(inboxManager.shouldFilter(
            id: "test",
            authors: [],
            doi: "10.1234/test.2024",
            venue: nil,
            arxivID: nil
        ))

        // Partial match should NOT filter
        XCTAssertFalse(inboxManager.shouldFilter(
            id: "test",
            authors: [],
            doi: "10.1234/test",
            venue: nil,
            arxivID: nil
        ))
    }

    func testShouldFilter_bibcode_exactMatch() {
        // Given
        _ = inboxManager.mute(type: .bibcode, value: "2024ApJ...123..456E")

        // When/Then
        XCTAssertTrue(inboxManager.shouldFilter(
            id: "2024ApJ...123..456E",
            authors: [],
            doi: nil,
            venue: nil,
            arxivID: nil
        ))
    }

    func testShouldFilter_venue_containsMatch() {
        // Given
        _ = inboxManager.mute(type: .venue, value: "Nature")

        // When/Then
        XCTAssertTrue(inboxManager.shouldFilter(
            id: "test",
            authors: [],
            doi: nil,
            venue: "Nature Physics",
            arxivID: nil
        ))
    }

    func testShouldFilter_arxivCategory_prefixMatch() {
        // Given
        _ = inboxManager.mute(type: .arxivCategory, value: "astro-ph")

        // When/Then
        XCTAssertTrue(inboxManager.shouldFilter(
            id: "test",
            authors: [],
            doi: nil,
            venue: nil,
            arxivID: "astro-ph.CO/2024.12345"
        ))

        // Different category should NOT filter
        XCTAssertFalse(inboxManager.shouldFilter(
            id: "test",
            authors: [],
            doi: nil,
            venue: nil,
            arxivID: "hep-ph/2024.12345"
        ))
    }

    func testShouldFilter_multipleMutes_anyMatchReturnsTrue() {
        // Given
        _ = inboxManager.mute(type: .author, value: "Smith")
        _ = inboxManager.mute(type: .venue, value: "Science")

        // When/Then - matches venue
        XCTAssertTrue(inboxManager.shouldFilter(
            id: "test",
            authors: ["Jones"],
            doi: nil,
            venue: "Science",
            arxivID: nil
        ))

        // When/Then - matches author
        XCTAssertTrue(inboxManager.shouldFilter(
            id: "test",
            authors: ["John Smith"],
            doi: nil,
            venue: "Nature",
            arxivID: nil
        ))
    }

    func testShouldFilter_noMutes_returnsFalse() {
        // Given: no mutes configured

        // When/Then
        XCTAssertFalse(inboxManager.shouldFilter(
            id: "test",
            authors: ["Einstein"],
            doi: "10.1234/test",
            venue: "Nature",
            arxivID: "astro-ph/2024.12345"
        ))
    }

    // MARK: - Mute CRUD Tests

    func testMute_createsNewMutedItem() {
        // When
        let item = inboxManager.mute(type: .author, value: "Einstein")

        // Then
        XCTAssertNotNil(item)
        XCTAssertEqual(item.type, "author")
        XCTAssertEqual(item.value, "Einstein")
        XCTAssertEqual(inboxManager.mutedItems.count, 1)
    }

    func testMute_duplicateValue_returnsExisting() {
        // Given
        let first = inboxManager.mute(type: .author, value: "Einstein")

        // When
        let second = inboxManager.mute(type: .author, value: "Einstein")

        // Then
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(inboxManager.mutedItems.count, 1)
    }

    func testUnmute_removesMutedItem() {
        // Given
        let item = inboxManager.mute(type: .author, value: "Einstein")
        XCTAssertEqual(inboxManager.mutedItems.count, 1)

        // When
        inboxManager.unmute(item)

        // Then
        XCTAssertEqual(inboxManager.mutedItems.count, 0)
    }

    func testClearAllMutedItems_removesAll() {
        // Given
        _ = inboxManager.mute(type: .author, value: "Einstein")
        _ = inboxManager.mute(type: .venue, value: "Nature")
        _ = inboxManager.mute(type: .doi, value: "10.1234/test")
        XCTAssertEqual(inboxManager.mutedItems.count, 3)

        // When
        inboxManager.clearAllMutedItems()

        // Then
        XCTAssertEqual(inboxManager.mutedItems.count, 0)
    }

    func testMutedItemsOfType_filtersCorrectly() {
        // Given
        _ = inboxManager.mute(type: .author, value: "Einstein")
        _ = inboxManager.mute(type: .author, value: "Planck")
        _ = inboxManager.mute(type: .venue, value: "Nature")

        // When
        let authors = inboxManager.mutedItems(ofType: .author)
        let venues = inboxManager.mutedItems(ofType: .venue)

        // Then
        XCTAssertEqual(authors.count, 2)
        XCTAssertEqual(venues.count, 1)
    }

    // MARK: - Paper Operations Tests

    func testAddToInbox_addsPaperToInboxLibrary() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let pub = createTestPublication(citeKey: "Test2024")

        // When
        inboxManager.addToInbox(pub)

        // Then
        XCTAssertTrue(pub.libraries?.contains(inbox) ?? false)
    }

    func testAddToInbox_marksPaperAsUnread() {
        // Given
        let pub = createTestPublication(citeKey: "Test2024")
        pub.isRead = true

        // When
        inboxManager.addToInbox(pub)

        // Then
        XCTAssertFalse(pub.isRead)
    }

    func testAddToInbox_alreadyInInbox_doesNotDuplicate() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let pub = createTestPublication(citeKey: "Test2024")
        inboxManager.addToInbox(pub)

        // When
        inboxManager.addToInbox(pub)

        // Then - should still only be in inbox once
        let libs = pub.libraries?.filter { $0.isInbox } ?? []
        XCTAssertEqual(libs.count, 1)
    }

    func testDismissFromInbox_removesPaperFromInbox() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let otherLib = createTestLibrary(name: "My Library")
        let pub = createTestPublication(citeKey: "Test2024")
        pub.addToLibrary(inbox)
        pub.addToLibrary(otherLib)
        persistenceController.save()

        // When
        inboxManager.dismissFromInbox(pub)

        // Then
        XCTAssertFalse(pub.libraries?.contains(inbox) ?? true)
        XCTAssertTrue(pub.libraries?.contains(otherLib) ?? false)
    }

    func testDismissFromInbox_deletesPaper_whenNotInOtherLibraries() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let pub = createTestPublication(citeKey: "Test2024")
        pub.addToLibrary(inbox)
        persistenceController.save()
        let pubID = pub.id

        // When
        inboxManager.dismissFromInbox(pub)

        // Then - paper should be deleted
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", pubID as CVarArg)
        let results = try? persistenceController.viewContext.fetch(request)
        XCTAssertEqual(results?.count ?? 0, 0)
    }

    func testKeepToLibrary_addsPaperToTargetLibrary() {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let targetLib = createTestLibrary(name: "Keep")
        let pub = createTestPublication(citeKey: "Test2024")
        pub.addToLibrary(inbox)
        persistenceController.save()

        // When
        inboxManager.keepToLibrary(pub, library: targetLib)

        // Then
        XCTAssertTrue(pub.libraries?.contains(targetLib) ?? false)
    }

    func testGetInboxPapers_returnsAllPapersInInbox() async {
        // Given
        let inbox = inboxManager.getOrCreateInbox()
        let pub1 = createTestPublication(citeKey: "Test2024a")
        let pub2 = createTestPublication(citeKey: "Test2024b")
        pub1.addToLibrary(inbox)
        pub2.addToLibrary(inbox)
        persistenceController.save()

        // When
        let papers = await inboxManager.getInboxPapers()

        // Then
        XCTAssertEqual(papers.count, 2)
    }

    // MARK: - Helpers

    private func createTestPublication(citeKey: String) -> CDPublication {
        let context = persistenceController.viewContext
        let pub = CDPublication(context: context)
        pub.id = UUID()
        pub.citeKey = citeKey
        pub.title = "Test Publication"
        pub.entryType = "article"
        pub.dateAdded = Date()
        pub.isRead = false
        return pub
    }

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
}
