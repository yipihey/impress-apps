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
    /// The PAPER open in the detail column, when the selected section is
    /// publication-bound (`.citedInManuscripts` — I2). Kept separate from
    /// `selectedManuscriptID` on purpose: they are two different record kinds
    /// and one `UUID?` for both would let a stale manuscript id select a paper.
    @State private var selectedPublicationID: UUID?

    /// The citation currently being inspected — raised by a long press in the
    /// editor or by `imprint://inspect/citation/{key}`. nil → no sheet.
    @State private var citationInspection: CitationInspection?
    /// `.all` so iPad opens on sidebar + list + editor; iPhone collapses this
    /// to a stack automatically.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - List state

    @State private var manuscripts: [ManuscriptModel] = []
    @State private var searchText = ""
    /// `searchPresented` moved into `RecordListHost`: the field and the ⌘F button
    /// that focuses it are one affordance, so the host owns the flag and this
    /// view owns only the TEXT (because what a query MEANS here is a store
    /// search — see `refresh()`).
    @State private var counts = ManuscriptSidebarCounts()

    // MARK: - Sheets / confirmations

    @State private var showNewSheet = false
    @State private var newTitle = ""
    @State private var newFormat: ManuscriptFormat = .typst
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showDeleteConfirmation = false
    /// Stage 6 phase 1: imprint-iOS's FIRST settings surface. Presented from
    /// the sidebar's gear, rendered by the chassis from
    /// `AppSettingsConfiguration.imprint` — the same declaration the macOS
    /// Settings scene's thirteen tabs come from, filtered by availability.
    @State private var showSettings = false

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
            // The gear lives on the SIDEBAR column, not the list: settings are
            // app-wide, and the sidebar is the column iOS lands on when the
            // split view collapses on iPhone. Putting it on the list column
            // would make it unreachable from the root on a phone.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("toolbar.settings")
                }
            }
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
        // Citation inspection is presented HERE, at the navigation root, not in
        // the editor: a deep link cold-launches the app (`XCUIApplication.open`
        // and Springboard both do), so a presenter that lived inside the open
        // editor would only ever work for the gesture. One presenter serves the
        // long press and `imprint://inspect/citation/{key}` alike.
        .onReceive(NotificationCenter.default.publisher(for: .inspectCiteKey)) { note in
            guard let key = note.userInfo?["citeKey"] as? String else { return }
            let resolution = ManuscriptCitationResolver.resolve(key)
            Logger.sharedStore.infoCapture(
                "inspect cite key '\(key)' → \(resolution.status)",
                category: "citation"
            )
            citationInspection = CitationInspection(resolution: resolution)
        }
        .sheet(item: $citationInspection) { inspection in
            CitationPaperSheet(resolution: inspection.resolution)
                .presentationDetents([.medium, .large])
        }
        // Settings, like citation inspection, is presented at the navigation
        // ROOT rather than inside a column — a sheet raised from a column is
        // dismissed by that column's own navigation on iPhone.
        .sheet(isPresented: $showSettings) {
            IOSSettingsScreen(configuration: .imprint) {
                showSettings = false
            }
            .environment(\.settingsSectionRegistry, ImprintSettingsSections.registry)
        }
    }

    /// `.sheet(item:)` needs identity; a resolution has none of its own, and
    /// inspecting the SAME key twice must re-present the sheet.
    private struct CitationInspection: Identifiable {
        let id = UUID()
        let resolution: CitationResolution
    }

    // MARK: - List column

    @ViewBuilder
    private var listColumn: some View {
        if let publicationSource {
            // I2: THE chassis's read-only publication list, the same view
            // impress-iOS shows. imprint writes the `citation-usage@1.0.0`
            // rows this scope resolves from; it does not own a paper list, and
            // this is deliberately not one — no triage sheet, no BibTeX editor,
            // no library management.
            IOSPublicationListPane(
                source: publicationSource,
                title: SidebarSectionType.citedInManuscripts.displayName,
                selectedID: $selectedPublicationID,
                listIdentifier: "publicationList",
                dataVersion: adapter.dataVersion)
                .id(publicationSource)
        } else {
            manuscriptListColumn
        }
    }

    private var manuscriptListColumn: some View {
        // THE shared iOS list host (C1): the `List`, the search field, the ⌘F
        // button, pull-to-refresh, the `.recordTriageRow` wiring and the
        // three-state branch are `RecordListHost`'s. What imprint parameterizes
        // is its ROW, its row MENU (Open + the organise grammar), its empty-state
        // COPY and the New Manuscript button under it.
        //
        // Reload triggers stay at this view's root rather than being handed to
        // the host: `refresh()` feeds the sidebar counts as well as the list, so
        // one `.onChange(of: adapter.dataVersion)` serves both columns. The host
        // gets `onReload` alone, which is what pull-to-refresh calls.
        RecordListHost(
            rows: manuscripts,
            selection: $selectedManuscriptID,
            searchText: $searchText,
            title: scopeTitle,
            searchPrompt: "Search \(descriptor.displayName.lowercased())s",
            emptyState: emptyState,
            rowIdentifierPrefix: "manuscriptRow.",
            triage: descriptor.triage,
            actions: triageActions,
            rowState: rowState,
            rowTagPaths: { Set($0.tags) },
            onReload: { refresh() },
            rowContent: manuscriptRow,
            rowMenu: { m in
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
            },
            emptyActions: {
                if searchText.isEmpty {
                    Button {
                        newTitle = ""
                        showNewSheet = true
                    } label: {
                        Label("New Manuscript", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            })
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                newManuscriptMenu
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
        // No `accessibilityIdentifier` here: the row identifier is the shared
        // host's (`RecordListRowIdentity`), which is what keeps
        // `manuscriptRow.<uuid>` and `messageRow.<uuid>` spelled one way. Both
        // UI suites match it by PREFIX, so a rename in one view file used to be
        // a silently empty query.
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

    /// The row dot's colour, from the ONE cross-platform `FlagColor` mapping
    /// (ImpressFTUI) that the sidebar's flag rows and macOS's flag rows also
    /// use — a local switch here would render a red dot beside a differently
    /// red sidebar row.
    private func flagColor(_ raw: String) -> Color {
        (FlagColor(storedValue: raw) ?? .gray).displayColor
    }

    /// The list's empty state as a `ChassisEmptyState` value — the chassis's
    /// vocabulary, imprint's words. Which of the two states applies depends on
    /// the query, so the host is handed the RESOLVED one (Stage 5d's rule: list
    /// copy is per-app product copy, not a shared string).
    private var emptyState: ChassisEmptyState {
        if searchText.isEmpty {
            return ChassisEmptyState(
                id: "manuscripts-empty",
                title: "No \(descriptor.pluralDisplayName)",
                systemImage: descriptor.symbolName,
                message: "Create a manuscript to start writing.")
        }
        return ChassisEmptyState(
            id: "manuscripts-no-matches",
            title: "No Results",
            systemImage: "magnifyingglass",
            message: "No manuscripts match \u{201C}\(searchText)\u{201D}.")
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if publicationSource != nil {
            if let id = selectedPublicationID {
                // The LIFTED pane (I2), with no `LibraryViewModel` and no
                // `LibraryManager` in the environment: Copy BibTeX takes the
                // store route and the Explore row does not render, because
                // exploration would write into imbib's exploration library.
                IOSPublicationDetailPane(publicationID: id)
                    .accessibilityIdentifier("publicationDetail")
                    .id(id)
            } else {
                ContentUnavailableView(
                    "No Paper Selected",
                    systemImage: "doc.text",
                    description: Text("Choose a paper from the list."))
            }
        } else if let id = selectedManuscriptID {
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

    /// Non-nil when the sidebar's selection is a publication-bound section.
    /// The whole publication branch of this shell hangs off this one value.
    private var publicationSource: PublicationSource? {
        ImprintSidebarBindings.publicationSource(for: scope)
    }

    private var scopeTitle: String {
        switch scope {
        case .status(_, let status): return RecordStatusPresentation.label(for: status)
        case .flagged(_, let color):
            return color.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Flagged"
        case .folder(_, let id):
            return folders.first(where: { $0.id == id })?.name ?? "Folder"
        // The LEAF, matching the sidebar row the user came from — the full
        // path is the row's identity, not its label, and the ancestors are the
        // rows above it.
        case .tag(_, let path):
            return path.split(separator: "/").last.map(String.init) ?? path
        // `.host` = a row only the host can name (see `RecordSidebarScope.host`);
        // imprint declares none, so it falls in with the other scopes that mean
        // "the whole list" here.
        case .all, .section, .host, nil:
            return "All \(descriptor.displayName)s"
        }
    }

    private func refresh() {
        if publicationSource != nil {
            // `PublicationSource.citedInManuscripts` resolves against
            // `CitedInManuscriptsSnapshot`, an in-memory set that something on
            // screen has to warm — on macOS that something is the sidebar's own
            // row. Here the list is the only reader, so the refresh warms it.
            Task { await CitedInManuscriptsSnapshot.shared.refresh() }
            return
        }
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
        guard url.scheme == "imprint" else { return }

        // `imprint://inspect/citation/{citeKey}` — the programmatic form of the
        // long-press citation affordance. iOS holds no
        // `com.apple.security.network.server` entitlement, so imprint-iOS runs
        // no HTTP automation server; a URL is how the on-device surface is
        // driven from outside the process (an agent, a sibling app, or
        // `xcrun simctl openurl`). The open editor picks it up via
        // `.inspectCiteKey` and shows exactly the sheet a finger would.
        if url.host == "inspect" {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.first == "citation", parts.count > 1 else { return }
            let citeKey = parts[1...].joined(separator: "/")
                .removingPercentEncoding ?? parts[1]
            NotificationCenter.default.post(
                name: .inspectCiteKey,
                object: nil,
                userInfo: ["citeKey": citeKey]
            )
            return
        }

        guard url.host == "open" else { return }
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
