import Foundation
import Testing

@testable import CounselEngine

// MARK: - Schema refs (WP C4)

/// The bridge's refs are the suite's canonical spellings, not impel-private
/// ones. Until C4 it wrote `impel/task` / `impel/agent-run`, which
/// `sqlite_store.ready_tasks`, `ImpelStoreAdapter.fetchThreads` and imbib's
/// Agents section all fail to match — the store compares `schema_ref` by exact
/// equality, so those rows were invisible to every reader including impel's own
/// window. `scripts/check-schema-refs.sh` holds the literals to
/// `schema-refs.json`; this pins the values a Swift reader sees.
@Test func bridgeWritesTheCanonicalSchemaRefs() {
    #expect(SharedTaskSchema.task == "task@1.0.0")
    #expect(SharedTaskSchema.agentRun == "agent-run@1.0.0")
}

// MARK: - Derived agent-run ids

/// `upsert_item` parses the id as a UUID and rejects anything else, so the old
/// `"<taskID>-run-<n>"` form failed on EVERY call and no agent-run row was ever
/// written. The replacement must be a real UUID.
@Test func runItemIDIsAUUID() {
    let id = SharedTaskBridge.runItemID(taskID: UUID().uuidString, roundNumber: 1)
    #expect(UUID(uuidString: id) != nil)
    #expect(id == id.lowercased(), "the store's canonical id form is lowercase")
}

/// Stability is the whole point: re-reporting a round must upsert the same row
/// rather than accumulate duplicates.
@Test func runItemIDIsStablePerTaskAndRound() {
    let task = UUID().uuidString
    #expect(
        SharedTaskBridge.runItemID(taskID: task, roundNumber: 3)
            == SharedTaskBridge.runItemID(taskID: task, roundNumber: 3))
    // Case-insensitive in the task id: Swift's `UUID.uuidString` is uppercase
    // and the store's ids are lowercase; the same task must not yield two runs.
    #expect(
        SharedTaskBridge.runItemID(taskID: task.uppercased(), roundNumber: 3)
            == SharedTaskBridge.runItemID(taskID: task.lowercased(), roundNumber: 3))
}

@Test func runItemIDSeparatesRoundsAndTasks() {
    let task = UUID().uuidString
    let other = UUID().uuidString
    #expect(
        SharedTaskBridge.runItemID(taskID: task, roundNumber: 1)
            != SharedTaskBridge.runItemID(taskID: task, roundNumber: 2))
    #expect(
        SharedTaskBridge.runItemID(taskID: task, roundNumber: 1)
            != SharedTaskBridge.runItemID(taskID: other, roundNumber: 1))
}

/// A non-UUID task key still produces a usable id rather than dropping the
/// provenance record.
@Test func runItemIDToleratesANonUUIDTaskKey() {
    let id = SharedTaskBridge.runItemID(taskID: "grdb-local-42", roundNumber: 0)
    #expect(UUID(uuidString: id) != nil)
}
