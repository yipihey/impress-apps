import CryptoKit
import Foundation
import ImpressKit
import ImpressStoreKit
import OSLog
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Schema refs

/// The refs this bridge writes, stated ONCE for the file.
///
/// `ImpelCore.ImpelStoreAdapter` declares the same two strings for impel's read
/// path, and CounselEngine deliberately does not depend on ImpelCore (its
/// Package.swift keeps the graph narrow so two headless CLIs don't link the GUI
/// stack). Two literals across a package boundary is normally the bug — here it
/// is safe *because* `scripts/check-schema-refs.sh` holds both to the same
/// `schema-refs.json` entry, so they cannot drift apart silently. That lint is
/// the reason a second copy is acceptable at all; without it, delete one.
enum SharedTaskSchema {
    static let task = "task@1.0.0"
    static let agentRun = "agent-run@1.0.0"
}

// MARK: - SharedTaskBridge

/// Writes task and agent-run items to the shared impress-core store
/// for cross-app provenance and discoverability.
///
/// GRDB remains authoritative for impel's task UI. This bridge provides
/// a read-only view of impel's activity to other apps (imbib, imprint,
/// implore, impart) via the shared impress-core SQLite store.
///
/// ## Schema contract
///
/// - Task items use `task@1.0.0` (`SharedSchema.task`)
/// - Agent-run items use `agent-run@1.0.0` (`SharedSchema.agentRun`)
///
/// Registered once, in `crates/impress-core/src/schemas/task.rs`; declared once
/// for the suite in `schema-refs.json`.
///
/// These were `impel/task` and `impel/agent-run` until WP C4 — a THIRD spelling
/// of kinds that impel's own Rust kernel writes versioned and that
/// `sqlite_store.ready_tasks`, `ImpelStoreAdapter` and imbib's Agents section
/// all read versioned. The store matches `schema_ref` by exact equality, so
/// every row this bridge wrote was invisible to all three: impel's OWN window
/// (`ImpelStoreAdapter.fetchThreads` queries `task@1.0.0`) never listed a
/// single counsel task it had mirrored. Existing rows are converged by
/// `impress_core::task_schema_migration` — flagged off, dry-run first,
/// reversible.
///
/// ## MIRROR contract — these rows are not schedulable, by design
///
/// GRDB is authoritative and impel's own orchestrator runs these tasks. The
/// rows here are a projection for sibling apps, so they deliberately carry NO
/// payload `task_kind`, and `ready_tasks` requires a non-empty `task_kind`
/// before it will hand a task to `impel-taskd`. That is what makes the
/// convergence safe: the rows become visible everywhere without becoming work
/// the impress scheduler will acquire, flip to `running`, and then fail for
/// want of a registered executor. **Do not add a `task_kind` here** without
/// reading `ready_tasks`' doc comment first.
///
/// ## Design
///
/// The bridge is intentionally thin — it establishes the call-site pattern
/// and directory layout without coupling CounselEngine to a specific
/// impress-core UniFFI ABI. The `SqliteItemStore` FFI calls are marked
/// `TODO` and will be wired once the shared UniFFI bindings stabilise.
///
/// ## Threading
///
/// `SharedTaskBridge` is an `actor` so all mutations are serialised. Call
/// sites in `TaskOrchestrator` dispatch into it via `Task { await ... }`
/// so they never block the main thread or the orchestrator's execution.
public actor SharedTaskBridge {

    // MARK: - Singleton

    public static let shared = SharedTaskBridge()

    // MARK: - Event publisher

    /// Fan-out point for mutation notifications. Every task / agent-run
    /// write emits a `StoreEvent` on this publisher so subscribers in
    /// other impress apps (or this one) can react via the shared
    /// `ImpressStoreKit` stream instead of polling.
    ///
    /// `nonisolated` so call sites can subscribe from any actor.
    public nonisolated let events = StoreEventPublisher()

    // MARK: - State

    /// Whether the shared workspace directory was successfully prepared.
    private var isAvailable = false

    /// Path to the shared impress-core SQLite database.
    private var databasePath: String = ""

    #if canImport(ImpressRustCore)
    private var store: SharedStore?
    #endif

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.impress.impel", category: "shared-task-bridge")

    // MARK: - Initialization

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let path = SharedWorkspace.databaseURL.path
            databasePath = path
            #if canImport(ImpressRustCore)
            store = try SharedStore.open(path: path)
            #endif
            isAvailable = true
            logger.info("SharedTaskBridge: shared workspace ready at \(path)")
        } catch {
            // Non-fatal: impel continues without cross-app visibility.
            isAvailable = false
            logger.error("SharedTaskBridge: workspace unavailable — \(error.localizedDescription)")
        }
    }

    // MARK: - Schema Registration

    /// Register impel schemas in the shared impress-core store.
    ///
    /// Must be called once at app startup before any `taskCreated` or
    /// `agentRoundCompleted` calls. Safe to call multiple times.
    public func registerSchemas() {
        guard isAvailable else { return }
        // Schema registration is handled by impress-core's register_core_schemas()
        // which runs automatically when SqliteItemStore is opened.
        logger.info("SharedTaskBridge: store open, schemas registered via impress-core")
    }

    // MARK: - Task Lifecycle

    /// Called when a new task is created in GRDB.
    ///
    /// Writes a `task@1.0.0` item to the shared store so sibling apps
    /// can display the task in their activity feeds.
    ///
    /// - Parameters:
    ///   - taskID: Stable GRDB UUID string (becomes `external_id` in the shared item).
    ///   - title: Short description of the task (typically the first 100 chars of the query).
    ///   - state: Lifecycle state (`queued`, `running`, `completed`, `failed`, `cancelled`).
    ///   - description: Full query text sent to the counsel agent, or nil.
    ///   - sourceApp: Originating app identifier (e.g. `"email"`, `"api"`, `"impel"`).
    public func taskCreated(
        taskID: String,
        title: String,
        state: String,
        description: String?,
        sourceApp: String = "impel"
    ) {
        guard isAvailable else { return }

        let payload: [String: Any?] = [
            "title": title,
            "state": state,
            "description": description,
            "source_app": sourceApp,
            "external_id": taskID
        ]
        let compacted = payload.compactMapValues { $0 }
        guard let payloadJSON = try? JSONSerialization.data(withJSONObject: compacted),
              let payloadString = String(data: payloadJSON, encoding: .utf8) else {
            logger.warning("SharedTaskBridge: failed to encode task payload for \(taskID)")
            return
        }

        #if canImport(ImpressRustCore)
        do {
            try store?.upsertItem(
                id: taskID, schemaRef: SharedTaskSchema.task, payloadJson: payloadString)
            logger.info("SharedTaskBridge: task created \(taskID) '\(title)' state=\(state)")
            // A new task is a structural change to the item graph.
            events.emit(.structural)
        } catch {
            logger.error("SharedTaskBridge: taskCreated upsert failed for \(taskID) — \(error.localizedDescription)")
        }
        #else
        logger.info("SharedTaskBridge: task created \(taskID) '\(title)' state=\(state) (ImpressRustCore not linked)")
        #endif
    }

    /// Called when a task transitions to a new lifecycle state.
    ///
    /// Updates the `state` field of the existing `task@1.0.0` item in the
    /// shared store so sibling apps see the current status.
    ///
    /// - Parameters:
    ///   - taskID: Stable GRDB UUID string identifying the task.
    ///   - newState: New lifecycle state (`running`, `completed`, `failed`, `cancelled`).
    public func taskStateChanged(taskID: String, newState: String) {
        guard isAvailable else { return }

        #if canImport(ImpressRustCore)
        do {
            guard let store = store else { return }
            // Merge newState into the existing payload to avoid overwriting other fields.
            var updatedPayload: [String: Any] = ["state": newState, "external_id": taskID]
            if let existing = try? store.getItem(id: taskID),
               let parsed = try? JSONSerialization.jsonObject(with: Data(existing.payloadJson.utf8)) as? [String: Any] {
                var merged = parsed
                merged["state"] = newState
                updatedPayload = merged
            }
            if let data = try? JSONSerialization.data(withJSONObject: updatedPayload),
               let payloadString = String(data: data, encoding: .utf8) {
                try store.upsertItem(
                    id: taskID, schemaRef: SharedTaskSchema.task, payloadJson: payloadString)
            }
            logger.info("SharedTaskBridge: task \(taskID) state → \(newState)")
            // A state transition is a field change on an existing item.
            if let uuid = UUID(uuidString: taskID) {
                events.emit(.itemsMutated(kind: .otherField, ids: [uuid]))
            } else {
                events.emit(.structural)
            }
        } catch {
            logger.error("SharedTaskBridge: taskStateChanged failed for \(taskID) — \(error.localizedDescription)")
        }
        #else
        logger.info("SharedTaskBridge: task \(taskID) state → \(newState) (ImpressRustCore not linked)")
        #endif
    }

    // MARK: - Agent Run Provenance

    /// Called after an AI agent loop execution completes.
    ///
    /// Writes an `agent-run@1.0.0` item to the shared store for
    /// provenance. The run item is linked to its parent task via an
    /// `OperatesOn` edge so the full execution history is traceable from
    /// any sibling app.
    ///
    /// - Parameters:
    ///   - taskID: Parent task's stable GRDB UUID string.
    ///   - agentID: Logical agent identifier (e.g. `"counsel"`).
    ///   - model: LLM model identifier (e.g. `"claude-opus-4-6"`).
    ///   - promptHash: A truncated hash of the system prompt for tracing.
    ///   - tokenCount: Total tokens consumed (input + output), or nil.
    ///   - durationMs: Wall-clock duration of the run in milliseconds, or nil.
    ///   - roundNumber: Number of rounds the agent loop ran.
    ///   - finishReason: Why the loop terminated (`completed`, `max_rounds_reached`, `error`), or nil.
    ///   - toolCalls: Names of tools invoked during this run, in order.
    public func agentRoundCompleted(
        taskID: String,
        agentID: String,
        model: String,
        promptHash: String,
        tokenCount: Int?,
        durationMs: Int?,
        roundNumber: Int,
        finishReason: String?,
        toolCalls: [String]
    ) {
        guard isAvailable else { return }

        // Stable ID for this run: task + round so repeated completions are
        // idempotent. It must ALSO be a UUID — `upsert_item` parses the id and
        // rejects anything else (`invalid UUID: …`), so the previous
        // `"\(taskID)-run-\(roundNumber)"` form meant every single agent-run
        // write in this bridge's history failed and was swallowed into the
        // `logger.error` below. Not one row was ever created. Found while
        // converging the spellings in WP C4; `Self.runItemID` keeps the
        // stability and makes the id legal.
        let runID = Self.runItemID(taskID: taskID, roundNumber: roundNumber)

        var payload: [String: Any] = [
            "agent_id": agentID,
            "model": model,
            "prompt_hash": promptHash,
            "round_number": roundNumber,
            "status": finishReason ?? "completed"
        ]
        if let tc = tokenCount  { payload["token_count"] = tc }
        if let dm = durationMs  { payload["duration_ms"] = dm }
        if let fr = finishReason { payload["finish_reason"] = fr }
        if !toolCalls.isEmpty   { payload["tool_calls"] = toolCalls }

        let toolList = toolCalls.joined(separator: ", ")

        guard let payloadJSON = try? JSONSerialization.data(withJSONObject: payload),
              let payloadString = String(data: payloadJSON, encoding: .utf8) else {
            logger.warning("SharedTaskBridge: failed to encode agent-run payload for \(runID)")
            return
        }

        #if canImport(ImpressRustCore)
        do {
            try store?.upsertItem(
                id: runID, schemaRef: SharedTaskSchema.agentRun, payloadJson: payloadString)
            logger.info(
                "SharedTaskBridge: agent-run \(runID) for task \(taskID) round=\(roundNumber) model=\(model) tools=[\(toolList)]"
            )
            // A new agent-run is a structural change.
            events.emit(.structural)
        } catch {
            logger.error("SharedTaskBridge: agentRoundCompleted upsert failed for \(runID) — \(error.localizedDescription)")
        }
        #else
        logger.info(
            "SharedTaskBridge: agent-run for task \(taskID) round=\(roundNumber) model=\(model) tools=[\(toolList)] (ImpressRustCore not linked)"
        )
        #endif
    }

    // MARK: - Item ids

    /// Namespace for derived agent-run ids. Arbitrary but FROZEN: changing it
    /// re-ids every run and breaks the idempotency this function exists for.
    private static let runIDNamespace = UUID(uuidString: "3f6c6b1e-9b2a-4d3e-9c7f-5a1b2c3d4e5f")!

    /// A stable UUID for one (task, round) pair — a UUIDv5, the same
    /// construction the Rust side uses for derived ids
    /// (`imprint_service::ThroughlineStore::item_id`, `Uuid::new_v5`). Pure and
    /// deterministic, so re-reporting a round upserts the same row instead of
    /// creating a duplicate.
    ///
    /// Non-UUID `taskID`s are hashed as their own text rather than rejected:
    /// the id only has to be stable, and refusing to record provenance because
    /// a caller's key was unusual would be the worse failure.
    static func runItemID(taskID: String, roundNumber: Int) -> String {
        let name = "\(taskID.lowercased())::run::\(roundNumber)"
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: runIDNamespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}
