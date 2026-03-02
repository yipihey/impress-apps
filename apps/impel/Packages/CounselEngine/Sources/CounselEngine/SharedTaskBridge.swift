import Foundation
import ImpressKit
import OSLog

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

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.impress.impel", category: "shared-task-bridge")

    // MARK: - Initialization

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let path = SharedWorkspace.databaseURL.path
            databasePath = path
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
        // TODO(unit9): Call SqliteItemStore.registerSchema("impel/task", version: "1.0.0")
        //              and SqliteItemStore.registerSchema("impel/agent-run", version: "1.0.0")
        //              once the impress-core UniFFI bindings for the shared store are available.
        logger.info(
            "SharedTaskBridge: schema registration deferred (impress-core UniFFI not yet wired)"
        )
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

        // TODO(unit9): Construct an impress-core `Item` with:
        //
        //   schema: "impel/task"
        //   payload: {
        //       "title": title,
        //       "state": state,
        //       "description": description ?? "",
        //       "source_app": sourceApp,
        //       "external_id": taskID
        //   }
        //
        // Then call:
        //   try sqliteItemStore.upsert(item)
        //
        // where `sqliteItemStore` is a lazily-opened `SqliteItemStore(path: databasePath)`.

        logger.info("SharedTaskBridge: task created \(taskID) '\(title)' state=\(state) (FFI TODO)")
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

        // TODO(unit9): Look up the shared item by external_id == taskID,
        //              then call sqliteItemStore.setPayload(field: "state", value: newState)
        //              via a SetPayload operation.

        logger.info("SharedTaskBridge: task \(taskID) state → \(newState) (FFI TODO)")
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

        // TODO(unit9): Construct an impress-core `Item` with:
        //
        //   schema: "impel/agent-run"
        //   payload: {
        //       "agent_id": agentID,
        //       "model": model,
        //       "prompt_hash": promptHash,
        //       "token_count": tokenCount,
        //       "duration_ms": durationMs,
        //       "tool_calls": toolCalls,          // StringArray field
        //       "status": finishReason ?? "completed",
        //       "finish_reason": finishReason,
        //       "round_number": roundNumber
        //   }
        //
        // Then:
        //   1. try sqliteItemStore.upsert(agentRunItem)
        //   2. Resolve the parent task item by external_id == taskID
        //   3. try sqliteItemStore.addReference(
        //          from: agentRunItem.id,
        //          to: taskItem.id,
        //          edgeType: .OperatesOn
        //      )

        let toolList = toolCalls.joined(separator: ", ")
        logger.info(
            "SharedTaskBridge: agent-run for task \(taskID) round=\(roundNumber) model=\(model) tools=[\(toolList)] (FFI TODO)"
        )
    }
}
