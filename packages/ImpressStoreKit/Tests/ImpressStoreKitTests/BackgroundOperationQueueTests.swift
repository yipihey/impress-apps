//
//  BackgroundOperationQueueTests.swift
//  ImpressStoreKitTests
//

import XCTest
@testable import ImpressStoreKit

final class BackgroundOperationQueueTests: XCTestCase {

    /// A fresh queue configured with a 0-second startup grace so
    /// `.background` operations run immediately in tests.
    private func makeQueue() async -> BackgroundOperationQueue {
        let q = BackgroundOperationQueue()
        await MainActor.run {} // yield once so the internal workerLoop starts
        await q.setStartupGraceSeconds(0)
        return q
    }

    func testDedupDropsSecondSubmissionWithSameKey() async {
        let q = await makeQueue()

        let started = DispatchSemaphore(value: 0)
        let block = DispatchSemaphore(value: 0)

        let first = BackgroundOperation(
            kind: .network,
            priority: .userInitiated,
            dedupeKey: "refresh-feed-A",
            label: "first"
        ) { _ in
            started.signal()
            block.wait()
        }
        let firstResult = await q.submit(first)
        guard case .accepted = firstResult else {
            XCTFail("first submission should be accepted"); return
        }

        // Wait until the first op is actually running, not just queued.
        started.wait()

        let duplicate = BackgroundOperation(
            kind: .network,
            priority: .userInitiated,
            dedupeKey: "refresh-feed-A",
            label: "duplicate"
        ) { _ in
            XCTFail("duplicate must not run")
        }
        let dupResult = await q.submit(duplicate)
        if case .deduped = dupResult {
            // expected
        } else {
            XCTFail("duplicate should be deduped, got \(dupResult)")
        }

        // Let the first op finish so the queue can shut down cleanly.
        block.signal()
    }

    func testUserInitiatedBypassesStartupGrace() async {
        let q = BackgroundOperationQueue()
        // Keep default 90s grace.
        let op = BackgroundOperation(
            kind: .read,
            priority: .userInitiated,
            label: "user"
        ) { _ in }
        let result = await q.submit(op)
        if case .accepted = result {
            // expected
        } else {
            XCTFail("user-initiated work should bypass startup grace, got \(result)")
        }
    }

    func testBackgroundWorkRefusedDuringStartupGrace() async {
        let q = BackgroundOperationQueue()
        let op = BackgroundOperation(
            kind: .read,
            priority: .background,
            label: "bg"
        ) { _ in
            XCTFail("background work must be refused during startup grace")
        }
        let result = await q.submit(op)
        XCTAssertEqual(result, .refusedStartupGrace)
    }
}

// Test helper — expose mutable configuration through the actor interface.
extension BackgroundOperationQueue {
    func setStartupGraceSeconds(_ seconds: TimeInterval) {
        self.startupGraceSeconds = seconds
    }
}
