#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptListWrapper.swift
//  PublicationManagerCore
//
//  The manuscripts list pane of the unified chassis (GUI-meld plan §5). A
//  deliberately small (~vs 2231-line UnifiedPublicationListWrapper) list that
//  reuses ONLY the shared row chrome (ImpressMailStyle), selection binding,
//  and the vim j/k grammar — with its own manuscript-shaped row model
//  (ManuscriptRowData) and actions bag. Manuscripts never enter
//  PublicationSource, so the publication wrapper's enrichment/dismissed/
//  citeKey assumptions can't leak in.

import SwiftUI
import AppKit
import ImpressFTUI
import ImpressKeyboard
import ImpressMailStyle
import ImpressStoreKit
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.imbib.app", category: "manuscripts")

/// What subset of manuscripts the list shows.
public enum ManuscriptListScope: Hashable, Sendable {
    case all
    case status(JournalManuscriptStatus)
    case folder(UUID)
    case flagged(FlagColor?)

    var statusString: String? {
        if case .status(let s) = self { return s.rawValue }
        return nil
    }
    var folderID: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }
    var title: String {
        switch self {
        case .all: return "All Manuscripts"
        case .status(let s): return s.displayName
        case .folder: return "Folder"
        case .flagged(let color):
            return color.map { "\($0.displayName) Flag" } ?? "Flagged"
        }
    }
}

// Actions: the shared RecordTriageActions (ADR-0021). Manuscript-specific
// verbs (create-with-format, duplicate, open, remove-from-folder) ride the
// same bag via onCreate/onDuplicate/onOpen/onRemoveFromScope.

public struct ManuscriptListWrapper: View {

    let scope: ManuscriptListScope
    @Binding var selectedID: UUID?
    var actions: RecordTriageActions

    @State private var rows: [ManuscriptRowData] = []
    @State private var filterText: String = ""
    @State private var isLoading = false
    @State private var dataVersion = 0
    /// Full multi-selection; `selectedID` (the binding the detail pane
    /// follows) tracks its primary member.
    @State private var selectedIDs = Set<UUID>()

    @FocusState private var listFocused: Bool
    @FocusState private var filterFocused: Bool
    @Environment(\.appShellConfiguration) private var shellConfiguration

    public init(
        scope: ManuscriptListScope,
        selectedID: Binding<UUID?>,
        actions: RecordTriageActions = RecordTriageActions()
    ) {
        self.scope = scope
        self._selectedID = selectedID
        self.actions = actions
    }

    private var visibleRows: [ManuscriptRowData] {
        guard !filterText.isEmpty else { return rows }
        let q = filterText.lowercased()
        return rows.filter {
            $0.title.lowercased().contains(q) || $0.authorString.lowercased().contains(q)
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
        .task(id: scopeKey) { await reload() }
        .task {
            // Row-level refresh. Deletes/creates emit `.structural`; in-place
            // edits emit `.itemsMutated` — reload for the ones touching our
            // rows (or any structural change, which can add/remove rows).
            for await event in ImbibImpressStore.shared.events.subscribe() {
                switch event {
                case .structural:
                    await reload()
                case .itemsMutated(_, let ids):
                    let visible = Set(rows.map(\.id))
                    if ids.isEmpty || !visible.isDisjoint(with: ids) || rows.isEmpty {
                        await reload()
                    }
                case .collectionMembershipChanged(let collectionID):
                    if scope.folderID == collectionID { await reload() }
                }
            }
        }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter manuscripts", text: $filterText)
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
                            // Swipe LEFT = archive (non-destructive) then
                            // delete; swipe RIGHT = star. Mirrors the
                            // publication row's gesture grammar.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                TriageSwipe.trailing(
                                    triage: ManuscriptRecordKind.descriptor.triage,
                                    row: triageState(row),
                                    targets: targetIDs(for: row),
                                    actions: actions)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                TriageSwipe.leading(
                                    triage: ManuscriptRecordKind.descriptor.triage,
                                    row: triageState(row),
                                    targets: targetIDs(for: row),
                                    actions: actions)
                            }
                            // Drag manuscript(s) onto a sidebar folder. JSON
                            // [uuid-string] payload, mirroring publication rows;
                            // dragging a selected row carries the whole selection.
                            .itemProvider {
                                let dragged = Array(targetIDs(for: row))
                                // Record for the sidebar's synchronous drop
                                // read (see RecordDragSession).
                                RecordDragSession.manuscript.begin(ids: dragged)
                                let ids = dragged.map(\.uuidString)
                                logger.info("drag started: \(ids.count) manuscript(s)")
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(
                                    forTypeIdentifier: UTType.manuscriptID.identifier,
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
                // `selectedID` the detail pane follows. Both handlers are
                // guarded so the pair reaches a fixed point without looping.
                .onChange(of: selectedIDs) { _, newIDs in
                    if let current = selectedID, newIDs.contains(current) { return }
                    selectedID = newIDs.first
                }
                .onChange(of: selectedID) { _, newID in
                    if let newID {
                        if !selectedIDs.contains(newID) { selectedIDs = [newID] }
                        // No animation: an animated scroll per row makes
                        // holding ↓ feel like wading rather than flying.
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
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(filterText.isEmpty ? "No manuscripts" : "No matches")
                .foregroundStyle(.secondary)
            if filterText.isEmpty {
                Menu("New Manuscript") {
                    ForEach(ManuscriptRecordKind.descriptor.creation) { affordance in
                        Button(affordance.label) { actions.onCreate(affordance) }
                    }
                }
                .fixedSize()
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowMenu(_ row: ManuscriptRowData) -> some View {
        let targets = targetIDs(for: row)
        Button(shellConfiguration.openBehavior(for: .manuscript) != .appHandoff
            ? "Open in New Window" : "Open in imprint") {
            actions.onOpen(row.id)
        }
        Button("Duplicate") { actions.onDuplicate(row.id) }
        Divider()
        // The shared triage segment: star/dismiss-or-restore/archive, Flag
        // and Tags submenus, Delete… last (ADR-0021 grammar).
        TriageMenu.items(
            triage: ManuscriptRecordKind.descriptor.triage,
            row: triageState(row),
            rowTagPaths: Set(row.tagDisplays.map(\.path)),
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

    private func triageState(_ row: ManuscriptRowData) -> TriageRowState {
        TriageRowState(
            isStarred: row.isStarredState,
            isDismissed: row.status == .dismissed,
            isArchived: row.status == .archived)
    }

    /// The IDs a row-level action applies to: the whole selection when the
    /// clicked row is part of it, else just the clicked row (Mail semantics).
    private func targetIDs(for row: ManuscriptRowData) -> Set<UUID> {
        selectedIDs.contains(row.id) && selectedIDs.count > 1 ? selectedIDs : [row.id]
    }

    // MARK: Keyboard (vim j/k + selection actions)

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
            guard let affordance = ManuscriptRecordKind.descriptor.creation.first else {
                return .ignored
            }
            actions.onCreate(affordance)
            return .handled
        case .toggleStar:
            guard let row = currentRow else { return .ignored }
            actions.onToggleStar(targets, !row.isStarredState)
            return .handled
        case .dismissOrRestore:
            guard let row = currentRow else { return .ignored }
            if row.status == .dismissed {
                actions.onRestore(targets)
            } else {
                actions.onDismiss(targets)
            }
            return .handled
        case .open:
            guard let id = selectedID else { return .ignored }
            actions.onOpen(id)
            return .handled
        case .focusFilter:
            filterFocused = true
            return .handled
        }
    }

    // MARK: Data

    private var scopeKey: String {
        switch scope {
        case .all: return "all"
        case .status(let s): return "status-\(s.rawValue)"
        case .folder(let id): return "folder-\(id.uuidString)"
        case .flagged(let color): return "flagged-\(color?.rawValue ?? "any")"
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fetched: [ManuscriptRow]
        if case .flagged(let color) = scope {
            fetched = RustStoreAdapter.shared.getFlaggedManuscripts(color: color)
        } else {
            fetched = RustStoreAdapter.shared.queryManuscripts(
                collectionID: scope.folderID,
                status: scope.statusString,
                sort: "modified",
                ascending: false
            )
        }
        var mapped = fetched.compactMap { ManuscriptRowData(from: $0) }
        // Dismissed manuscripts live only under Dismissed — they must not
        // clutter All Manuscripts, folders, or flag views (imbib's convention).
        if scope.statusString != JournalManuscriptStatus.dismissed.rawValue {
            mapped = mapped.filter { $0.status != .dismissed }
        }
        rows = mapped
        // Keep the current selection valid; otherwise select the first row so
        // the detail pane always has something to show.
        if let sel = selectedID, !mapped.contains(where: { $0.id == sel }) {
            selectedID = mapped.first?.id
        } else if selectedID == nil {
            selectedID = mapped.first?.id
        }
        logger.debug("Manuscripts reloaded scope=\(scopeKey) count=\(mapped.count)")
    }
}
#endif
