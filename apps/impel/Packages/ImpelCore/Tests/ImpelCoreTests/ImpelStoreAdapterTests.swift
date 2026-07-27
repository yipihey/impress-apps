//
//  ImpelStoreAdapterTests.swift
//  ImpelCoreTests
//
//  Stage 0: the task@1.0.0 → ResearchThread mapping and the state vocabulary
//  bridge (kernel lifecycle → GUI ThreadState).
//

import XCTest
@testable import ImpelCore
import ImpressRustCore

final class ImpelStoreAdapterTests: XCTestCase {

    func testThreadStateMapping() {
        XCTAssertEqual(ImpelStoreAdapter.threadState(fromTaskState: "queued"), .embryo)
        XCTAssertEqual(ImpelStoreAdapter.threadState(fromTaskState: "running"), .active)
        XCTAssertEqual(ImpelStoreAdapter.threadState(fromTaskState: "waiting_review"), .review)
        XCTAssertEqual(ImpelStoreAdapter.threadState(fromTaskState: "completed"), .complete)
        XCTAssertEqual(ImpelStoreAdapter.threadState(fromTaskState: "failed"), .blocked)
        XCTAssertEqual(ImpelStoreAdapter.threadState(fromTaskState: "cancelled"), .killed)
        XCTAssertEqual(ImpelStoreAdapter.threadState(fromTaskState: "???"), .embryo)
    }

    func testTaskRowMapsToThread() throws {
        // Round-trip through a real in-memory store so the row shape is the
        // FFI's, not a hand-built fixture.
        let store = try SharedStore.openInMemory()
        let id = UUID().uuidString.lowercased()
        try store.upsertItemV2(row: SharedItemUpsert(
            id: id,
            schemaRef: ImpelStoreAdapter.taskSchema,
            payloadJson: #"{"title": "Probe kNN scaling", "state": "running", "description": "counsel run", "assigned_to": "artificer"}"#,
            parentId: nil,
            tags: [],
            createdMs: 1_700_000_000_000,
            isRead: nil,
            isStarred: nil
        ))
        let rows = try store.queryItems(query: SharedItemQuery(
            schemaRef: ImpelStoreAdapter.taskSchema,
            parentId: nil, payloadEq: [], modifiedAfterMs: nil,
            sortField: "", ascending: false, limit: 0, offset: 0
        ))
        XCTAssertEqual(rows.count, 1)
        let thread = try XCTUnwrap(ImpelStoreAdapter.thread(from: rows[0]))
        XCTAssertEqual(thread.title, "Probe kNN scaling")
        XCTAssertEqual(thread.state, .active)
        XCTAssertEqual(thread.claimedBy, "artificer")
        XCTAssertEqual(
            thread.createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }
}
