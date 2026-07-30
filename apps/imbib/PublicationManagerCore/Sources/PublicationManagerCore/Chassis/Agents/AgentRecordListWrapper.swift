#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  AgentRecordListWrapper.swift
//  PublicationManagerCore
//
//  The agents list pane of the unified chassis (Stage 2-C, ADR-0021). ONE
//  wrapper for BOTH agent record kinds — the scope decides which schema it
//  lists (tasks vs runs), so the section stays a single small clone of
//  MessageListWrapper: shared row chrome (ImpressMailStyle), selection
//  binding, and the shared triage builders (TriageSwipe/TriageMenu/
//  TriageKeyGrammar).
//
//  Deliberate v1 gaps (KERNEL-owned, documented in the capability matrix):
//  - no dismissal/deletion (descriptors declare .none/.none; task state
//    moves ONLY through TaskStoreApi.transition — `d` is ignored)
//  - no creation (tasks are scheduled by impel-taskd/counsel, not `n`)
//  - no drag (tasks/runs have no folder tree)
//

import SwiftUI
import AppKit
import ImpressFTUI
import ImpressKeyboard
import ImpressMailStyle
import ImpressRustCore
import ImpressStoreKit
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "agents")

// `AgentListScope` moved to Chassis/RecordKind/RecordScopeKey+ListScopes.swift
// (Stage 2a): the scope is a Foundation value type and is now
// cross-platform; only this wrapper is AppKit-adjacent.

// Actions: the shared RecordTriageActions (ADR-0021). Agents have no
// kind-specific verbs in v1 — open is the detail pane, and kernel-owned
// verbs (transition/claim/cancel) stay on impel's HTTP command path.

public struct AgentRecordListWrapper: View {

    let scope: AgentListScope
    @Binding var selectedID: UUID?
    var actions: RecordTriageActions

    @State private var taskRows: [TaskRowData] = []
    @State private var runRows: [AgentRunRowData] = []
    @State private var filterText: String = ""
    @State private var isLoading = false
    /// Full multi-selection; `selectedID` (the binding the detail pane
    /// follows) tracks its primary member.
    @State private var selectedIDs = Set<UUID>()

    @FocusState private var listFocused: Bool
    @FocusState private var filterFocused: Bool

    public init(
        scope: AgentListScope,
        selectedID: Binding<UUID?>,
        actions: RecordTriageActions = RecordTriageActions()
    ) {
        self.scope = scope
        self._selectedID = selectedID
        self.actions = actions
    }

    private var visibleTaskRows: [TaskRowData] {
        guard !filterText.isEmpty else { return taskRows }
        let q = filterText.lowercased()
        return taskRows.filter {
            $0.title.lowercased().contains(q)
                || $0.state.lowercased().contains(q)
                || $0.taskDescription.lowercased().contains(q)
                || ($0.assignedTo?.lowercased().contains(q) ?? false)
        }
    }

    private var visibleRunRows: [AgentRunRowData] {
        guard !filterText.isEmpty else { return runRows }
        let q = filterText.lowercased()
        return runRows.filter {
            $0.agentID.lowercased().contains(q)
                || $0.model.lowercased().contains(q)
                || ($0.resultSummary?.lowercased().contains(q) ?? false)
        }
    }

    /// Ordered visible ids, kind-agnostic (keyboard nav + selection repair).
    private var visibleIDs: [UUID] {
        scope.isRunScope ? visibleRunRows.map(\.id) : visibleTaskRows.map(\.id)
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            // `.focusable()` lives on the LIST ONLY, not the whole VStack: a
            // focusable wrapper around the filter TextField steals its key
            // events (CLAUDE.md "Do NOT put .focusable() on views that
            // contain text editors").
            listBody
                .focusable()
                .focused($listFocused)
                .keyboardGuarded { press in handleKey(press) }
        }
        // ⌘F target: whichever list is frontmost gets the Find in List command.
        .focusedSceneValue(\.listFilterFocusAction, { filterFocused = true })
        .task(id: scope) { await reload() }
        .task {
            // Row-level refresh. Star/flag/tag via the generic
            // RustStoreAdapter ops emit StoreEvents in-process. Kernel-driven
            // writes (impel-taskd transitions, new runs) land through impel's
            // OWN store handle and don't surface here — the list catches up
            // on the next reload (scope change / relaunch), the same
            // documented v1 limit as mail.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                switch event {
                case .structural:
                    await reload()
                case .itemsMutated(_, let ids):
                    let visible = Set(visibleIDs)
                    if ids.isEmpty || !visible.isDisjoint(with: ids) || visible.isEmpty {
                        await reload()
                    }
                case .collectionMembershipChanged:
                    // Tasks/runs have no Contains-edge folders.
                    break
                }
            }
        }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField(scope.isRunScope ? "Filter runs" : "Filter tasks", text: $filterText)
                .textFieldStyle(.plain)
                .focused($filterFocused)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: List

    @ViewBuilder
    private var listBody: some View {
        if isLoading && visibleIDs.isEmpty && filterText.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleIDs.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List(selection: $selectedIDs) {
                    if scope.isRunScope {
                        ForEach(visibleRunRows) { row in
                            listRow(
                                row,
                                isStarred: row.isStarredState,
                                tagPaths: row.tagPaths)
                        }
                    } else {
                        ForEach(visibleTaskRows) { row in
                            listRow(
                                row,
                                isStarred: row.isStarredState,
                                tagPaths: row.tagPaths)
                        }
                    }
                }
                .listStyle(.inset)
                // Two-way sync between the multi-selection and the primary
                // `selectedID` the detail pane follows (fixed-point guarded).
                .onChange(of: selectedIDs) { _, newIDs in
                    if let current = selectedID, newIDs.contains(current) { return }
                    selectedID = newIDs.first
                }
                .onChange(of: selectedID) { _, newID in
                    if let newID {
                        if !selectedIDs.contains(newID) { selectedIDs = [newID] }
                        proxy.scrollTo(newID)
                    } else if !selectedIDs.isEmpty {
                        selectedIDs = []
                    }
                }
            }
        }
    }

    /// One row with the shared chrome + triage builders — generic over the
    /// two MailStyleItem row kinds so the scope stays the only branch point.
    @ViewBuilder
    private func listRow(
        _ row: some MailStyleItem,
        isStarred: Bool,
        tagPaths: [String]
    ) -> some View {
        let triageRow = TriageRowState(
            isStarred: isStarred, isDismissed: false, isArchived: false)
        MailStyleRow(item: row)
            .tag(row.id)
            .id(row.id)
            .contextMenu {
                // The shared triage segment only: star, Flag and Tags
                // submenus (ADR-0021 grammar). No dismiss/archive/delete —
                // task lifecycle is kernel-owned, runs are immutable, so the
                // descriptors declare those capabilities absent and the
                // builders omit the items.
                TriageMenu.items(
                    triage: scope.descriptor.triage,
                    row: triageRow,
                    rowTagPaths: Set(tagPaths),
                    targets: targetIDs(for: row.id),
                    actions: actions)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                TriageSwipe.trailing(
                    triage: scope.descriptor.triage,
                    row: triageRow,
                    targets: targetIDs(for: row.id),
                    actions: actions)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                TriageSwipe.leading(
                    triage: scope.descriptor.triage,
                    row: triageRow,
                    targets: targetIDs(for: row.id),
                    actions: actions)
            }
        // No .itemProvider: agent rows don't drag — tasks/runs have no
        // folder tree (capability-matrix ➖ with note).
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: scope.isRunScope ? "bolt" : "checklist")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(filterText.isEmpty ? "No \(scope.title.lowercased())" : "No matches")
                .foregroundStyle(.secondary)
            if filterText.isEmpty {
                Text(scope.isRunScope
                    ? "Agent runs appear here once impel records task provenance in the shared store."
                    : "Tasks appear here once impel schedules work in the shared store.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The IDs a row-level action applies to: the whole selection when the
    /// clicked row is part of it, else just the clicked row (Mail semantics).
    private func targetIDs(for id: UUID) -> Set<UUID> {
        selectedIDs.contains(id) && selectedIDs.count > 1 ? selectedIDs : [id]
    }

    // MARK: Keyboard (vim j/k + selection actions via TriageKeyGrammar)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let ordered = visibleIDs
        guard !ordered.isEmpty else { return .ignored }
        guard let command = TriageKeyGrammar.command(forCharacters: press.characters) else {
            return .ignored
        }
        let currentIndex = selectedID.flatMap { id in ordered.firstIndex(of: id) }
        let currentStarred: Bool? = selectedID.flatMap { id in
            scope.isRunScope
                ? runRows.first(where: { $0.id == id })?.isStarredState
                : taskRows.first(where: { $0.id == id })?.isStarredState
        }
        let targets: Set<UUID> = {
            guard let id = selectedID else { return [] }
            return selectedIDs.contains(id) && selectedIDs.count > 1 ? selectedIDs : [id]
        }()

        switch command {
        case .navigateDown:
            let next = currentIndex.map { min($0 + 1, ordered.count - 1) } ?? 0
            selectedID = ordered[next]
            return .handled
        case .navigateUp:
            let prev = currentIndex.map { max($0 - 1, 0) } ?? 0
            selectedID = ordered[prev]
            return .handled
        case .create:
            // Tasks are scheduled by impel-taskd/counsel (descriptor.creation
            // is []) — `n` falls through.
            return .ignored
        case .toggleStar:
            guard let starred = currentStarred else { return .ignored }
            actions.onToggleStar(targets, !starred)
            return .handled
        case .dismissOrRestore:
            // No dismissal semantics for tasks/runs (kernel-owned lifecycle;
            // capability absent → `d` returns .ignored by contract).
            return .ignored
        case .open:
            guard let id = selectedID else { return .ignored }
            actions.onOpen(id)
            return .handled
        case .focusFilter:
            filterFocused = true
            return .handled
        case .focusPaneLeft, .focusPaneRight:
            // Pane focus is window-scoped, not list-scoped: bubble h/l up to the
            // shell that owns the split (ContentView / ImpressSplitView).
            return .ignored
        }
    }

    // MARK: Data

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let reader = AgentStoreReader.shared
        switch scope {
        case .tasks:
            taskRows = reader.fetchTasks().compactMap { TaskRowData(from: $0) }
            runRows = []
        case .tasksByState(let state):
            taskRows = reader.fetchTasks(state: state).compactMap { TaskRowData(from: $0) }
            runRows = []
        case .runs:
            runRows = reader.fetchRuns().compactMap { AgentRunRowData(from: $0) }
            taskRows = []
        }
        // Keep the current selection valid; otherwise select the first row so
        // the detail pane always has something to show.
        let ids = visibleIDs
        if let sel = selectedID, !ids.contains(sel) {
            selectedID = ids.first
        } else if selectedID == nil {
            selectedID = ids.first
        }
        logger.debug("Agents reloaded scope=\(String(describing: scope)) tasks=\(taskRows.count) runs=\(runRows.count)")
    }
}
#endif
