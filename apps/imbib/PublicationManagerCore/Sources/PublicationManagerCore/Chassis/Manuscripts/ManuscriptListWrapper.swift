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
import ImpressFTUI
import ImpressKeyboard
import ImpressMailStyle
import ImpressStoreKit
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "manuscripts")

/// What subset of manuscripts the list shows.
public enum ManuscriptListScope: Hashable, Sendable {
    case all
    case status(JournalManuscriptStatus)
    case folder(UUID)

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
        }
    }
}

/// Actions the list surfaces to the toolbar / context menu / keyboard.
/// Mirrors the shape of `PublicationListActions` but only what manuscripts
/// support (no enrichment, no dismissed-library triage).
public struct ManuscriptListActions {
    public var onNewManuscript: () -> Void = {}
    public var onDelete: (Set<UUID>) -> Void = { _ in }
    public var onDuplicate: (UUID) -> Void = { _ in }
    public var onSetFlag: (Set<UUID>, FlagColor?) -> Void = { _, _ in }
    public var onOpenInImprint: (UUID) -> Void = { _ in }
    public init() {}
}

public struct ManuscriptListWrapper: View {

    let scope: ManuscriptListScope
    @Binding var selectedID: UUID?
    var actions: ManuscriptListActions

    @State private var rows: [ManuscriptRowData] = []
    @State private var filterText: String = ""
    @State private var isLoading = false
    @State private var dataVersion = 0

    @FocusState private var listFocused: Bool

    public init(
        scope: ManuscriptListScope,
        selectedID: Binding<UUID?>,
        actions: ManuscriptListActions = ManuscriptListActions()
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
            listBody
        }
        .focusable()
        .focused($listFocused)
        .keyboardGuarded { press in handleKey(press) }
        .task(id: scopeKey) { await reload() }
        .task {
            // Row-level refresh: reload when manuscript items mutate.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if case .itemsMutated = event { await reload() }
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
                List(selection: $selectedID) {
                    ForEach(visibleRows) { row in
                        MailStyleRow(item: row)
                            .tag(row.id)
                            .id(row.id)
                            .contextMenu { rowMenu(row) }
                    }
                }
                .listStyle(.inset)
                .onChange(of: selectedID) { _, newID in
                    if let newID { withAnimation { proxy.scrollTo(newID) } }
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
                Button("New Manuscript", action: actions.onNewManuscript)
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowMenu(_ row: ManuscriptRowData) -> some View {
        Button("Open in imprint") { actions.onOpenInImprint(row.id) }
        Button("Duplicate") { actions.onDuplicate(row.id) }
        Divider()
        Menu("Flag") {
            ForEach(FlagColor.allCases) { color in
                Button(color.displayName) { actions.onSetFlag([row.id], color) }
            }
            Button("Clear Flag") { actions.onSetFlag([row.id], nil) }
        }
        Divider()
        Button("Delete", role: .destructive) { actions.onDelete([row.id]) }
    }

    // MARK: Keyboard (vim j/k + selection actions)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let ordered = visibleRows
        guard !ordered.isEmpty else { return .ignored }
        let currentIndex = selectedID.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }

        switch press.characters {
        case "j":
            let next = currentIndex.map { min($0 + 1, ordered.count - 1) } ?? 0
            selectedID = ordered[next].id
            return .handled
        case "k":
            let prev = currentIndex.map { max($0 - 1, 0) } ?? 0
            selectedID = ordered[prev].id
            return .handled
        case "n":
            actions.onNewManuscript()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: Data

    private var scopeKey: String {
        switch scope {
        case .all: return "all"
        case .status(let s): return "status-\(s.rawValue)"
        case .folder(let id): return "folder-\(id.uuidString)"
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fetched = RustStoreAdapter.shared.queryManuscripts(
            collectionID: scope.folderID,
            status: scope.statusString,
            sort: "modified",
            ascending: false
        )
        let mapped = fetched.compactMap { ManuscriptRowData(from: $0) }
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
