//
//  IOSManuscriptLibraryView.swift
//  imprint-iOS
//
//  imprint's iOS shell: sidebar → list → editor.
//
//  It used to be a flat `List` of the first 100 manuscripts with an
//  `.onDelete` hard delete and nothing else — no collections, no search, no
//  context menu, and a swipe that DELETED where every other impress surface
//  dismisses. Each of those is a place where iOS had re-encoded (or simply
//  not encoded) a rule that already exists as data.
//
//  So none of them are fixed here. What is here is a wiring harness:
//
//    * the sidebar is `PublicationManagerCore.RecordSidebarView`, driven by
//      `AppShellConfiguration.imprint` (sections + kind bindings) and
//      `ManuscriptRecordKind.descriptor` (statuses, folder capability);
//    * the swipe and long-press grammar is `.recordTriageRow(...)`, i.e.
//      `TriageSwipe` / `TriageMenu` built from the SAME
//      `TriageCapabilities` macOS uses — which is what makes left-swipe
//      dismiss, and makes it restore-and-delete inside Dismissed, without a
//      single hand-written swipe action;
//    * scope selection is `ManuscriptStoreScope`, so the dismissed-exclusion
//      rule stays where the adapter already enforces it;
//    * every mutation carries `SceneUndoManager.shared.manager`, so the Undo
//      button and shake-to-undo reach library operations.
//
//  The app-specific half — where the data comes from — is
//  `IOSManuscriptSidebarBindings.swift`.
//

import SwiftUI
import OSLog
import ImpressLogging
import ImprintCore
import PublicationManagerCore

struct IOSManuscriptLibraryView: View {

    @Bindable private var adapter = ManuscriptStoreAdapter.shared

    // MARK: - Navigation state

    /// The sidebar's selection, in chassis vocabulary.
    @State private var scope: RecordSidebarScope?
    /// The manuscript open in the detail column.
    @State private var selectedManuscriptID: UUID?
    /// `.all` so iPad opens on sidebar + list + editor; iPhone collapses this
    /// to a stack automatically.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - List state

    @State private var manuscripts: [ManuscriptModel] = []
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var counts = ManuscriptSidebarCounts()

    // MARK: - Sheets / confirmations

    @State private var showNewSheet = false
    @State private var newTitle = ""
    @State private var newFormat: ManuscriptFormat = .typst
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showDeleteConfirmation = false

    // MARK: - Declarative inputs

    private var descriptor: RecordKindDescriptor { ImprintSidebarBindings.descriptor }
    private var undoManager: UndoManager { SceneUndoManager.shared.manager }

    private var folders: [RecordFolder] {
        adapter.listCollections().map {
            RecordFolder(id: $0.id, name: $0.name, parentID: $0.parentID, sortOrder: $0.sortOrder)
        }
    }

    private var triageActions: RecordTriageActions {
        var actions = ImprintSidebarBindings.triageActions(
            adapter: adapter, undoManager: undoManager)
        // Host-owned by contract: confirmation first (deletion is
        // `.confirmHard` for this kind), then the hard delete.
        actions.onDelete = { ids in
            pendingDeleteIDs = ids
            showDeleteConfirmation = true
        }
        actions.onOpen = { id in selectedManuscriptID = id }
        return actions
    }

    private var collectionActions: RecordCollectionActions {
        ImprintSidebarBindings.collectionActions(adapter: adapter, undoManager: undoManager)
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RecordSidebarView(
                configuration: ImprintSidebarBindings.configuration,
                dataSource: ImprintSidebarBindings.dataSource(adapter: adapter, counts: counts),
                collectionActions: collectionActions,
                dataVersion: adapter.dataVersion,
                selection: $scope,
                title: "imprint")
        } content: {
            listColumn
        } detail: {
            detailColumn
        }
        .task {
            refresh()
            // Keep the stored-section outline snapshot fresh for multi-section
            // documents. Cheap — a single subscription to the store event bus.
            await OutlineSnapshotMaintainer.shared.start()
        }
        .onChange(of: adapter.dataVersion) { _, _ in refresh() }
        .onChange(of: scope) { _, _ in refresh() }
        .onChange(of: searchText) { _, _ in refresh() }
        .onOpenURL { url in handleIncomingURL(url) }
    }

    // MARK: - List column

    private var listColumn: some View {
        Group {
            if manuscripts.isEmpty {
                emptyState
            } else {
                manuscriptList
            }
        }
        .navigationTitle(scopeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            isPresented: $searchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search \(descriptor.displayName.lowercased())s")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                newManuscriptMenu
            }
            // ⌘F for hardware keyboards — the iOS half of macOS's
            // ImpressFindCommands / ⌘F filter.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    searchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityIdentifier("toolbar.find")
            }
        }
        .sheet(isPresented: $showNewSheet) { newManuscriptSheet }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performPendingDelete() }
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text("This cannot be undone from the Dismissed list.")
        }
    }

    private var manuscriptList: some View {
        List(selection: $selectedManuscriptID) {
            ForEach(manuscripts) { m in
                manuscriptRow(m)
                    .tag(m.id)
                    .recordTriageRow(
                        triage: descriptor.triage,
                        row: rowState(m),
                        targets: [m.id],
                        actions: triageActions,
                        rowTagPaths: Set(m.tags),
                        extraMenuItems: {
                            Button {
                                selectedManuscriptID = m.id
                            } label: {
                                Label("Open", systemImage: "square.and.pencil")
                            }
                            RecordFolderMenu.moveTo(
                                folders: folders,
                                targets: [m.id],
                                actions: collectionActions,
                                currentFolderID: scope?.folderID)
                            Divider()
                        })
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func manuscriptRow(_ m: ManuscriptModel) -> some View {
        HStack(spacing: 8) {
            if let flag = m.flagColor {
                Circle()
                    .fill(flagColor(flag))
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if m.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(m.title.isEmpty ? "Untitled" : m.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    statusBadge(m.status)
                    if !m.authors.isEmpty {
                        Text(m.authors.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(m.format.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("manuscriptRow.\(m.id.uuidString)")
    }

    private func statusBadge(_ status: String) -> some View {
        // Label text comes from the chassis's shared status presentation, so
        // the badge and the sidebar node never disagree about a status name.
        Text(RecordStatusPresentation.label(for: status))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }

    private func flagColor(_ raw: String) -> Color {
        switch raw {
        case "red": return .red
        case "amber": return .orange
        case "blue": return .blue
        default: return .gray
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                searchText.isEmpty ? "No Manuscripts" : "No Results",
                systemImage: searchText.isEmpty ? "doc.text" : "magnifyingglass")
        } description: {
            Text(searchText.isEmpty
                 ? "Create a manuscript to start writing."
                 : "No manuscripts match “\(searchText)”.")
        } actions: {
            if searchText.isEmpty {
                Button {
                    newTitle = ""
                    showNewSheet = true
                } label: {
                    Label("New Manuscript", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectedManuscriptID {
            IOSManuscriptEditorHost(manuscriptID: id)
                .id(id)
        } else {
            ContentUnavailableView(
                "No Manuscript Selected",
                systemImage: "doc.text",
                description: Text("Choose a manuscript from the list."))
        }
    }

    // MARK: - New manuscript
    //
    // The creation affordances are the DESCRIPTOR's (`creation`), which is
    // `DocumentFormat.allCases` — so a new document format shows up here
    // automatically instead of needing a third hardcoded picker.

    private var creationAffordances: [CreationAffordance] {
        descriptor.creation.filter { affordance in
            affordance.formatValue.flatMap(ManuscriptFormat.init(rawValue:)) != nil
        }
    }

    private var newManuscriptMenu: some View {
        Menu {
            ForEach(creationAffordances) { affordance in
                Button(affordance.label) {
                    newFormat = affordance.formatValue
                        .flatMap(ManuscriptFormat.init(rawValue:)) ?? .typst
                    newTitle = ""
                    showNewSheet = true
                }
            }
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .accessibilityIdentifier("toolbar.newManuscript")
    }

    private var newManuscriptSheet: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Untitled", text: $newTitle)
                        .accessibilityIdentifier("newManuscript.title")
                }
                Section("Format") {
                    Picker("Format", selection: $newFormat) {
                        ForEach(creationAffordances) { affordance in
                            if let format = affordance.formatValue
                                .flatMap(ManuscriptFormat.init(rawValue:)) {
                                Text(affordance.label).tag(format)
                            }
                        }
                    }
                }
                if case .folder(_, let folderID) = scope,
                   let folder = folders.first(where: { $0.id == folderID }) {
                    Section {
                        Label("Filed into “\(folder.name)”", systemImage: "folder")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New \(descriptor.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createManuscript() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createManuscript() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = title.isEmpty ? "Untitled" : title
        let format = newFormat
        let targetFolder = scope?.folderID
        showNewSheet = false
        do {
            let id = try adapter.createManuscript(
                title: finalTitle,
                format: format,
                body: format == .latex ? Self.latexStarter : Self.typstStarter
            )
            // Creating inside a folder scope files it there, undoably —
            // otherwise the new manuscript would vanish from the list the
            // user is looking at.
            if let targetFolder {
                _ = adapter.addToCollection(
                    manuscriptIDs: [id], collectionID: targetFolder,
                    undoManager: undoManager)
            }
            refresh()
            selectedManuscriptID = id
            Logger.sharedStore.infoCapture(
                "IOSManuscriptLibraryView: created manuscript \(id)",
                category: "manuscript-library"
            )
        } catch {
            Logger.sharedStore.error(
                "IOSManuscriptLibraryView: create failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Delete (host-owned: confirm, then hard delete)

    private var deleteConfirmationTitle: String {
        pendingDeleteIDs.count > 1
            ? "Delete \(pendingDeleteIDs.count) \(descriptor.displayName)s?"
            : "Delete \(descriptor.displayName)?"
    }

    private func performPendingDelete() {
        let targets = pendingDeleteIDs
        pendingDeleteIDs = []
        guard ManuscriptStoreAdapter.deletionIsHard else {
            // A kind whose deletion is `.softToDismissed` must not hard-delete
            // here; the descriptor decides, not this view.
            _ = adapter.dismiss(ids: Array(targets), undoManager: undoManager)
            refresh()
            return
        }
        for id in targets {
            if selectedManuscriptID == id { selectedManuscriptID = nil }
            try? adapter.deleteManuscript(id: id)
        }
        refresh()
    }

    // MARK: - Data

    private func rowState(_ m: ManuscriptModel) -> TriageRowState {
        TriageRowState(
            isStarred: m.isStarred,
            isDismissed: m.status == ManuscriptStoreAdapter.dismissedStatus,
            isArchived: m.status == ManuscriptStoreAdapter.archivedStatus)
    }

    private var scopeTitle: String {
        switch scope {
        case .status(_, let status): return RecordStatusPresentation.label(for: status)
        case .flagged(_, let color):
            return color.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Flagged"
        case .folder(_, let id):
            return folders.first(where: { $0.id == id })?.name ?? "Folder"
        case .all, .section, nil:
            return "All \(descriptor.displayName)s"
        }
    }

    private func refresh() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storeScope = ImprintSidebarBindings.storeScope(for: scope) ?? .all
        if query.isEmpty {
            manuscripts = adapter.listManuscripts(scope: storeScope, limit: 0)
        } else {
            // Search is a listing surface: the adapter applies the same
            // dismissed-exclusion rule, except inside the Dismissed scope.
            let dismissed = ManuscriptStoreAdapter.dismissedStatus
            let inDismissedScope = storeScope.explicitStatusIsDismissed
            var hits = adapter.searchManuscripts(
                query: query, limit: 0, includeDismissed: inDismissedScope)
            if inDismissedScope {
                hits = hits.filter { $0.status == dismissed }
            } else if case .status(let status) = storeScope {
                hits = hits.filter { $0.status == status }
            } else if case .folder(let folderID) = storeScope {
                let members = Set(
                    adapter.listManuscripts(scope: .folder(folderID), limit: 0).map(\.id))
                hits = hits.filter { members.contains($0.id) }
            } else if case .flagged(let color) = storeScope {
                hits = hits.filter { m in
                    guard let flag = m.flagColor else { return false }
                    return color == nil || flag == color
                }
            }
            manuscripts = hits
        }
    }

    // MARK: - URL handling

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "imprint", url.host == "open" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return }
        if let uuidString = items.first(where: { $0.name == "documentUUID" })?.value,
           let id = UUID(uuidString: uuidString) {
            selectedManuscriptID = id
        }
    }

    // MARK: - Starters

    private static let typstStarter = """
    // A new manuscript

    = Introduction

    Start writing here, or tap the quote button to insert a citation from imbib.
    """

    private static let latexStarter = """
    \\documentclass{article}
    \\usepackage[utf8]{inputenc}
    \\usepackage{amsmath, amssymb}

    \\title{Untitled}
    \\author{}
    \\date{\\today}

    \\begin{document}
    \\maketitle

    \\section{Introduction}

    Start writing here.

    \\end{document}
    """
}

// MARK: - Scope helper

private extension ManuscriptStoreScope {
    /// Whether this scope NAMES the reserved dismissed status — the one case
    /// in which a listing surface may show dismissed rows.
    var explicitStatusIsDismissed: Bool {
        guard case .status(let status) = self else { return false }
        return status == ManuscriptStoreAdapter.dismissedStatus
    }
}
