#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  MessageListWrapper.swift
//  PublicationManagerCore
//
//  The mail list pane of the unified chassis (Stage 2-A, ADR-0021). A
//  deliberately small clone of FigureListWrapper: shared row chrome
//  (ImpressMailStyle), selection binding, the shared triage builders
//  (TriageSwipe/TriageMenu/TriageKeyGrammar), and in-list THREAD grouping —
//  rows collapse to the newest message per payload thread_id with a "(n)"
//  badge; the thread itself renders in the detail pane.
//
//  Deliberate v1 gaps (IMAP-owned, documented in the capability matrix):
//  - no drag (moving mail = IMAP move through impart, not store setParent)
//  - no dismissal/deletion (descriptor declares .none/.none; `d` is ignored)
//

import SwiftUI
import AppKit
import ImpressFTUI
import ImpressKeyboard
import ImpressMailStyle
import ImpressRustCore
import ImpressStoreKit
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "mail")

// `MessageListScope` moved to Chassis/RecordKind/RecordScopeKey+ListScopes.swift
// (Stage 2a): the scope is a Foundation value type and is now
// cross-platform; only this wrapper is AppKit-adjacent.

// Actions: the shared RecordTriageActions (ADR-0021). Mail has no
// kind-specific verbs in v1 — open is the detail pane, and IMAP-owned verbs
// (move/delete/compose) stay in impart's classic window.

public struct MessageListWrapper: View {

    let scope: MessageListScope
    @Binding var selectedID: UUID?
    var actions: RecordTriageActions

    @State private var rows: [MessageRowData] = []
    @State private var filterText: String = ""
    @State private var isLoading = false
    /// Full multi-selection; `selectedID` (the binding the detail pane
    /// follows) tracks its primary member.
    @State private var selectedIDs = Set<UUID>()

    @FocusState private var listFocused: Bool
    @FocusState private var filterFocused: Bool

    public init(
        scope: MessageListScope,
        selectedID: Binding<UUID?>,
        actions: RecordTriageActions = RecordTriageActions()
    ) {
        self.scope = scope
        self._selectedID = selectedID
        self.actions = actions
    }

    private var visibleRows: [MessageRowData] {
        guard !filterText.isEmpty else { return rows }
        let q = filterText.lowercased()
        return rows.filter {
            $0.subject.lowercased().contains(q)
                || $0.from.lowercased().contains(q)
                || $0.preview.lowercased().contains(q)
        }
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
            // RustStoreAdapter ops emit StoreEvents in-process. IMAP-driven
            // writes land through impart's OWN store handle
            // (MessageManagerCore) and don't surface here — the list catches
            // up on the next reload (scope change / relaunch), a documented
            // Stage-2-A v1 limit.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                switch event {
                case .structural:
                    await reload()
                case .itemsMutated(_, let ids):
                    let visible = Set(rows.map(\.id))
                    if ids.isEmpty || !visible.isDisjoint(with: ids) || rows.isEmpty {
                        await reload()
                    }
                case .collectionMembershipChanged:
                    // Mail folders are envelope-parent, not Contains edges.
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
            TextField("Filter messages", text: $filterText)
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
        if isLoading && rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleRows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List(selection: $selectedIDs) {
                    ForEach(visibleRows) { row in
                        MailStyleRow(item: row)
                            .tag(row.id)
                            .id(row.id)
                            .contextMenu { rowMenu(row) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                TriageSwipe.trailing(
                                    triage: MessageRecordKind.descriptor.triage,
                                    row: triageState(row),
                                    targets: targetIDs(for: row),
                                    actions: actions)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                TriageSwipe.leading(
                                    triage: MessageRecordKind.descriptor.triage,
                                    row: triageState(row),
                                    targets: targetIDs(for: row),
                                    actions: actions)
                            }
                        // No .itemProvider: mail rows don't drag in v1 —
                        // moving mail is an IMAP move (impart), not a store
                        // setParent (capability-matrix ❌ with note).
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(filterText.isEmpty ? "No messages" : "No matches")
                .foregroundStyle(.secondary)
            if filterText.isEmpty {
                Text("Messages appear here once impart has mirrored mail into the shared store.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowMenu(_ row: MessageRowData) -> some View {
        // The shared triage segment only: star, Flag and Tags submenus
        // (ADR-0021 grammar). No dismiss/archive/delete — mail lifecycle is
        // IMAP-owned in v1, so the descriptor declares those capabilities
        // absent and the builders omit the items.
        TriageMenu.items(
            triage: MessageRecordKind.descriptor.triage,
            row: triageState(row),
            rowTagPaths: Set(row.tagPaths),
            targets: targetIDs(for: row),
            actions: actions)
    }

    private func triageState(_ row: MessageRowData) -> TriageRowState {
        TriageRowState(
            isStarred: row.isStarredState,
            isDismissed: false,
            isArchived: false)
    }

    /// The IDs a row-level action applies to: the whole selection when the
    /// clicked row is part of it, else just the clicked row (Mail semantics).
    private func targetIDs(for row: MessageRowData) -> Set<UUID> {
        selectedIDs.contains(row.id) && selectedIDs.count > 1 ? selectedIDs : [row.id]
    }

    // MARK: Keyboard (vim j/k + selection actions via TriageKeyGrammar)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let ordered = visibleRows
        guard !ordered.isEmpty else { return .ignored }
        guard let command = TriageKeyGrammar.command(forCharacters: press.characters) else {
            return .ignored
        }
        let currentIndex = selectedID.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }
        let currentRow = selectedID.flatMap { id in ordered.first(where: { $0.id == id }) }
        let targets: Set<UUID> = {
            guard let id = selectedID else { return [] }
            return selectedIDs.contains(id) && selectedIDs.count > 1 ? selectedIDs : [id]
        }()

        switch command {
        case .navigateDown:
            let next = currentIndex.map { min($0 + 1, ordered.count - 1) } ?? 0
            selectedID = ordered[next].id
            return .handled
        case .navigateUp:
            let prev = currentIndex.map { max($0 - 1, 0) } ?? 0
            selectedID = ordered[prev].id
            return .handled
        case .create:
            // Compose stays in impart's classic window (descriptor.creation
            // is []) — `n` falls through.
            return .ignored
        case .toggleStar:
            guard let row = currentRow else { return .ignored }
            actions.onToggleStar(targets, !row.isStarredState)
            return .handled
        case .dismissOrRestore:
            // No dismissal semantics for mail in v1 (IMAP-owned lifecycle;
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
        let reader = MailStoreReader.shared
        let fetched: [SharedItemRow]
        switch scope {
        case .folder(let id):
            // Folder scope = envelope parentId filter, pushed to the store.
            fetched = reader.fetchMessages(inFolder: id.uuidString.lowercased())
        case .account(let id):
            // v1: an account node lists its inbox-role folder. Sent/Drafts/…
            // are one click away as child folder nodes.
            let folders = reader.fetchFolders(accountID: id.uuidString.lowercased())
            if let inbox = folders.first(where: {
                MailStoreReader.folderPayload(from: $0)?.role == "inbox"
            }) {
                fetched = reader.fetchMessages(inFolder: inbox.id)
            } else {
                fetched = []
            }
        case .allInboxes:
            // Fetch folders with role inbox, parentId-query each, merge+sort
            // — fine at Stage-2 scale (per-folder queries are indexed).
            let inboxes = reader.fetchInboxFolders()
            fetched = inboxes
                .flatMap { reader.fetchMessages(inFolder: $0.id) }
                .sorted { $0.createdMs > $1.createdMs }
        case .flagged(let color):
            fetched = reader.fetchAllMessages().filter { row in
                guard let flagColor = row.flagColor else { return false }
                if let color { return flagColor == color.rawValue }
                return true
            }
        }
        let mapped = fetched.compactMap { MessageRowData(from: $0) }
        // Thread grouping: collapse to the newest message per thread with a
        // "(n)" badge; the detail pane shows the full thread.
        let collapsed = MessageRowData.collapsedByThread(mapped)
        rows = collapsed
        // Keep the current selection valid; otherwise select the first row so
        // the detail pane always has something to show.
        if let sel = selectedID, !collapsed.contains(where: { $0.id == sel }) {
            selectedID = collapsed.first?.id
        } else if selectedID == nil {
            selectedID = collapsed.first?.id
        }
        logger.debug("Mail reloaded scope=\(String(describing: scope)) messages=\(mapped.count) threads=\(collapsed.count)")
    }
}
#endif
