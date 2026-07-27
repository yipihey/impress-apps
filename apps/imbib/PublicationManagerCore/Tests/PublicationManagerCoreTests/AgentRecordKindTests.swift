//
//  AgentRecordKindTests.swift
//  PublicationManagerCoreTests
//
//  Stage 2-C (ADR-0021): the task / agent-run record kinds' descriptor
//  contracts — always-available tabs, KERNEL-owned lifecycle (no
//  dismiss/delete; TaskStoreApi.transition is the sole legal state
//  mutation), scope identity determinism, row mappings, and the impel shell
//  preset — mirroring MessageRecordKindTests.
//

import SwiftUI
import XCTest
import ImpressRustCore
@testable import PublicationManagerCore

#if os(macOS)
final class AgentRecordKindTests: XCTestCase {

    // MARK: - Descriptor tab contract

    /// Tasks and runs have no gating context — Info/Source/View are always
    /// available (the View tab is DetailTab.pdf relabeled: MarkdownUI-
    /// rendered result summary).
    func testAllTabsAlwaysAvailable() {
        for descriptor in [TaskRecordKind.descriptor, AgentRunRecordKind.descriptor] {
            for context in [
                RecordTabContext(),
                RecordTabContext(isEditable: false),
                RecordTabContext(previewKind: DocumentFormat.PreviewKind.none),
                RecordTabContext(previewKind: .compiledPDF),
            ] {
                XCTAssertEqual(
                    descriptor.availableTabs(for: context),
                    [.info, .source, .pdf],
                    "\(descriptor.displayName) tabs must be unconditional")
            }
        }
    }

    func testCoercionKeepsValidTabsAndLandsOnInfoOtherwise() {
        let context = RecordTabContext()
        for descriptor in [TaskRecordKind.descriptor, AgentRunRecordKind.descriptor] {
            XCTAssertEqual(descriptor.coercedTab(.info, for: context), .info)
            XCTAssertEqual(descriptor.coercedTab(.source, for: context), .source)
            XCTAssertEqual(descriptor.coercedTab(.pdf, for: context), .pdf)
            // Tabs outside the agent sets coerce to info.
            XCTAssertEqual(descriptor.coercedTab(.notes, for: context), .info)
            XCTAssertEqual(descriptor.coercedTab(.bibtex, for: context), .info)
        }
    }

    // MARK: - Triage contract (kernel-only lifecycle)

    func testTaskTriageCapabilitiesMatchContract() {
        let triage = TaskRecordKind.descriptor.triage
        XCTAssertTrue(triage.canStar)
        XCTAssertTrue(triage.canFlag)
        XCTAssertTrue(triage.canTag)
        XCTAssertEqual(triage.dismissal, .none,
                       "task state moves ONLY through TaskStoreApi.transition — "
                       + "a .statusChange dismissal would bypass the kernel")
        XCTAssertNil(triage.archiveStatus)
        XCTAssertEqual(triage.deletion, .none,
                       "task deletion is kernel-owned, never the chassis")
        XCTAssertEqual(triage.statuses, [],
                       "the kernel lifecycle lives in payload `state`, not the "
                       + "chassis's `status` machinery")
        XCTAssertTrue(TaskRecordKind.descriptor.creation.isEmpty,
                      "tasks are scheduled by impel-taskd/counsel, not `n`")
        XCTAssertEqual(TaskRecordKind.descriptor.defaultOpenBehavior, .detailPane)
    }

    func testAgentRunTriageCapabilitiesMatchContract() {
        let triage = AgentRunRecordKind.descriptor.triage
        XCTAssertTrue(triage.canStar)
        XCTAssertTrue(triage.canFlag)
        XCTAssertTrue(triage.canTag)
        XCTAssertEqual(triage.dismissal, .none,
                       "runs are immutable provenance records — no lifecycle verbs")
        XCTAssertNil(triage.archiveStatus)
        XCTAssertEqual(triage.deletion, .none)
        XCTAssertEqual(triage.statuses, [])
        XCTAssertTrue(AgentRunRecordKind.descriptor.creation.isEmpty,
                      "runs are recorded by the kernel, never by hand")
        XCTAssertEqual(AgentRunRecordKind.descriptor.defaultOpenBehavior, .detailPane)
    }

    /// Schema refs are VERSIONED — impel-core's TaskStoreApi writes
    /// `task@1.0.0` / `agent-run@1.0.0` (task_store.rs), unlike mail's
    /// unversioned refs.
    func testRegistryLookupByVersionedSchemaRef() {
        let registry = AppShellConfiguration.impel.recordKinds
        XCTAssertEqual(registry.descriptor(forSchemaRef: "task@1.0.0")?.id, .task)
        XCTAssertEqual(registry.descriptor(forSchemaRef: "agent-run@1.0.0")?.id, .agentRun)
        XCTAssertEqual(registry[.task]?.displayName, "Task")
        XCTAssertEqual(registry[.agentRun]?.displayName, "Agent Run")
    }

    // MARK: - Scope identity

    func testScopeStableViewIDsAreDeterministicAndDistinct() {
        XCTAssertEqual(
            AgentListScope.tasks.stableViewID,
            AgentListScope.tasks.stableViewID,
            "same scope must produce the same id across evaluations")
        XCTAssertNotEqual(
            AgentListScope.tasks.stableViewID,
            AgentListScope.runs.stableViewID)
        XCTAssertNotEqual(
            AgentListScope.tasks.stableViewID,
            AgentListScope.tasksByState("queued").stableViewID)
        XCTAssertNotEqual(
            AgentListScope.tasksByState("queued").stableViewID,
            AgentListScope.tasksByState("running").stableViewID)
        XCTAssertEqual(
            AgentListScope.tasksByState("failed").stableViewID,
            AgentListScope.tasksByState("failed").stableViewID)
    }

    func testScopeKeysAreNamespacedAgainstOtherKinds() {
        XCTAssertTrue(AgentListScope.tasks.scopeKey.hasPrefix("agents-"))
        XCTAssertTrue(AgentListScope.runs.scopeKey.hasPrefix("agents-"))
        XCTAssertNotEqual(
            AgentListScope.tasks.stableViewID,
            MessageListScope.allInboxes.stableViewID)
        XCTAssertNotEqual(
            AgentListScope.runs.stableViewID,
            FigureListScope.all.stableViewID)
    }

    // MARK: - Row models

    @MainActor
    func testTaskRowDataMapsSharedItemRow() {
        let id = UUID()
        let row = SharedItemRow(
            id: id.uuidString.lowercased(),
            schemaRef: "task@1.0.0",
            payloadJson: #"{"title":"Summarize referee report","state":"waiting_review","description":"Read the report and draft a response.","assigned_to":"counsel"}"#,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_100_000,
            parentId: nil,
            isRead: false,
            isStarred: true,
            tags: ["projects/reionization"],
            flagColor: "red")
        guard let data = TaskRowData(from: row) else {
            return XCTFail("row should map")
        }
        XCTAssertEqual(data.id, id)
        XCTAssertEqual(data.title, "Summarize referee report")
        XCTAssertEqual(data.state, "waiting_review")
        XCTAssertEqual(data.taskDescription, "Read the report and draft a response.")
        XCTAssertEqual(data.assignedTo, "counsel")
        XCTAssertTrue(data.isStarred)
        XCTAssertEqual(data.flag?.color, .red)
        XCTAssertEqual(data.tagDisplays.map(\.leaf), ["reionization"])
        // MailStyleItem projections
        XCTAssertEqual(data.headerText, "Waiting Review",
                       "header = humanized kernel state")
        XCTAssertEqual(data.titleText, "Summarize referee report")
        XCTAssertEqual(data.subtitleText, "waiting_review")
        XCTAssertEqual(data.trailingBadgeText, "counsel",
                       "badge = the claiming agent")
        XCTAssertEqual(data.previewText, "Read the report and draft a response.")
        XCTAssertFalse(data.isRead,
                       "the ENVELOPE read flag is kept — not derived from state")
        XCTAssertEqual(
            data.date,
            Date(timeIntervalSince1970: 1_700_000_100),
            "task rows date by modifiedMs (last transition)")
        XCTAssertFalse(data.hasAttachment)
    }

    @MainActor
    func testTaskRowDataDefaults() {
        let row = SharedItemRow(
            id: UUID().uuidString.lowercased(),
            schemaRef: "task@1.0.0",
            payloadJson: "{}",
            createdMs: 0, modifiedMs: 0,
            parentId: nil, isRead: true, isStarred: false,
            tags: [], flagColor: nil)
        guard let data = TaskRowData(from: row) else {
            return XCTFail("row should map")
        }
        XCTAssertEqual(data.titleText, "Untitled task")
        XCTAssertEqual(data.state, "queued", "missing state defaults to queued")
        XCTAssertNil(data.trailingBadgeText, "no badge when unassigned")
        XCTAssertNil(data.previewText)
        XCTAssertNil(data.flag)
        XCTAssertTrue(data.isRead)
        // Non-UUID store ids don't map (defensive).
        let bad = SharedItemRow(
            id: "not-a-uuid", schemaRef: "task@1.0.0", payloadJson: "{}",
            createdMs: 0, modifiedMs: 0, parentId: nil,
            isRead: true, isStarred: false, tags: [], flagColor: nil)
        XCTAssertNil(TaskRowData(from: bad))
    }

    @MainActor
    func testAgentRunRowDataMapsSharedItemRow() {
        let id = UUID()
        let row = SharedItemRow(
            id: id.uuidString.lowercased(),
            schemaRef: "agent-run@1.0.0",
            payloadJson: ##"{"agent_id":"counsel","model":"claude-sonnet","prompt_hash":"abc123","result_summary":"# Done\n\nDrafted the response.","token_count":1234,"duration_ms":5600}"##,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_100_000,
            parentId: nil,
            isRead: true,
            isStarred: false,
            tags: [],
            flagColor: nil)
        guard let data = AgentRunRowData(from: row) else {
            return XCTFail("row should map")
        }
        XCTAssertEqual(data.id, id)
        XCTAssertEqual(data.agentID, "counsel")
        XCTAssertEqual(data.model, "claude-sonnet")
        XCTAssertEqual(data.promptHash, "abc123")
        XCTAssertEqual(data.resultSummary, "# Done\n\nDrafted the response.")
        XCTAssertEqual(data.tokenCount, 1234)
        XCTAssertEqual(data.durationMs, 5600)
        // MailStyleItem projections
        XCTAssertEqual(data.headerText, "counsel", "header = the invoking agent")
        XCTAssertEqual(data.titleText, "# Done",
                       "title = first line of the result summary")
        XCTAssertEqual(data.subtitleText, "claude-sonnet")
        XCTAssertEqual(data.trailingBadgeText, "1234 tok · 5.6s")
        XCTAssertEqual(data.previewText, "# Done Drafted the response.",
                       "preview collapses whitespace runs")
        XCTAssertEqual(
            data.date,
            Date(timeIntervalSince1970: 1_700_000_000),
            "runs are append-only — dates come from createdMs")
    }

    @MainActor
    func testAgentRunRowDataFallsBackToModelTitle() {
        let row = SharedItemRow(
            id: UUID().uuidString.lowercased(),
            schemaRef: "agent-run@1.0.0",
            payloadJson: #"{"agent_id":"scout","model":"claude-haiku","prompt_hash":"h"}"#,
            createdMs: 0, modifiedMs: 0,
            parentId: nil, isRead: true, isStarred: false,
            tags: [], flagColor: nil)
        guard let data = AgentRunRowData(from: row) else {
            return XCTFail("row should map")
        }
        XCTAssertEqual(data.titleText, "claude-haiku",
                       "no result_summary → title falls back to the model")
        XCTAssertNil(data.previewText)
        XCTAssertNil(data.trailingBadgeText, "no metrics recorded → no badge")
    }

    // MARK: - State display helpers

    func testStateDisplayNamesAndOrder() {
        XCTAssertEqual(AgentStoreReader.taskStates,
                       ["queued", "running", "waiting_review",
                        "completed", "failed", "cancelled"],
                       "canonical kernel pipeline order")
        XCTAssertEqual(AgentStoreReader.stateDisplayName("waiting_review"),
                       "Waiting Review")
        XCTAssertEqual(AgentStoreReader.stateDisplayName("queued"), "Queued")
    }

    // MARK: - impel shell preset

    func testImpelPresetMatchesContract() {
        let c = AppShellConfiguration.impel
        XCTAssertEqual(c.appID, "impel")
        XCTAssertEqual(c.visibleSections, [.agents],
                       "Flagged is deliberately skipped in v1")
        XCTAssertEqual(c.defaultSection, .agents)
        XCTAssertEqual(c.defaultDetailTab, .info)
        XCTAssertEqual(c.openBehavior(for: .task), .detailPane)
        XCTAssertEqual(c.openBehavior(for: .agentRun), .detailPane)
        XCTAssertTrue(c.customSurfaces.isEmpty,
                      "dashboard/escalations/suggestions/counsel register "
                      + "app-side via withCustomSurfaces")
        XCTAssertFalse(c.permits(.inbox))
        XCTAssertFalse(c.permits(.manuscripts))
        XCTAssertFalse(c.permits(.figures))
        XCTAssertFalse(c.permits(.mail))
        XCTAssertTrue(c.permits(.agents))
    }

    /// The Agents section stays hidden outside impel: imprint/implore/impart
    /// exclude it via visibleSections; imbib permits everything (nil) but
    /// the content gate (`shouldShowSection` appID == "impel") keeps it out
    /// — the preset half of that contract is assertable here.
    func testAgentsSectionGatingAcrossPresets() {
        XCTAssertFalse(AppShellConfiguration.imprint.permits(.agents))
        XCTAssertFalse(AppShellConfiguration.implore.permits(.agents))
        XCTAssertFalse(AppShellConfiguration.impart.permits(.agents))
        // imbib's visibleSections is nil → permits everything; the appID
        // content gate (not testable here — private) is the actual guard.
        XCTAssertTrue(AppShellConfiguration.imbib.permits(.agents))
        XCTAssertNotEqual(AppShellConfiguration.imbib.appID, "impel")
    }

    @MainActor
    func testWithCustomSurfacesPreservesShellIdentity() {
        let surface = CustomSurfaceDescriptor(
            id: "dashboard", title: "Dashboard", systemImage: "square.grid.2x2",
            makeView: { AnyView(EmptyView()) })
        let extended = AppShellConfiguration.impel.withCustomSurfaces([surface])
        XCTAssertEqual(extended.appID, "impel")
        XCTAssertEqual(extended.visibleSections, [.agents])
        XCTAssertEqual(extended.defaultSection, .agents)
        XCTAssertEqual(extended.customSurfaces["dashboard"]?.title, "Dashboard")
        XCTAssertNotEqual(extended, .impel, "surface ids participate in equality")
    }
}
#endif
