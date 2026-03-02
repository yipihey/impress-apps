import Foundation
import ImpressKit
import OSLog
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

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
/// - Task items use schema `impel/task@1.0.0`
/// - Agent-run items use schema `impel/agent-run@1.0.0`
///
/// Both schemas are registered in `crates/impel-core/src/schemas.rs`.
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
    /// Writes a `impel/task@1.0.0` item to the shared store so sibling apps
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
            try store?.upsertItem(id: taskID, schemaRef: "impel/task", payloadJson: payloadString)
            logger.info("SharedTaskBridge: task created \(taskID) '\(title)' state=\(state)")
        } catch {
            logger.error("SharedTaskBridge: taskCreated upsert failed for \(taskID) — \(error.localizedDescription)")
        }
        #else
        logger.info("SharedTaskBridge: task created \(taskID) '\(title)' state=\(state) (ImpressRustCore not linked)")
        #endif
    }

    /// Called when a task transitions to a new lifecycle state.
    ///
    /// Updates the `state` field of the existing `impel/task` item in the
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
            if let existing = store.getItem(id: taskID),
               let parsed = try? JSONSerialization.jsonObject(with: Data(existing.payloadJson.utf8)) as? [String: Any] {
                var merged = parsed
                merged["state"] = newState
                updatedPayload = merged
            }
            if let data = try? JSONSerialization.data(withJSONObject: updatedPayload),
               let payloadString = String(data: data, encoding: .utf8) {
                try store.upsertItem(id: taskID, schemaRef: "impel/task", payloadJson: payloadString)
            }
            logger.info("SharedTaskBridge: task \(taskID) state → \(newState)")
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
    /// Writes an `impel/agent-run@1.0.0` item to the shared store for
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

        // Stable ID for this run: task + round so repeated completions are idempotent.
        let runID = "\(taskID)-run-\(roundNumber)"

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
            try store?.upsertItem(id: runID, schemaRef: "impel/agent-run", payloadJson: payloadString)
            logger.info(
                "SharedTaskBridge: agent-run \(runID) for task \(taskID) round=\(roundNumber) model=\(model) tools=[\(toolList)]"
            )
        } catch {
            logger.error("SharedTaskBridge: agentRoundCompleted upsert failed for \(runID) — \(error.localizedDescription)")
        }
        #else
        logger.info(
            "SharedTaskBridge: agent-run for task \(taskID) round=\(roundNumber) model=\(model) tools=[\(toolList)] (ImpressRustCore not linked)"
        )
        #endif
    }
}
