// Chassis file — CROSS-PLATFORM (macOS + iOS) since ADR-0022 D9.
//
// Gated `#if os(macOS)` with the comment "macOS-only in GUI-meld Phase 1 (iOS
// keeps IOSContentView)", which was historical, not technical: plain SwiftUI
// over `AgentStoreReader` and `RelatedItemsSection` (both already
// cross-platform) and MarkdownUI (which ships iOS), with exactly ONE AppKit
// call — `Color(NSColor.textBackgroundColor)`, for which `ImpressTheme` has
// shipped `Color.platformTextBackground` since the ADR-023 parity protocol.
// impress-iOS was the first host to want a task/run detail on a phone; the
// honest answer is to fix the chassis rather than fork the pane app-side.
//
//  AgentRecordDetailPane.swift
//  PublicationManagerCore
//
//  The tabbed agent-record detail (Stage 2-C): the standard chassis detail
//  experience for `task@1.0.0` / `agent-run@1.0.0` items, mirroring
//  MessageDetailPane's tab host — Info / Source / View, from the
//  TaskRecordKind / AgentRunRecordKind descriptors.
//
//  - Task — Info: state/assignee/description/dates (+ run provenance);
//    Source: the task description/prompt text, monospaced; View
//    (DetailTab.pdf relabeled): the LATEST run's result_summary rendered
//    with MarkdownUI (summaries are Markdown documents).
//  - AgentRun — Info: agent/model/prompt-hash metadata, timings, tokens;
//    Source: the raw result_summary, monospaced; View: the result_summary
//    rendered with MarkdownUI.
//
//  MarkdownUI is an allowlisted PMC dependency (scripts/check-chassis-deps.sh)
//  — same renderer the markdown-manuscript Preview tab uses. No WebKit.
//

import SwiftUI
import ImpressFTUI
import ImpressRustCore
import ImpressTheme
import MarkdownUI

/// Which agent record kind the pane shows (the section's scope decides).
public enum AgentDetailKind: Sendable, Hashable {
    case task
    case run

    var descriptor: RecordKindDescriptor {
        switch self {
        case .task: return TaskRecordKind.descriptor
        case .run: return AgentRunRecordKind.descriptor
        }
    }
}

public struct AgentRecordDetailPane: View {

    let kind: AgentDetailKind
    let recordID: UUID
    @Binding var selectedTab: DetailTab

    /// Top clearance for the tab picker (the section host reclaims the
    /// toolbar band with `.ignoresSafeArea(.top)` — same as messages).
    let topInset: CGFloat

    @State private var taskRow: TaskRowData?
    @State private var runRow: AgentRunRowData?
    /// The displayed task's newest recorded run (Task View tab), if any.
    @State private var latestRun: AgentRunRowData?

    public init(
        kind: AgentDetailKind,
        recordID: UUID,
        selectedTab: Binding<DetailTab>,
        topInset: CGFloat = 0
    ) {
        self.kind = kind
        self.recordID = recordID
        self._selectedTab = selectedTab
        self.topInset = topInset
    }

    /// All agent tabs are unconditionally available (info/source/view) —
    /// the context carries no gating fields for these kinds.
    private var tabContext: RecordTabContext { RecordTabContext() }

    private var availableTabs: [DetailTab] {
        kind.descriptor.availableTabs(for: tabContext)
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.top, topInset)
            Divider()
            content
        }
        .onChange(of: recordID, initial: true) { _, id in
            load(id: id)
            let coerced = kind.descriptor.coercedTab(selectedTab, for: tabContext)
            if coerced != selectedTab { selectedTab = coerced }
        }
        .task(id: recordID) {
            // Refresh the snapshot when the displayed record mutates
            // elsewhere in-process (star/flag/tag via the generic ops).
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if case .itemsMutated(_, let ids) = event, ids.contains(recordID) {
                    load(id: recordID)
                }
            }
        }
    }

    private func load(id: UUID) {
        let reader = AgentStoreReader.shared
        switch kind {
        case .task:
            taskRow = reader.fetchTask(id: id.uuidString)
                .flatMap { TaskRowData(from: $0) }
            latestRun = reader.fetchLatestRun(forTask: id.uuidString)
                .flatMap { AgentRunRowData(from: $0) }
            runRow = nil
        case .run:
            runRow = reader.fetchRun(id: id.uuidString)
                .flatMap { AgentRunRowData(from: $0) }
            taskRow = nil
            latestRun = nil
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(availableTabs) { tab in
                // The agent "PDF" tab is really the rendered-Markdown
                // surface — label it "View".
                Label(tab == .pdf ? "View" : tab.label,
                      systemImage: tab == .pdf ? "text.justify.left" : tab.icon).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .info:
            infoTab
        case .source:
            sourceTab
        case .pdf:
            viewTab
        case .notes, .bibtex:
            // Not part of the agent tab sets; coerced away on entry.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Info tab

    @ViewBuilder
    private var infoTab: some View {
        switch kind {
        case .task:
            if let row = taskRow { taskInfo(row) } else { unavailable }
        case .run:
            if let row = runRow { runInfo(row) } else { unavailable }
        }
    }

    private func taskInfo(_ row: TaskRowData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(row.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    infoRow("State", AgentStoreReader.stateDisplayName(row.state))
                    infoRow("Assigned To", row.assignedTo ?? "—")
                    infoRow("Created", row.dateCreated.formatted(date: .abbreviated, time: .shortened))
                    infoRow("Modified", row.dateModified.formatted(date: .abbreviated, time: .shortened))
                }

                if !row.taskDescription.isEmpty {
                    Divider()
                    Text("Description")
                        .font(.headline)
                    Text(row.taskDescription)
                        .textSelection(.enabled)
                }

                if let latestRun {
                    Divider()
                    Text("Latest Run")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        infoRow("Agent", latestRun.agentID.isEmpty ? "—" : latestRun.agentID)
                        infoRow("Model", latestRun.model.isEmpty ? "—" : latestRun.model)
                        if let metrics = latestRun.metricsText {
                            infoRow("Metrics", metrics)
                        }
                        infoRow("Recorded", latestRun.dateCreated.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                // ADR-0022 D8 (G5): the runs, messages and artifacts this
                // task is edge-linked to (`ProducedBy` & co.). Renders
                // nothing when there are none.
                RelatedItemsSection(itemID: recordID)

                triageFooter(flag: row.flag, tags: row.tagDisplays)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runInfo(_ row: AgentRunRowData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(row.titleText)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    infoRow("Agent", row.agentID.isEmpty ? "—" : row.agentID)
                    infoRow("Model", row.model.isEmpty ? "—" : row.model)
                    if let promptHash = row.promptHash {
                        infoRow("Prompt Hash", promptHash, monospaced: true)
                    }
                    if let tokenCount = row.tokenCount {
                        infoRow("Tokens", "\(tokenCount)")
                    }
                    if let durationMs = row.durationMs {
                        infoRow("Duration", String(format: "%.1f s", Double(durationMs) / 1000.0))
                    }
                    infoRow("Recorded", row.dateCreated.formatted(date: .abbreviated, time: .shortened))
                }

                // ADR-0022 D8 (G5): the task this run answered, the artifacts
                // it produced. Renders nothing when there are none.
                RelatedItemsSection(itemID: recordID)

                triageFooter(flag: row.flag, tags: row.tagDisplays)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func triageFooter(flag: PublicationFlag?, tags: [TagDisplayData]) -> some View {
        if flag != nil || !tags.isEmpty {
            Divider()
        }
        if let flag {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                    .foregroundStyle(flag.color.displayColor)
                Text(flag.color.displayName)
                    .foregroundStyle(.secondary)
            }
        }
        if !tags.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(tags) { tag in
                    TagChip(tag: tag)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    // MARK: Source tab (raw text, monospaced)

    /// Task: the description/prompt text. Run: the raw result_summary.
    private var sourceText: String? {
        switch kind {
        case .task:
            return taskRow.map(\.taskDescription)
        case .run:
            return runRow.map { $0.resultSummary ?? "" }
        }
    }

    @ViewBuilder
    private var sourceTab: some View {
        if let text = sourceText {
            ScrollView {
                Text(text.isEmpty
                    ? (kind == .task ? "(no description)" : "(no result summary)")
                    : text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else {
            unavailable
        }
    }

    // MARK: View tab (MarkdownUI-rendered result summary)

    /// Task: the LATEST run's result_summary. Run: its own result_summary.
    private var viewMarkdown: String? {
        switch kind {
        case .task:
            return latestRun?.resultSummary
        case .run:
            return runRow?.resultSummary
        }
    }

    @ViewBuilder
    private var viewTab: some View {
        if (kind == .task ? taskRow != nil : runRow != nil) {
            if let markdown = viewMarkdown, !markdown.isEmpty {
                ScrollView {
                    Markdown(markdown)
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.platformTextBackground)
            } else {
                ContentUnavailableView(
                    kind == .task ? "No Run Recorded" : "No Result Summary",
                    systemImage: "bolt.slash",
                    description: Text(kind == .task
                        ? "The rendered view shows the latest run's result summary once an agent records one."
                        : "This run recorded no result summary.")
                )
            }
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            kind == .task ? "Task Unavailable" : "Run Unavailable",
            systemImage: kind == .task ? "checklist" : "bolt",
            description: Text("This record could not be read from the store.")
        )
    }
}
