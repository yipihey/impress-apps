//
//  ShareExtensionServiceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-07.
//

import XCTest
@testable import PublicationManagerCore

final class ShareExtensionServiceTests: XCTestCase {

    // MARK: - Properties

    private var service: ShareExtensionService!
    private var testDefaults: UserDefaults!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        service = ShareExtensionService.shared
        // Clear any existing items before each test
        service.clearPendingItems()
    }

    override func tearDown() {
        // Clean up after tests
        service.clearPendingItems()
        super.tearDown()
    }

    // MARK: - SharedItem Tests

    func testSharedItem_initialization_setsAllProperties() {
        let id = UUID()
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!
        let name = "Test Search"
        let query = "author:Abel"
        let libraryID = UUID()
        let createdAt = Date()

        let item = ShareExtensionService.SharedItem(
            id: id,
            url: url,
            type: .smartSearch,
            name: name,
            query: query,
            libraryID: libraryID,
            createdAt: createdAt
        )

        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.type, .smartSearch)
        XCTAssertEqual(item.name, name)
        XCTAssertEqual(item.query, query)
        XCTAssertEqual(item.libraryID, libraryID)
        XCTAssertEqual(item.createdAt, createdAt)
    }

    func testSharedItem_defaultValues() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B")!

        let item = ShareExtensionService.SharedItem(
            url: url,
            type: .paper,
            name: nil,
            libraryID: nil
        )

        XCTAssertNotEqual(item.id, UUID()) // Should have generated a UUID
        XCTAssertNil(item.name)
        XCTAssertNil(item.query)
        XCTAssertNil(item.libraryID)
    }

    func testSharedItem_equatable() {
        let id = UUID()
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!

        let item1 = ShareExtensionService.SharedItem(
            id: id,
            url: url,
            type: .smartSearch,
            name: "Test",
            libraryID: nil
        )

        let item2 = ShareExtensionService.SharedItem(
            id: id,
            url: url,
            type: .smartSearch,
            name: "Test",
            libraryID: nil
        )

        XCTAssertEqual(item1, item2)
    }

    func testSharedItem_codable() throws {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!
        let libraryID = UUID()

        let item = ShareExtensionService.SharedItem(
            url: url,
            type: .smartSearch,
            name: "Test Search",
            query: "author:Abel",
            libraryID: libraryID
        )

        // Encode
        let data = try JSONEncoder().encode(item)

        // Decode
        let decoded = try JSONDecoder().decode(ShareExtensionService.SharedItem.self, from: data)

        XCTAssertEqual(decoded.id, item.id)
        XCTAssertEqual(decoded.url, item.url)
        XCTAssertEqual(decoded.type, item.type)
        XCTAssertEqual(decoded.name, item.name)
        XCTAssertEqual(decoded.query, item.query)
        XCTAssertEqual(decoded.libraryID, item.libraryID)
    }

    // MARK: - ItemType Tests

    func testItemType_rawValues() {
        XCTAssertEqual(ShareExtensionService.SharedItem.ItemType.smartSearch.rawValue, "smartSearch")
        XCTAssertEqual(ShareExtensionService.SharedItem.ItemType.paper.rawValue, "paper")
        XCTAssertEqual(ShareExtensionService.SharedItem.ItemType.docsSelection.rawValue, "docsSelection")
    }

    func testItemType_codable() throws {
        let types: [ShareExtensionService.SharedItem.ItemType] = [.smartSearch, .paper, .docsSelection]

        for type in types {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(ShareExtensionService.SharedItem.ItemType.self, from: data)
            XCTAssertEqual(decoded, type)
        }
    }

    // MARK: - Queue Smart Search Tests

    func testQueueSmartSearch_addsItemToQueue() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=author%3AAbel")!
        let name = "Abel Papers"
        let libraryID = UUID()

        service.queueSmartSearch(url: url, name: name, libraryID: libraryID)

        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 1)

        let item = items.first!
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.type, .smartSearch)
        XCTAssertEqual(item.name, name)
        XCTAssertEqual(item.libraryID, libraryID)
    }

    func testQueueSmartSearch_nilLibraryID() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!

        service.queueSmartSearch(url: url, name: "Test", libraryID: nil)

        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.libraryID)
    }

    func testQueueSmartSearch_multipleItems() {
        let url1 = URL(string: "https://ui.adsabs.harvard.edu/search/q=test1")!
        let url2 = URL(string: "https://ui.adsabs.harvard.edu/search/q=test2")!

        service.queueSmartSearch(url: url1, name: "Test 1", libraryID: nil)
        service.queueSmartSearch(url: url2, name: "Test 2", libraryID: nil)

        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 2)
    }

    // MARK: - Queue Paper Import Tests

    func testQueuePaperImport_addsItemToQueue() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B/abstract")!
        let libraryID = UUID()

        service.queuePaperImport(url: url, libraryID: libraryID)

        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 1)

        let item = items.first!
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.type, .paper)
        XCTAssertNil(item.name)
        XCTAssertEqual(item.libraryID, libraryID)
    }

    func testQueuePaperImport_toInbox() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B")!

        service.queuePaperImport(url: url, libraryID: nil)

        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.libraryID)
    }

    // MARK: - Queue Docs Selection Tests

    func testQueueDocsSelection_addsItemToQueue() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(cfcf0423d46d0bd5222cb1392a6ec63f)")!
        let query = "docs(cfcf0423d46d0bd5222cb1392a6ec63f)"

        service.queueDocsSelection(url: url, query: query)

        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 1)

        let item = items.first!
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.type, .docsSelection)
        XCTAssertEqual(item.query, query)
        XCTAssertNil(item.libraryID) // Always to Inbox
    }

    func testQueueDocsSelection_alwaysToInbox() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(abc)")!

        service.queueDocsSelection(url: url, query: "docs(abc)")

        let items = service.getPendingItems()
        XCTAssertNil(items.first?.libraryID)
    }

    // MARK: - Get Pending Items Tests

    func testGetPendingItems_emptyQueue() {
        let items = service.getPendingItems()
        XCTAssertTrue(items.isEmpty)
    }

    func testGetPendingItems_preservesOrder() {
        let urls = (1...5).map { URL(string: "https://ui.adsabs.harvard.edu/search/q=test\($0)")! }

        for (i, url) in urls.enumerated() {
            service.queueSmartSearch(url: url, name: "Test \(i)", libraryID: nil)
        }

        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 5)

        // Items should be in the order they were added
        for (i, item) in items.enumerated() {
            XCTAssertEqual(item.name, "Test \(i)")
        }
    }

    func testGetPendingItems_mixedTypes() {
        let searchURL = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!
        let paperURL = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B")!
        let docsURL = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(abc)")!

        service.queueSmartSearch(url: searchURL, name: "Search", libraryID: nil)
        service.queuePaperImport(url: paperURL, libraryID: nil)
        service.queueDocsSelection(url: docsURL, query: "docs(abc)")

        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].type, .smartSearch)
        XCTAssertEqual(items[1].type, .paper)
        XCTAssertEqual(items[2].type, .docsSelection)
    }

    // MARK: - Remove Item Tests

    func testRemoveItem_removesCorrectItem() {
        let url1 = URL(string: "https://ui.adsabs.harvard.edu/search/q=test1")!
        let url2 = URL(string: "https://ui.adsabs.harvard.edu/search/q=test2")!

        service.queueSmartSearch(url: url1, name: "Test 1", libraryID: nil)
        service.queueSmartSearch(url: url2, name: "Test 2", libraryID: nil)

        var items = service.getPendingItems()
        XCTAssertEqual(items.count, 2)

        // Remove first item
        service.removeItem(items[0])

        items = service.getPendingItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Test 2")
    }

    func testRemoveItem_nonexistentItem() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!

        service.queueSmartSearch(url: url, name: "Test", libraryID: nil)

        // Create a new item that's not in the queue
        let fakeItem = ShareExtensionService.SharedItem(
            url: url,
            type: .smartSearch,
            name: "Fake",
            libraryID: nil
        )

        // Should not crash
        service.removeItem(fakeItem)

        // Original item should still be there
        let items = service.getPendingItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Test")
    }

    func testRemoveItem_allItems() {
        let urls = (1...3).map { URL(string: "https://ui.adsabs.harvard.edu/search/q=test\($0)")! }

        for (i, url) in urls.enumerated() {
            service.queueSmartSearch(url: url, name: "Test \(i)", libraryID: nil)
        }

        var items = service.getPendingItems()
        XCTAssertEqual(items.count, 3)

        // Remove all items one by one
        for item in items {
            service.removeItem(item)
        }

        items = service.getPendingItems()
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Clear Pending Items Tests

    func testClearPendingItems_emptiesQueue() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!

        service.queueSmartSearch(url: url, name: "Test", libraryID: nil)
        XCTAssertEqual(service.getPendingItems().count, 1)

        service.clearPendingItems()

        XCTAssertTrue(service.getPendingItems().isEmpty)
    }

    func testClearPendingItems_emptyQueue() {
        // Should not crash on empty queue
        service.clearPendingItems()
        XCTAssertTrue(service.getPendingItems().isEmpty)
    }

    // MARK: - Has Pending Items Tests

    func testHasPendingItems_false_whenEmpty() {
        XCTAssertFalse(service.hasPendingItems)
    }

    func testHasPendingItems_true_whenNotEmpty() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!
        service.queueSmartSearch(url: url, name: "Test", libraryID: nil)

        XCTAssertTrue(service.hasPendingItems)
    }

    // MARK: - Library Info Tests

    func testUpdateAvailableLibraries_storesLibraries() {
        let libraries = [
            SharedLibraryInfo(id: UUID(), name: "Library 1", isDefault: true),
            SharedLibraryInfo(id: UUID(), name: "Library 2", isDefault: false)
        ]

        service.updateAvailableLibraries(libraries)

        let retrieved = service.getAvailableLibraries()
        XCTAssertEqual(retrieved.count, 2)
        XCTAssertEqual(retrieved[0].name, "Library 1")
        XCTAssertEqual(retrieved[0].isDefault, true)
        XCTAssertEqual(retrieved[1].name, "Library 2")
        XCTAssertEqual(retrieved[1].isDefault, false)
    }

    func testUpdateAvailableLibraries_overwritesPrevious() {
        let libraries1 = [SharedLibraryInfo(id: UUID(), name: "Old", isDefault: true)]
        let libraries2 = [SharedLibraryInfo(id: UUID(), name: "New", isDefault: true)]

        service.updateAvailableLibraries(libraries1)
        service.updateAvailableLibraries(libraries2)

        let retrieved = service.getAvailableLibraries()
        XCTAssertEqual(retrieved.count, 1)
        XCTAssertEqual(retrieved[0].name, "New")
    }

    func testGetAvailableLibraries_empty() {
        // Ensure no libraries exist
        service.updateAvailableLibraries([])

        let retrieved = service.getAvailableLibraries()
        XCTAssertTrue(retrieved.isEmpty)
    }

    // MARK: - SharedLibraryInfo Tests

    func testSharedLibraryInfo_initialization() {
        let id = UUID()
        let info = SharedLibraryInfo(id: id, name: "Test Library", isDefault: true)

        XCTAssertEqual(info.id, id)
        XCTAssertEqual(info.name, "Test Library")
        XCTAssertTrue(info.isDefault)
    }

    func testSharedLibraryInfo_equatable() {
        let id = UUID()
        let info1 = SharedLibraryInfo(id: id, name: "Test", isDefault: true)
        let info2 = SharedLibraryInfo(id: id, name: "Test", isDefault: true)

        XCTAssertEqual(info1, info2)
    }

    func testSharedLibraryInfo_codable() throws {
        let id = UUID()
        let info = SharedLibraryInfo(id: id, name: "Test Library", isDefault: true)

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(SharedLibraryInfo.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "Test Library")
        XCTAssertTrue(decoded.isDefault)
    }

    // MARK: - Notification Tests

    func testQueueSmartSearch_postsNotification() {
        let expectation = self.expectation(forNotification: ShareExtensionService.sharedURLReceivedNotification,
                                           object: nil,
                                           handler: nil)

        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!
        service.queueSmartSearch(url: url, name: "Test", libraryID: nil)

        wait(for: [expectation], timeout: 1.0)
    }

    func testQueuePaperImport_postsNotification() {
        let expectation = self.expectation(forNotification: ShareExtensionService.sharedURLReceivedNotification,
                                           object: nil,
                                           handler: nil)

        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B")!
        service.queuePaperImport(url: url, libraryID: nil)

        wait(for: [expectation], timeout: 1.0)
    }

    func testQueueDocsSelection_postsNotification() {
        let expectation = self.expectation(forNotification: ShareExtensionService.sharedURLReceivedNotification,
                                           object: nil,
                                           handler: nil)

        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(abc)")!
        service.queueDocsSelection(url: url, query: "docs(abc)")

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Singleton Tests

    func testShared_returnsSameInstance() {
        let instance1 = ShareExtensionService.shared
        let instance2 = ShareExtensionService.shared

        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - App Group Identifier Tests

    func testAppGroupIdentifier_isCorrect() {
        XCTAssertEqual(ShareExtensionService.appGroupIdentifier, "group.com.imbib.app")
    }
}
