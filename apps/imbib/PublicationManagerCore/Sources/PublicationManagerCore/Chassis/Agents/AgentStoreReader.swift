// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a read-only
// `SharedStore` reader (Foundation + ImpressRustCore). While it was gated iOS
// could not read tasks or agent runs from the shared store AT ALL.
//
//  AgentStoreReader.swift
//  PublicationManagerCore
//
//  Stage 2-C (ADR-0021): store access for the Agents section. Task and
//  agent-run rows — `task@1.0.0` / `agent-run@1.0.0` — live in the SHARED
//  impress store (written by impel-core's TaskStoreApi), but the chassis
//  cannot depend on ImpelCore/CounselEngine (PMC ships to every app). So
//  this reader clones the MailStoreReader pattern: its own `SharedStore`
//  handle on the same database, flat `queryItems`/`countItems` reads only.
//
//  Scope discipline — READ-ONLY by design: task lifecycle is KERNEL-owned
//  (`TaskStoreApi.transition` is the sole legal state mutation, ADR-0015 D1;
//  docs/status-lifecycle.md), and agent-run rows are immutable provenance.
//  The only store mutations the Agents chassis performs are the generic
//  star/flag/tag ops via `RustStoreAdapter.shared`.
//

import Foundation
import ImpressKit
import ImpressRustCore
import OSLog

/// Decoded `task@1.0.0` payload fields (defensive: rows may omit optionals).
struct AgentTaskPayload: Decodable {
    var title: String?
    /// queued | running | waiting_review | completed | failed | cancelled.
    var state: String?
    var description: String?
    var assignedTo: String?

    enum CodingKeys: String, CodingKey {
        case title, state, description
        case assignedTo = "assigned_to"
    }
}

/// Decoded `agent-run@1.0.0` payload fields (provenance record, ADR-0005 §5).
struct AgentRunPayload: Decodable {
    var agentID: String?
    var model: String?
    var promptHash: String?
    var resultSummary: String?
    var tokenCount: Int64?
    var durationMs: Int64?

    enum CodingKeys: String, CodingKey {
        case model
        case agentID = "agent_id"
        case promptHash = "prompt_hash"
        case resultSummary = "result_summary"
        case tokenCount = "token_count"
        case durationMs = "duration_ms"
    }
}

@MainActor
public final class AgentStoreReader {

    public static let shared = AgentStoreReader()

    private static let logger = Logger(subsystem: "com.imbib.app", category: "agents")

    /// Schema refs as impel-core's TaskStoreApi writes them — VERSIONED
    /// (crates/impel-core/src/task_store.rs TASK_SCHEMA / AGENT_RUN_SCHEMA).
    ///
    /// Read from the DESCRIPTORS rather than re-typed: these were two string
    /// literals duplicating what `TaskRecordKind`/`AgentRunRecordKind` already
    /// declare, and a reader with its own copy of a ref is precisely the
    /// silent-empty-query bug schema-refs.json exists to prevent. There are
    /// three live spellings of each of these kinds
    /// (knownDivergences/impel-task-spelling), which makes having exactly one
    /// Swift-side statement of the one this reader wants worth more here than
    /// anywhere else.
    public static let taskSchema = TaskRecordKind.descriptor.primarySchemaRef
    public static let agentRunSchema = AgentRunRecordKind.descriptor.primarySchemaRef

    /// The kernel task lifecycle, in canonical pipeline order — the
    /// descriptor's declared `lifecycle`, not a parallel array. Empty only if
    /// the descriptor stops declaring one, which `AgentRecordKindTests` fails on.
    public static let taskStates: [String] =
        TaskRecordKind.descriptor.lifecycle?.stateValues ?? []

    private var store: SharedStore?

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            store = try SharedStore.open(path: SharedWorkspace.databasePath)
        } catch {
            Self.logger.error("AgentStoreReader failed to open shared store: \(error)")
        }
    }

    public var isReady: Bool { store != nil }

    // MARK: - Reads

    /// Task rows, optionally filtered by payload `state`, newest-modified
    /// first (the kernel bumps `modified` on every transition).
    public func fetchTasks(state: String? = nil, limit: UInt32 = 5000) -> [SharedItemRow] {
        guard let store else { return [] }
        let eq: [SharedFieldEq] = state.map {
            [SharedFieldEq(field: "state", valueJson: Self.jsonString($0))]
        } ?? []
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: Self.taskSchema, parentId: nil, payloadEq: eq,
            modifiedAfterMs: nil, sortField: "modified",
            ascending: false, limit: limit, offset: 0))) ?? []
    }

    /// Agent-run rows, newest first by creation (runs are append-only).
    public func fetchRuns(limit: UInt32 = 5000) -> [SharedItemRow] {
        guard let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: Self.agentRunSchema, parentId: nil, payloadEq: [],
            modifiedAfterMs: nil, sortField: "created",
            ascending: false, limit: limit, offset: 0))) ?? []
    }

    /// One task row by store id (schema-checked; refs carry the version).
    public func fetchTask(id: String) -> SharedItemRow? {
        guard let store else { return nil }
        guard let row = try? store.getItem(id: id.lowercased()) else { return nil }
        // Registry lookup, not `hasPrefix("task")`: the tolerant lookup
        // compares BASE NAMES on both sides, so a future `task-template` row
        // cannot pass as a task the way a prefix check would let it.
        guard BuiltinRecordKinds.registry.kind(forStoreSchemaRef: row.schemaRef) == .task
        else { return nil }
        return row
    }

    /// One agent-run row by store id.
    public func fetchRun(id: String) -> SharedItemRow? {
        guard let store else { return nil }
        guard let row = try? store.getItem(id: id.lowercased()) else { return nil }
        guard row.schemaRef.hasPrefix("agent-run") else { return nil }
        return row
    }

    /// Runs recorded for one task, newest first. The kernel links
    /// `task —ProducedBy→ run` as a typed reference (record_agent_run), so
    /// this follows the task's edges and resolves each target — fine at
    /// per-task run counts.
    public func fetchRuns(forTask taskID: String) -> [SharedItemRow] {
        guard let store else { return [] }
        guard let refs = try? store.getItemReferences(id: taskID.lowercased()) else { return [] }
        return refs
            .filter { $0.edgeType == "ProducedBy" }
            .compactMap { try? store.getItem(id: $0.targetId) }
            .compactMap { $0 }
            .filter { $0.schemaRef.hasPrefix("agent-run") }
            .sorted { $0.createdMs > $1.createdMs }
    }

    /// The newest run recorded for a task (the Task detail's View tab).
    public func fetchLatestRun(forTask taskID: String) -> SharedItemRow? {
        fetchRuns(forTask: taskID).first
    }

    // MARK: - Counts (sidebar badges)

    /// Count of tasks, optionally per payload `state` (pushed to the store).
    public func taskCount(state: String? = nil) -> Int {
        guard let store else { return 0 }
        let eq: [SharedFieldEq] = state.map {
            [SharedFieldEq(field: "state", valueJson: Self.jsonString($0))]
        } ?? []
        let count = (try? store.countItems(query: SharedItemQuery(
            schemaRef: Self.taskSchema, parentId: nil, payloadEq: eq,
            modifiedAfterMs: nil, sortField: "", ascending: false,
            limit: 0, offset: 0))) ?? 0
        return Int(count)
    }

    /// Count of agent-run rows.
    public func runCount() -> Int {
        guard let store else { return 0 }
        let count = (try? store.countItems(query: SharedItemQuery(
            schemaRef: Self.agentRunSchema, parentId: nil, payloadEq: [],
            modifiedAfterMs: nil, sortField: "", ascending: false,
            limit: 0, offset: 0))) ?? 0
        return Int(count)
    }

    // MARK: - Payload decoding helpers

    nonisolated static func taskPayload(from row: SharedItemRow) -> AgentTaskPayload? {
        guard let data = row.payloadJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentTaskPayload.self, from: data)
    }

    nonisolated static func runPayload(from row: SharedItemRow) -> AgentRunPayload? {
        guard let data = row.payloadJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentRunPayload.self, from: data)
    }

    /// The declared spec for a kernel task state, if the descriptor knows it.
    nonisolated static func stateSpec(_ state: String) -> StatusSpec? {
        TaskRecordKind.descriptor.lifecycle?.state(state)
    }

    /// Human-readable label for a kernel task state ("waiting_review" →
    /// "Waiting Review"). The DECLARED label, falling back to a title-cased
    /// spelling for a state this build does not know — a kernel newer than the
    /// GUI must render as something honest rather than blank.
    nonisolated static func stateDisplayName(_ state: String) -> String {
        stateSpec(state)?.label
            ?? state.split(separator: "_").map(\.capitalized).joined(separator: " ")
    }

    /// SF Symbol for a kernel task state (sidebar smart children + rows).
    /// Was a six-arm `switch`; now the declaration on `TaskRecordKind`.
    nonisolated static func stateIcon(_ state: String) -> String {
        stateSpec(state)?.systemImage ?? "circle"
    }

    /// Encode a Swift string as a JSON scalar for `SharedFieldEq.valueJson`
    /// (same helper shape as MailStoreReader's).
    private nonisolated static func jsonString(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let array = String(data: data, encoding: .utf8),
           array.count >= 2 {
            return String(array.dropFirst().dropLast())
        }
        return "\"\(value)\""
    }
}
