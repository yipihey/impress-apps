#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  FigureListWrapper.swift
//  PublicationManagerCore
//
//  The figures list pane of the unified chassis (Stage 2-B, ADR-0021). A
//  deliberately small clone of ManuscriptListWrapper minus the editor-session
//  logic: shared row chrome (ImpressMailStyle), selection binding, the shared
//  triage builders (TriageSwipe/TriageMenu/TriageKeyGrammar — the
//  capability-matrix rule for new kinds), and folder drag via
//  UTType.figureID + RecordDragSession.figure.
//

import SwiftUI
import AppKit
import ImpressFTUI
import ImpressKeyboard
import ImpressMailStyle
import ImpressRustCore
import ImpressStoreKit
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.imbib.app", category: "figures")

// `FigureListScope` moved to Chassis/RecordKind/RecordScopeKey+ListScopes.swift
// (Stage 2a): the scope is a Foundation value type and is now
// cross-platform; only this wrapper is AppKit-adjacent.

// Actions: the shared RecordTriageActions (ADR-0021). Figure-specific verbs
// (open-in-canvas, remove-from-folder) ride the same bag via
// onOpen/onRemoveFromScope.

public struct FigureListWrapper: View {

    let scope: FigureListScope
    @Binding var selectedID: UUID?
    var actions: RecordTriageActions

    @State private var rows: [FigureRowData] = []
    @State private var filterText: String = ""
    @State private var isLoading = false
    /// Full multi-selection; `selectedID` (the binding the detail pane
    /// follows) tracks its primary member.
    @State private var selectedIDs = Set<UUID>()

    @FocusState private var listFocused: Bool
    @FocusState private var filterFocused: Bool

    public init(
        scope: FigureListScope,
        selectedID: Binding<UUID?>,
        actions: RecordTriageActions = RecordTriageActions()
    ) {
        self.scope = scope
        self._selectedID = selectedID
        self.actions = actions
    }

    private var visibleRows: [FigureRowData] {
        guard !filterText.isEmpty else { return rows }
        let q = filterText.lowercased()
        return rows.filter {
            $0.title.lowercased().contains(q)
                || ($0.caption?.lowercased().contains(q) ?? false)
                || $0.format.lowercased().contains(q)
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
            // Row-level refresh. Star/flag/tag/rename/delete via the generic
            // RustStoreAdapter ops emit StoreEvents; FigureStoreReader's own
            // envelope mutations post `.structural` explicitly.
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
                    // Figure folders are envelope-parent, not Contains edges —
                    // moves surface as `.structural` above.
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
            TextField("Filter figures", text: $filterText)
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
                                    triage: FigureRecordKind.descriptor.triage,
                                    row: triageState(row),
                                    targets: targetIDs(for: row),
                                    actions: actions)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                TriageSwipe.leading(
                                    triage: FigureRecordKind.descriptor.triage,
                                    row: triageState(row),
                                    targets: targetIDs(for: row),
                                    actions: actions)
                            }
                            // Drag figure(s) onto a sidebar folder. JSON
                            // [uuid-string] payload, mirroring manuscript rows;
                            // dragging a selected row carries the whole selection.
                            .itemProvider {
                                let dragged = Array(targetIDs(for: row))
                                // Record for the sidebar's synchronous drop
                                // read (see RecordDragSession).
                                RecordDragSession.figure.begin(ids: dragged)
                                let ids = dragged.map(\.uuidString)
                                logger.info("drag started: \(ids.count) figure(s)")
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(
                                    forTypeIdentifier: UTType.figureID.identifier,
                                    visibility: .all
                                ) { completion in
                                    let jsonData = try? JSONEncoder().encode(ids)
                                    completion(jsonData, nil)
                                    return nil
                                }
                                return provider
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(filterText.isEmpty ? "No figures" : "No matches")
                .foregroundStyle(.secondary)
            if filterText.isEmpty {
                Text("Figures are created from the Generate mode or the canvas.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowMenu(_ row: FigureRowData) -> some View {
        let targets = targetIDs(for: row)
        Button("Open in Canvas") { actions.onOpen(row.id) }
        Divider()
        // The shared triage segment: star, Flag and Tags submenus, Delete…
        // last (ADR-0021 grammar; figures have no dismiss/archive lifecycle).
        TriageMenu.items(
            triage: FigureRecordKind.descriptor.triage,
            row: triageState(row),
            rowTagPaths: Set(row.tagPaths),
            targets: targets,
            actions: actions)
        if scope.folderID != nil {
            Divider()
            Button(targets.count > 1
                ? "Remove \(targets.count) from Folder" : "Remove from Folder") {
                actions.onRemoveFromScope(targets)
            }
        }
    }

    private func triageState(_ row: FigureRowData) -> TriageRowState {
        TriageRowState(
            isStarred: row.isStarredState,
            isDismissed: false,
            isArchived: false)
    }

    /// The IDs a row-level action applies to: the whole selection when the
    /// clicked row is part of it, else just the clicked row (Mail semantics).
    private func targetIDs(for row: FigureRowData) -> Set<UUID> {
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
            // Figures have no creation affordance (descriptor.creation is []).
            return .ignored
        case .toggleStar:
            guard let row = currentRow else { return .ignored }
            actions.onToggleStar(targets, !row.isStarredState)
            return .handled
        case .dismissOrRestore:
            // No dismissal semantics for figures (capability absent → ignored).
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
        let reader = FigureStoreReader.shared
        let fetched: [SharedItemRow]
        switch scope {
        case .folder(let id):
            // Folder scope = envelope parentId filter, pushed to the store.
            fetched = reader.fetchFigures(inFolder: id.uuidString.lowercased())
        case .all:
            fetched = reader.fetchFigures()
        case .unfiled:
            // Fetch all + client-side filter — fine at implore scale.
            fetched = reader.fetchFigures().filter { $0.parentId == nil }
        case .flagged(let color):
            fetched = reader.fetchFigures().filter { row in
                guard let flagColor = row.flagColor else { return false }
                if let color { return flagColor == color.rawValue }
                return true
            }
        case .tag(let path):
            // Tags live on the item ENVELOPE, not the payload, so this is a
            // post-filter — the same shape the flag case above takes, and the
            // reason no store query gains an argument. Descendant-inclusive via
            // the one authority, so the sidebar's tag tree is selectable at
            // every level rather than only at its leaves.
            fetched = reader.fetchFigures().filter {
                TagPathMatch.anyMatches($0.tags, scopePath: path)
            }
        }
        let mapped = fetched.compactMap { FigureRowData(from: $0) }
        rows = mapped
        // Keep the current selection valid; otherwise select the first row so
        // the detail pane always has something to show.
        if let sel = selectedID, !mapped.contains(where: { $0.id == sel }) {
            selectedID = mapped.first?.id
        } else if selectedID == nil {
            selectedID = mapped.first?.id
        }
        logger.debug("Figures reloaded scope=\(String(describing: scope)) count=\(mapped.count)")
    }
}
#endif
