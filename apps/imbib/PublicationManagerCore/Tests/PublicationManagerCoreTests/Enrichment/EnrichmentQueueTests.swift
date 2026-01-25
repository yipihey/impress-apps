//
//  EnrichmentQueueTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class EnrichmentQueueTests: XCTestCase {

    var queue: EnrichmentQueue!

    override func setUp() async throws {
        queue = EnrichmentQueue(maxSize: 10)
    }

    // MARK: - Basic Operations

    func testEnqueueAndDequeue() async {
        let request = EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "10.1234/test"],
            priority: .libraryPaper
        )

        let added = await queue.enqueue(request)
        XCTAssertTrue(added)

        let count = await queue.count
        XCTAssertEqual(count, 1)

        let dequeued = await queue.dequeue()
        XCTAssertNotNil(dequeued)
        XCTAssertEqual(dequeued?.publicationID, request.publicationID)

        let countAfter = await queue.count
        XCTAssertEqual(countAfter, 0)
    }

    func testDequeueEmptyQueue() async {
        let result = await queue.dequeue()
        XCTAssertNil(result)
    }

    func testPeek() async {
        let request = EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "10.1234/test"],
            priority: .libraryPaper
        )

        await queue.enqueue(request)

        let peeked = await queue.peek()
        XCTAssertNotNil(peeked)
        XCTAssertEqual(peeked?.publicationID, request.publicationID)

        // Should still be in queue
        let count = await queue.count
        XCTAssertEqual(count, 1)
    }

    func testPeekEmptyQueue() async {
        let result = await queue.peek()
        XCTAssertNil(result)
    }

    // MARK: - Priority Ordering

    func testPriorityOrdering() async {
        let lowPriority = EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "low"],
            priority: .backgroundSync
        )
        let highPriority = EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "high"],
            priority: .userTriggered
        )
        let medPriority = EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "med"],
            priority: .libraryPaper
        )

        // Add in non-priority order
        await queue.enqueue(lowPriority)
        await queue.enqueue(highPriority)
        await queue.enqueue(medPriority)

        // Should dequeue in priority order
        let first = await queue.dequeue()
        XCTAssertEqual(first?.identifiers[.doi], "high")

        let second = await queue.dequeue()
        XCTAssertEqual(second?.identifiers[.doi], "med")

        let third = await queue.dequeue()
        XCTAssertEqual(third?.identifiers[.doi], "low")
    }

    func testFIFOWithinPriority() async {
        let first = EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "first"],
            priority: .libraryPaper
        )
        let second = EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "second"],
            priority: .libraryPaper
        )
        let third = EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "third"],
            priority: .libraryPaper
        )

        await queue.enqueue(first)
        await queue.enqueue(second)
        await queue.enqueue(third)

        let dequeued1 = await queue.dequeue()
        XCTAssertEqual(dequeued1?.identifiers[.doi], "first")

        let dequeued2 = await queue.dequeue()
        XCTAssertEqual(dequeued2?.identifiers[.doi], "second")

        let dequeued3 = await queue.dequeue()
        XCTAssertEqual(dequeued3?.identifiers[.doi], "third")
    }

    // MARK: - Deduplication

    func testDeduplication() async {
        let publicationID = UUID()

        let request1 = EnrichmentRequest(
            publicationID: publicationID,
            identifiers: [.doi: "10.1234/test"],
            priority: .libraryPaper
        )
        let request2 = EnrichmentRequest(
            publicationID: publicationID,  // Same publication ID
            identifiers: [.doi: "10.1234/test"],
            priority: .userTriggered
        )

        let added1 = await queue.enqueue(request1)
        XCTAssertTrue(added1)

        let added2 = await queue.enqueue(request2)
        XCTAssertFalse(added2)  // Rejected as duplicate

        let count = await queue.count
        XCTAssertEqual(count, 1)
    }

    func testContainsPublicationID() async {
        let publicationID = UUID()
        let request = EnrichmentRequest(
            publicationID: publicationID,
            identifiers: [.doi: "10.1234/test"],
            priority: .libraryPaper
        )

        var contains = await queue.contains(publicationID: publicationID)
        XCTAssertFalse(contains)

        await queue.enqueue(request)

        contains = await queue.contains(publicationID: publicationID)
        XCTAssertTrue(contains)

        _ = await queue.dequeue()

        contains = await queue.contains(publicationID: publicationID)
        XCTAssertFalse(contains)
    }

    // MARK: - Queue Size Limits

    func testMaxSizeEnforced() async {
        let smallQueue = EnrichmentQueue(maxSize: 3)

        for i in 0..<5 {
            let request = EnrichmentRequest(
                publicationID: UUID(),
                identifiers: [.doi: "test\(i)"],
                priority: .libraryPaper
            )
            await smallQueue.enqueue(request)
        }

        let count = await smallQueue.count
        XCTAssertEqual(count, 3)  // Only first 3 should be added
    }

    func testIsFullAndIsEmpty() async {
        let smallQueue = EnrichmentQueue(maxSize: 2)

        var isEmpty = await smallQueue.isEmpty
        var isFull = await smallQueue.isFull
        XCTAssertTrue(isEmpty)
        XCTAssertFalse(isFull)

        await smallQueue.enqueue(EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "1"],
            priority: .libraryPaper
        ))

        isEmpty = await smallQueue.isEmpty
        isFull = await smallQueue.isFull
        XCTAssertFalse(isEmpty)
        XCTAssertFalse(isFull)

        await smallQueue.enqueue(EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "2"],
            priority: .libraryPaper
        ))

        isEmpty = await smallQueue.isEmpty
        isFull = await smallQueue.isFull
        XCTAssertFalse(isEmpty)
        XCTAssertTrue(isFull)
    }

    // MARK: - Remove Operations

    func testRemovePublicationID() async {
        let publicationID = UUID()
        let request = EnrichmentRequest(
            publicationID: publicationID,
            identifiers: [.doi: "10.1234/test"],
            priority: .libraryPaper
        )

        await queue.enqueue(request)
        var count = await queue.count
        XCTAssertEqual(count, 1)

        let removed = await queue.remove(publicationID: publicationID)
        XCTAssertTrue(removed)

        count = await queue.count
        XCTAssertEqual(count, 0)

        // Removing again should return false
        let removedAgain = await queue.remove(publicationID: publicationID)
        XCTAssertFalse(removedAgain)
    }

    func testRemoveNonExistentPublicationID() async {
        let removed = await queue.remove(publicationID: UUID())
        XCTAssertFalse(removed)
    }

    func testClear() async {
        for i in 0..<5 {
            await queue.enqueue(EnrichmentRequest(
                publicationID: UUID(),
                identifiers: [.doi: "test\(i)"],
                priority: .libraryPaper
            ))
        }

        var count = await queue.count
        XCTAssertEqual(count, 5)

        await queue.clear()

        count = await queue.count
        XCTAssertEqual(count, 0)

        let isEmpty = await queue.isEmpty
        XCTAssertTrue(isEmpty)
    }

    // MARK: - Priority Upgrade

    func testUpgradePriority() async {
        let publicationID = UUID()
        let request = EnrichmentRequest(
            publicationID: publicationID,
            identifiers: [.doi: "test"],
            priority: .backgroundSync  // Lowest priority
        )

        await queue.enqueue(request)

        let upgraded = await queue.upgradePriority(publicationID: publicationID, to: .userTriggered)
        XCTAssertTrue(upgraded)

        // Peek should show upgraded priority
        let peeked = await queue.peek()
        XCTAssertEqual(peeked?.priority, .userTriggered)
    }

    func testUpgradePriorityToLowerFails() async {
        let publicationID = UUID()
        let request = EnrichmentRequest(
            publicationID: publicationID,
            identifiers: [.doi: "test"],
            priority: .userTriggered  // Highest priority
        )

        await queue.enqueue(request)

        // Can't "upgrade" to lower priority
        let upgraded = await queue.upgradePriority(publicationID: publicationID, to: .backgroundSync)
        XCTAssertFalse(upgraded)

        let peeked = await queue.peek()
        XCTAssertEqual(peeked?.priority, .userTriggered)
    }

    func testUpgradePriorityNonExistent() async {
        let upgraded = await queue.upgradePriority(publicationID: UUID(), to: .userTriggered)
        XCTAssertFalse(upgraded)
    }

    // MARK: - Statistics

    func testCountsByPriority() async {
        await queue.enqueue(EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "1"],
            priority: .userTriggered
        ))
        await queue.enqueue(EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "2"],
            priority: .libraryPaper
        ))
        await queue.enqueue(EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "3"],
            priority: .libraryPaper
        ))

        let counts = await queue.countsByPriority

        XCTAssertEqual(counts[.userTriggered], 1)
        XCTAssertEqual(counts[.recentlyViewed], 0)
        XCTAssertEqual(counts[.libraryPaper], 2)
        XCTAssertEqual(counts[.backgroundSync], 0)
    }

    func testAllPublicationIDs() async {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        await queue.enqueue(EnrichmentRequest(publicationID: id1, identifiers: [:], priority: .libraryPaper))
        await queue.enqueue(EnrichmentRequest(publicationID: id2, identifiers: [:], priority: .libraryPaper))
        await queue.enqueue(EnrichmentRequest(publicationID: id3, identifiers: [:], priority: .libraryPaper))

        let ids = await queue.allPublicationIDs

        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains(id1))
        XCTAssertTrue(ids.contains(id2))
        XCTAssertTrue(ids.contains(id3))
    }

    // MARK: - Batch Operations

    func testBatchEnqueue() async {
        let requests = (0..<5).map { i in
            EnrichmentRequest(
                publicationID: UUID(),
                identifiers: [.doi: "test\(i)"],
                priority: .libraryPaper
            )
        }

        let added = await queue.enqueue(requests)
        XCTAssertEqual(added, 5)

        let count = await queue.count
        XCTAssertEqual(count, 5)
    }

    func testBatchEnqueueWithDuplicates() async {
        let sharedID = UUID()
        let requests = [
            EnrichmentRequest(publicationID: sharedID, identifiers: [.doi: "1"], priority: .libraryPaper),
            EnrichmentRequest(publicationID: sharedID, identifiers: [.doi: "2"], priority: .libraryPaper),
            EnrichmentRequest(publicationID: UUID(), identifiers: [.doi: "3"], priority: .libraryPaper)
        ]

        let added = await queue.enqueue(requests)
        XCTAssertEqual(added, 2)  // One duplicate rejected

        let count = await queue.count
        XCTAssertEqual(count, 2)
    }

    func testBatchDequeue() async {
        for i in 0..<5 {
            await queue.enqueue(EnrichmentRequest(
                publicationID: UUID(),
                identifiers: [.doi: "test\(i)"],
                priority: .libraryPaper
            ))
        }

        let dequeued = await queue.dequeue(count: 3)
        XCTAssertEqual(dequeued.count, 3)

        let remaining = await queue.count
        XCTAssertEqual(remaining, 2)
    }

    func testBatchDequeueMoreThanAvailable() async {
        await queue.enqueue(EnrichmentRequest(
            publicationID: UUID(),
            identifiers: [.doi: "test"],
            priority: .libraryPaper
        ))

        let dequeued = await queue.dequeue(count: 10)
        XCTAssertEqual(dequeued.count, 1)

        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)
    }
}
