// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): pure row CONSTRUCTION
// (Foundation + ImpressRustCore). No store handle, no I/O.
//
//  AgentStoreWriter.swift
//  PublicationManagerCore
//
//  ADR-0022 D9 finding 1, closed for the task and agent-run kinds. See
//  `MailStoreWriter.swift`'s header for the full argument.
//
//  THE SCOPE LINE IS SHARPER HERE THAN ANYWHERE ELSE, so it is worth saying
//  twice: task LIFECYCLE is kernel-owned. `TaskStoreApi.transition` is the sole
//  legal state mutation (ADR-0015 D1, docs/status-lifecycle.md), and agent-run
//  rows are immutable provenance. Nothing in this file transitions anything —
//  it builds a row with a state field in it, which is what a FIXTURE needs and
//  is not what a state machine is. A production caller that wants to move a
//  task from `queued` to `running` calls impel; there is no shortcut here and
//  adding one would be a bug, not a feature.
//
//  `taskRow(state:)` therefore takes a raw string rather than a typed enum, and
//  `AgentStoreReader.taskStates` (the descriptor's declared lifecycle, in
//  canonical order) is the list a fixture should choose from.
//

import Foundation
import ImpressRustCore

/// Builds `task@1.0.0` and `agent-run@1.0.0` rows whose payload field names come
/// from `AgentStoreReader`'s own decoders.
public enum AgentStoreWriter {

    /// Re-exported from the reader, which reads them from the DESCRIPTORS.
    public static var taskSchemaRef: String { AgentStoreReader.taskSchema }
    public static var agentRunSchemaRef: String { AgentStoreReader.agentRunSchema }

    /// A `task@1.0.0` row.
    ///
    /// `state` should be one of `AgentStoreReader.taskStates` — the descriptor's
    /// declared lifecycle. A state outside it is not rejected here (this builds
    /// rows, it does not police the kernel), but it will render through
    /// `stateDisplayName`'s title-cased fallback and sort into no smart child.
    nonisolated public static func taskRow(
        id: String,
        title: String?,
        state: String?,
        description: String? = nil,
        assignedTo: String? = nil,
        createdMs: Int64? = nil,
        isStarred: Bool? = nil
    ) -> SharedItemUpsert {
        var payload = AgentTaskPayload()
        payload.title = title
        payload.state = state
        payload.description = description
        payload.assignedTo = assignedTo
        return ChassisPayloadRow.upsert(
            id: id, schemaRef: taskSchemaRef, parentID: nil,
            payload: payload, createdMs: createdMs, isStarred: isStarred)
    }

    /// An `agent-run@1.0.0` row (provenance, ADR-0005 §5).
    ///
    /// The kernel links `task —ProducedBy→ run` as a typed reference; this
    /// builds the run row only. A fixture that wants the edge adds it with
    /// `SharedStore.addReference` after both rows exist.
    nonisolated public static func agentRunRow(
        id: String,
        agentID: String?,
        model: String? = nil,
        promptHash: String? = nil,
        resultSummary: String? = nil,
        tokenCount: Int64? = nil,
        durationMs: Int64? = nil,
        createdMs: Int64? = nil
    ) -> SharedItemUpsert {
        var payload = AgentRunPayload()
        payload.agentID = agentID
        payload.model = model
        payload.promptHash = promptHash
        payload.resultSummary = resultSummary
        payload.tokenCount = tokenCount
        payload.durationMs = durationMs
        return ChassisPayloadRow.upsert(
            id: id, schemaRef: agentRunSchemaRef, parentID: nil,
            payload: payload, createdMs: createdMs)
    }
}
