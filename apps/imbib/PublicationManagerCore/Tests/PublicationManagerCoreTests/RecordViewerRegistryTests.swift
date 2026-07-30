//
//  RecordViewerRegistryTests.swift
//  PublicationManagerCoreTests
//
//  WP G3 (ADR-0022 D4): the viewer-registry seam — which kinds resolve their
//  section view through the registry, which deliberately do NOT (publications
//  and manuscripts keep legacy routing), the KindTaggedRow projections of the
//  per-kind row structs, and the unknown-kind default path.
//
//  Mirrors RecordKindDescriptorTests: the assertions ARE the contract, so a
//  new kind's viewer registration is a conscious edit here.
//

import SwiftUI
import XCTest
import ImpressRustCore
@testable import PublicationManagerCore

#if os(macOS)
final class RecordViewerRegistryTests: XCTestCase {

    // MARK: - Builtin coverage

    /// Every kind whose section view SectionContentView resolves through the
    /// registry must have a factory.
    func testBuiltinCoversRegistryRoutedKinds() {
        let registry = RecordViewerRegistry.builtin
        for kind: RecordKindID in [.figure, .message, .task, .agentRun] {
            XCTAssertNotNil(
                registry[kind],
                "\(kind.rawValue) routes through the registry — it needs a factory")
        }
    }

    /// The absence list is the point: publications keep the fragile
    /// HSplitView + toolbar path, manuscripts keep the host-owned editor
    /// session (imbib CLAUDE.md). Registering either is a deliberate act that
    /// must fail this test first.
    func testBuiltinOmitsLegacyRoutedKinds() {
        let registry = RecordViewerRegistry.builtin
        XCTAssertNil(registry[.publication], "publications keep legacy routing")
        XCTAssertNil(registry[.manuscript], "manuscripts keep legacy routing")
        XCTAssertNil(registry[.artifact], "artifacts have no section view")
    }

    func testBuiltinRegisteredKindsAreExactlyTheNewerKinds() {
        XCTAssertEqual(
            RecordViewerRegistry.builtin.registeredKinds,
            Set([.figure, .message, .task, .agentRun] as [RecordKindID]))
    }

    /// Agent tasks and runs are separate kinds sharing one section view —
    /// both must resolve, since AgentListScope picks the key.
    func testAgentKindsBothResolve() {
        XCTAssertEqual(RecordViewerRegistry.builtin[.task]?.kind, .task)
        XCTAssertEqual(RecordViewerRegistry.builtin[.agentRun]?.kind, .agentRun)
    }

    // MARK: - Lookup / registration

    func testUnknownKindLookupReturnsNil() {
        XCTAssertNil(RecordViewerRegistry.builtin[RecordKindID("dataset")])
        XCTAssertNil(RecordViewerRegistry()[.figure])
        XCTAssertTrue(RecordViewerRegistry().registeredKinds.isEmpty)
    }

    @MainActor
    func testRegisterAddsAndReplacesByKind() {
        let registry = RecordViewerRegistry()
        let kind = RecordKindID("dataset")
        registry.register(RecordViewerFactory(
            kind: kind, makeSectionView: { _ in AnyView(Text("first")) }))
        XCTAssertEqual(registry.registeredKinds, [kind])

        registry.register(RecordViewerFactory(
            kind: kind, makeSectionView: { _ in AnyView(Text("second")) }))
        XCTAssertEqual(registry.registeredKinds, [kind], "same kind replaces, never duplicates")
        XCTAssertNotNil(registry[kind])
    }

    /// A factory handed a scope it doesn't own degrades instead of trapping.
    ///
    /// Stage 3: the context carries the CHASSIS scope (`RecordSidebarScope`)
    /// and each kind rebuilds its own, so "a scope it doesn't own" is now a
    /// scope naming a different KIND — which is what the sink actually hands
    /// over. The nil half is the load-bearing half.
    @MainActor
    func testSectionContextTypedScopeAccessor() {
        let context = RecordSectionContext(scope: .all(.figure))
        XCTAssertEqual(context.scope(as: FigureListScope.self), .all)
        XCTAssertNil(context.scope(as: MessageListScope.self))
        XCTAssertNil(context.scope(as: ManuscriptListScope.self))
        XCTAssertNil(context.scope(as: AgentListScope.self))
    }

    // MARK: - KindTaggedRow projections

    @MainActor
    func testFigureRowProjection() {
        let id = UUID()
        let figure = FigureRowData(from: SharedItemRow(
            id: id.uuidString.lowercased(),
            schemaRef: "figure",
            payloadJson: #"{"title":"Power spectrum","caption":"z=6","format":"png","data_hash":"abc123"}"#,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_100_000,
            parentId: nil,
            isRead: true,
            isStarred: true,
            tags: ["projects/reionization"],
            flagColor: "red"))
        guard let figure else { return XCTFail("figure row should map") }

        let row = KindTaggedRow(figure: figure)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.kind, .figure)
        XCTAssertEqual(row.titleText, figure.titleText)
        XCTAssertEqual(row.headerText, "PNG")
        XCTAssertEqual(row.date, figure.date)
        XCTAssertTrue(row.isStarred)
        XCTAssertTrue(row.hasAttachment, "paperclip = CAS artifact present")
        XCTAssertEqual(row.flag?.color, .red)
        XCTAssertEqual(row.tagDisplays.map(\.leaf), ["reionization"])
    }

    @MainActor
    func testMessageRowProjection() {
        let id = UUID()
        let message = MessageRowData(from: SharedItemRow(
            id: id.uuidString.lowercased(),
            schemaRef: "email-message",
            payloadJson: #"{"subject":"Referee report","body":"please revise","from":"editor@journal.org"}"#,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_100_000,
            parentId: nil,
            isRead: false,
            isStarred: false,
            tags: [],
            flagColor: nil))
        guard let message else { return XCTFail("message row should map") }

        let row = KindTaggedRow(message: message)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.kind, .message)
        XCTAssertEqual(row.titleText, "Referee report")
        XCTAssertEqual(row.headerText, "editor@journal.org")
        XCTAssertFalse(row.isRead, "mail keeps real unread semantics")
        XCTAssertEqual(row.date, message.messageDate)
    }

    @MainActor
    func testTaskAndRunRowProjections() {
        let taskID = UUID()
        let task = TaskRowData(from: SharedItemRow(
            id: taskID.uuidString.lowercased(),
            schemaRef: "task@1.0.0",
            payloadJson: #"{"title":"Summarize inbox","state":"queued","description":"…"}"#,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_100_000,
            parentId: nil,
            isRead: true,
            isStarred: false,
            tags: [],
            flagColor: nil))
        guard let task else { return XCTFail("task row should map") }

        let taskRow = KindTaggedRow(task: task)
        XCTAssertEqual(taskRow.id, taskID)
        XCTAssertEqual(taskRow.kind, .task)
        XCTAssertEqual(taskRow.titleText, "Summarize inbox")

        let runID = UUID()
        let run = AgentRunRowData(from: SharedItemRow(
            id: runID.uuidString.lowercased(),
            schemaRef: "agent-run@1.0.0",
            payloadJson: #"{"agent_id":"counsel","model":"opus","result_summary":"Done\nmore"}"#,
            createdMs: 1_700_000_000_000,
            modifiedMs: 1_700_000_100_000,
            parentId: nil,
            isRead: true,
            isStarred: false,
            tags: [],
            flagColor: nil))
        guard let run else { return XCTFail("run row should map") }

        let runRow = KindTaggedRow(agentRun: run)
        XCTAssertEqual(runRow.id, runID)
        XCTAssertEqual(runRow.kind, .agentRun)
        XCTAssertEqual(runRow.titleText, "Done", "first line of the result summary")
        XCTAssertEqual(runRow.headerText, "counsel")
    }

    @MainActor
    func testManuscriptRowProjection() {
        let id = UUID()
        let manuscript = ManuscriptRowData(from: ManuscriptRow(
            id: id.uuidString.lowercased(),
            title: "Reionization draft",
            authorString: "Abel, T.",
            status: "draft",
            format: "typst",
            journalTarget: nil,
            bodyContentHash: nil,
            bodyModifiedAt: nil,
            bodySize: 0,
            bodyIsBlobRef: false,
            revisionCount: 0,
            isRead: true,
            isStarred: false,
            flagColor: nil,
            flagStyle: nil,
            flagLength: nil,
            tags: [],
            dateAdded: 1_700_000_000_000,
            dateModified: 1_700_000_100_000))
        guard let manuscript else { return XCTFail("manuscript row should map") }

        let row = KindTaggedRow(manuscript: manuscript)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.kind, .manuscript)
        XCTAssertEqual(row.titleText, "Reionization draft")
        XCTAssertEqual(row.headerText, "Abel, T.")
    }

    // MARK: - AnyRecordListWrapper

    /// The detail pane follows the first selected row in DISPLAY order —
    /// `Set<UUID>.first` is unordered and would flip between rows.
    @MainActor
    func testPrimaryRowFollowsDisplayOrder() {
        let rows = [
            makeRow(kind: .message, title: "one"),
            makeRow(kind: .figure, title: "two"),
            makeRow(kind: .agentRun, title: "three"),
        ]
        XCTAssertNil(AnyRecordListWrapper.primaryRow(in: [], of: rows))
        XCTAssertEqual(
            AnyRecordListWrapper.primaryRow(in: [rows[2].id, rows[1].id], of: rows)?.titleText,
            "two")
        XCTAssertEqual(
            AnyRecordListWrapper.primaryRow(in: [rows[0].id], of: rows)?.kind,
            .message)
    }

    /// A kind with no registered factory still renders — the wrapper falls
    /// back to the shared mail-style chrome rather than dropping the row.
    @MainActor
    func testRowFactoryDefaultsForUnregisteredKind() {
        let registry = RecordViewerRegistry.builtin
        let known = makeRow(kind: .figure, title: "figure")
        let unknown = makeRow(kind: RecordKindID("dataset"), title: "dataset")
        XCTAssertNotNil(registry[known.kind]?.makeListRow(known))
        XCTAssertNil(registry[unknown.kind], "no factory — the wrapper renders MailStyleRow")
    }

    @MainActor
    private func makeRow(kind: RecordKindID, title: String) -> KindTaggedRow {
        KindTaggedRow(
            id: UUID(), kind: kind, headerText: kind.rawValue,
            titleText: title, date: Date(timeIntervalSince1970: 0))
    }
}
#endif
