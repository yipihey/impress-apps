//
//  ImpelStoreAdapter.swift
//  ImpelCore
//
//  Stage 0 of the GUI unification: impel's READ path comes straight from the
//  shared item store (the same rows impel-taskd writes), replacing the mock
//  HTTP client state. Commands (state transitions, claims, escalation
//  resolutions) stay on HTTP — `TaskStoreApi.transition` in the Rust kernel
//  is the only legal way task state moves.
//
//  Reads are watermark-friendly (`modified_after_ms`) but Stage 0 keeps it
//  simple: full snapshot per poll, diffed by the caller's @Published state.
//

import Foundation
import ImpressKit
import ImpressRustCore

public final class ImpelStoreAdapter: @unchecked Sendable {

    public static let shared = ImpelStoreAdapter()

    /// Schema refs as impel-core's TaskStoreApi writes them
    /// (crates/impel-core/src/task_store.rs TASK_SCHEMA / AGENT_RUN_SCHEMA).
    public static let taskSchema = "task@1.0.0"
    public static let agentRunSchema = "agent-run@1.0.0"

    private let lock = NSLock()
    private var store: SharedStore?
    public private(set) var lastError: String?

    private init() {}

    private func handle() -> SharedStore? {
        lock.lock()
        defer { lock.unlock() }
        if let store { return store }
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let s = try SharedStore.open(path: SharedWorkspace.databasePath)
            store = s
            return s
        } catch {
            lastError = "SharedStore open failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// All task records, newest-modified first, mapped into the GUI's
    /// ResearchThread shape.
    public func fetchThreads(limit: UInt32 = 500) -> [ResearchThread] {
        guard let store = handle() else { return [] }
        do {
            let rows = try store.queryItems(query: SharedItemQuery(
                schemaRef: Self.taskSchema,
                parentId: nil,
                payloadEq: [],
                modifiedAfterMs: nil,
                sortField: "modified",
                ascending: false,
                limit: limit,
                offset: 0
            ))
            return rows.compactMap(Self.thread(from:))
        } catch {
            lastError = "task query failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Raw agent-run rows (newest first) for the runs surfaces.
    public func fetchAgentRuns(limit: UInt32 = 500) -> [SharedItemRow] {
        guard let store = handle() else { return [] }
        do {
            return try store.queryItems(query: SharedItemQuery(
                schemaRef: Self.agentRunSchema,
                parentId: nil,
                payloadEq: [],
                modifiedAfterMs: nil,
                sortField: "created",
                ascending: false,
                limit: limit,
                offset: 0
            ))
        } catch {
            lastError = "agent-run query failed: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Mapping

    /// Kernel task lifecycle → GUI thread state
    /// (queued | running | waiting_review | completed | failed | cancelled).
    static func threadState(fromTaskState raw: String) -> ThreadState {
        switch raw {
        case "queued": return .embryo
        case "running": return .active
        case "waiting_review": return .review
        case "completed": return .complete
        case "failed": return .blocked
        case "cancelled": return .killed
        default: return .embryo
        }
    }

    static func thread(from row: SharedItemRow) -> ResearchThread? {
        guard let data = row.payloadJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let title = obj["title"] as? String ?? "Untitled task"
        let stateRaw = obj["state"] as? String ?? "queued"
        let created = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000.0)
        let modified = Date(timeIntervalSince1970: TimeInterval(row.modifiedMs) / 1000.0)
        return ResearchThread(
            id: row.id,
            title: title,
            description: obj["description"] as? String ?? "",
            state: threadState(fromTaskState: stateRaw),
            temperature: obj["temperature"] as? Double ?? 0.5,
            claimedBy: obj["assigned_to"] as? String,
            createdAt: created,
            updatedAt: modified,
            artifactCount: 0
        )
    }
}
