//
//  IOSSidebarHost.swift
//  imbib-iOS
//
//  imbib-iOS's sidebar column: a wiring harness around
//  `PublicationManagerCore.RecordSidebarView` (Stage 5a).
//
//  Nothing here decides what the sidebar SHOWS. Sections, their order, titles,
//  icons and gates come from `AppShellConfiguration.imbib`; the rows come from
//  `ImbibSidebarBindings`; the rendering, expansion, collapse persistence and
//  organise grammar come from PMC. What is left is the chrome the old
//  hand-written sidebar carried and must keep carrying: the sheets, the add
//  menu, the section-reorder sheet, pull-to-refresh, and the per-row verbs that
//  are not folder verbs (Delete Library, Open on SciX, Hide a search form…),
//  handed to the shared renderer as `RecordSidebarHostChrome`.
//
//  Selection is BINDING-ONLY. The host owns `SidebarSection?` (what
//  `IOSContentView.contentList` routes on) and hands the shared view a proxy
//  binding through `ImbibSidebarBindings.scope(for:)` / `.section(for:)`, so
//  imbib's notification-driven navigation and the sidebar's own taps write the
//  same one place.
//
//  The second half of this file (from "New Library Sheet" down) is the five
//  sheet views that lived in `IOSSidebarView.swift` and are used only by this
//  column — carried over as-is rather than rewritten, because they were not the
//  thing that was wrong with the old sidebar. `IOSSidebarView`'s two local
//  duplicates that WERE wrong are gone: `ArXivSearchField` shadowed the public
//  `PublicationManagerCore` enum of the same name, and `LibraryDragItem` was a
//  `Transferable` nothing referenced.
//

import PublicationManagerCore
import SwiftUI
import UIKit
import os

struct IOSSidebarHost: View {

    // MARK: - Bindings

    @Binding var selection: SidebarSection?

    /// iPhone drill-down callback: fires with a smart-search id.
    var onNavigateToSmartSearch: ((UUID) -> Void)?

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Store

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - State

    @State private var snapshot = ImbibSidebarSnapshot()
    /// Bumped by anything that changes the ROWS without touching the store
    /// (hiding/reordering search forms, SciX arriving, section reorder).
    @State private var chromeRevision = 0
    /// See `refresh()` — pull-to-refresh can re-enter.
    @State private var isRefreshing = false

    @State private var searchFormOrder: [SearchFormType] = SearchFormStore.loadOrderSync()
    @State private var hiddenSearchForms: Set<SearchFormType> = SearchFormStore.loadHiddenSync()
    @State private var sectionOrder: [SidebarSectionType] = SidebarSectionOrderStore.loadOrderSync()
    @State private var inboxAgeLimit: AgeLimitPreset = .threeMonths

    // Sheets / confirmations
    @State private var showNewLibrarySheet = false
    @State private var showArXivCategoryBrowser = false
    @State private var showSectionReorderSheet = false
    @State private var showNewCollectionForLibrary: UUID?
    @State private var showSmartCollectionForLibrary: UUID?
    @State private var renamingCollection: CollectionModel?
    @State private var libraryToDelete: LibraryModel?
    @State private var showDeleteLibraryConfirmation = false

    // MARK: - Derived

    private var visibleSearchForms: [SearchFormType] {
        searchFormOrder.filter { !hiddenSearchForms.contains($0) }
    }

    /// The chassis-vocabulary view of `selection`. Two-way, because both the
    /// sidebar and imbib's notifications write the selection.
    private var scopeSelection: Binding<RecordSidebarScope?> {
        Binding(
            get: { ImbibSidebarBindings.scope(for: selection) },
            set: { newScope in
                // `nil` reaches here when the shared view clears a selection it
                // just deleted; anything it cannot route leaves the content
                // pane where it is rather than blanking it.
                guard let newScope else { selection = nil; return }
                if let mapped = ImbibSidebarBindings.section(for: newScope) {
                    selection = mapped
                }
            })
    }

    /// The library the add menu targets: the selected one, else the first.
    private var actionLibrary: LibraryModel? {
        if case .library(let id) = selection,
           let match = snapshot.libraries.first(where: { $0.id == id }) {
            return match
        }
        return snapshot.libraries.first
    }

    // MARK: - Body

    var body: some View {
        RecordSidebarView(
            configuration: ImbibSidebarBindings.configuration,
            dataSource: ImbibSidebarBindings.dataSource(
                snapshot: snapshot,
                libraryManager: libraryManager,
                searchForms: visibleSearchForms),
            collectionActions: ImbibSidebarBindings.collectionActions(snapshot: snapshot),
            chrome: chrome,
            // Reading these two @Observable values HERE (in `body`) is what
            // registers observation for them: the data-source closures run
            // after body, so a read inside one is invisible to SwiftUI and the
            // SciX shelf list would never refresh after a background pull.
            dataVersion: ImbibSidebarBindings.dataVersion(
                chromeRevision: chromeRevision
                    &+ SciXLibraryRepository.shared.libraries.count),
            selection: scopeSelection,
            title: "imbib")
        .refreshable { await refresh() }
        .task {
            await refresh()
            await loadSciXIfAvailable()
        }
        .onReceive(NotificationCenter.default.publisher(for: .explorationLibraryDidChange)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSmartSearch)) { note in
            guard let searchID = note.object as? UUID else { return }
            selection = .smartSearch(searchID)
            onNavigateToSmartSearch?(searchID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { note in
            if let collectionID = note.userInfo?["collectionID"] as? UUID {
                selection = .collection(collectionID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncedSettingsDidChange)) { _ in
            Task { inboxAgeLimit = await InboxSettingsStore.shared.settings.ageLimit }
        }
        // The reorder sheet mutates `sectionOrder`; the SIDEBAR reads the order
        // back from the shared store (`SidebarSectionOrderStore`, the same one
        // macOS uses), so the rebuild has to wait for the write to land — a
        // bare `chromeRevision += 1` here would re-read the old order.
        .onChange(of: sectionOrder) { _, newOrder in
            Task {
                await SidebarSectionOrderStore.shared.save(newOrder)
                chromeRevision += 1
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSectionReorderSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityIdentifier("sidebar.reorderSections")
            }
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    addMenu
                    Spacer()
                }
            }
        }
        .modifier(SidebarSheets(
            showNewLibrarySheet: $showNewLibrarySheet,
            showArXivCategoryBrowser: $showArXivCategoryBrowser,
            showSectionReorderSheet: $showSectionReorderSheet,
            showNewCollectionForLibrary: $showNewCollectionForLibrary,
            showSmartCollectionForLibrary: $showSmartCollectionForLibrary,
            renamingCollection: $renamingCollection,
            libraryToDelete: $libraryToDelete,
            showDeleteLibraryConfirmation: $showDeleteLibraryConfirmation,
            sectionOrder: $sectionOrder,
            arXivLibraryID: actionLibrary?.id,
            onDeleteLibrary: { library in
                try? libraryManager.deleteLibrary(id: library.id)
                Task { await refresh() }
            }))
    }

    // MARK: - Host chrome

    private var chrome: RecordSidebarHostChrome {
        // Captured, not read inside the closure: same observation rule as the
        // `dataVersion` note above — the inbox badge is @Observable state.
        let unreadCount = InboxManager.shared.unreadCount
        return RecordSidebarHostChrome(
            nodeAccessory: { node in
                // The per-library `+`: creates a collection IN that library,
                // which is why the section header offers no root create.
                guard case .library(let libraryID)? = route(node) else { return nil }
                return AnyView(
                    Menu {
                        Button {
                            showSmartCollectionForLibrary = libraryID
                        } label: {
                            Label("New Smart Collection", systemImage: "folder.badge.gearshape")
                        }
                        Button {
                            showNewCollectionForLibrary = libraryID
                        } label: {
                            Label("New Collection", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    })
            },
            nodeMenu: { node in nodeMenu(node) },
            nodeSwipeActions: { node in nodeSwipeActions(node) },
            sectionAccessory: { section in sectionAccessory(section, unreadCount: unreadCount) },
            // DELIBERATELY nil, and the reason is a finding worth keeping.
            //
            // The deleted sidebar reordered search forms and SciX shelves with
            // `ForEach.onMove`. Wiring the same thing here made the sidebar
            // hostile: `onMove` installs a drag-reorder recogniser on the
            // section's rows, and it captures ordinary drags — a plain scroll
            // swipe left the app never reporting idle (every UI test that
            // scrolled the sidebar TIMED OUT rather than failed), and
            // collapsing a section whose rows carried it did the same. A
            // sidebar you cannot reliably scroll on a touch device is a worse
            // bargain than drag-reorder of nine search forms.
            //
            // So the capability moved to explicit verbs — "Move Up" / "Move
            // Down" in each row's menu (see `nodeMenu`), which is also more in
            // keeping with a keyboard-first suite than a drag. The
            // `onMoveNodes` seam stays in the chassis for a host whose section
            // has no scroll to lose.
            onMoveNodes: nil)
    }

    private func route(_ node: RecordSidebarNode) -> ImbibSidebarRoute? {
        node.scope.hostKey.flatMap(ImbibSidebarRoute.init(key:))
    }

    private func collection(_ node: RecordSidebarNode) -> CollectionModel? {
        guard let id = node.scope.folderID else { return nil }
        let all = snapshot.collectionsByLibrary.values.flatMap { $0 }
            + snapshot.inboxCollections + snapshot.explorationCollections
        return all.first { $0.id == id }
    }

    private func nodeMenu(_ node: RecordSidebarNode) -> AnyView? {
        switch route(node) {
        case .library(let libraryID):
            if let library = snapshot.libraries.first(where: { $0.id == libraryID }) {
                return AnyView(
                    Button("Delete Library", role: .destructive) {
                        libraryToDelete = library
                        showDeleteLibraryConfirmation = true
                    })
            }
            return nil

        case .feed(let feedID):
            return AnyView(
                Group {
                    Button {
                        NotificationCenter.default.post(name: .editSmartSearch, object: feedID)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteSmartSearch(feedID)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                })

        case .scixLibrary(let libraryID):
            guard let library = SciXLibraryRepository.shared.libraries
                .first(where: { $0.id == libraryID })
            else { return nil }
            return AnyView(
                Group {
                    Button {
                        if let url = URL(
                            string:
                                "https://ui.adsabs.harvard.edu/user/libraries/\(library.remoteID)")
                        {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open on SciX", systemImage: "safari")
                    }
                    Button {
                        Task {
                            try? await SciXSyncManager.shared.pullLibraryPapers(
                                libraryID: library.remoteID)
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    reorderButtons(
                        of: library.id,
                        in: SciXLibraryRepository.shared.libraries.map(\.id),
                        move: moveScixLibrary(_:to:))
                })

        case .searchForm(let form):
            return AnyView(
                Group {
                    reorderButtons(
                        of: form, in: visibleSearchForms, move: moveSearchForm(_:to:))
                    Divider()
                    Button("Hide", role: .destructive) { hideSearchForm(form) }
                })

        case .recent, .contentOnly:
            return nil

        case nil:
            // A SMART collection: `isFolder` is false for it (no subfolders, no
            // reparent — the same rule macOS applies), so the shared organise
            // menu skips it, and Rename/Delete would have been lost.
            guard let collection = collection(node), collection.isSmart else { return nil }
            return AnyView(
                Group {
                    Button {
                        renamingCollection = collection
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteCollection(collection)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                })
        }
    }

    private func nodeSwipeActions(_ node: RecordSidebarNode) -> AnyView? {
        if case .feed(let feedID)? = route(node) {
            return AnyView(
                Button(role: .destructive) {
                    deleteSmartSearch(feedID)
                } label: {
                    Label("Delete", systemImage: "trash")
                })
        }
        guard let collection = collection(node) else { return nil }
        // Exploration collections delete through `LibraryManager` (it also
        // clears ExplorationService's context); smart collections have no
        // shared swipe because they are not organisable folders.
        let isExploration = snapshot.explorationCollections.contains { $0.id == collection.id }
        guard isExploration || collection.isSmart else { return nil }
        return AnyView(
            Button(role: .destructive) {
                if isExploration {
                    deleteExplorationCollection(collection)
                } else {
                    deleteCollection(collection)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            })
    }

    private func sectionAccessory(_ section: SidebarSectionType, unreadCount: Int) -> AnyView? {
        switch section {
        case .inbox:
            return AnyView(
                HStack(spacing: 6) {
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    Text(inboxAgeLimit == .unlimited ? "∞" : inboxAgeLimit.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Menu {
                        Button {
                            createInboxRootCollection()
                        } label: {
                            Label("New Collection", systemImage: "folder.badge.plus")
                        }
                        Divider()
                        Button {
                            selection = .searchForm(.adsModern)
                        } label: {
                            Label("SciX Search", systemImage: "magnifyingglass")
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                })

        case .search:
            guard !hiddenSearchForms.isEmpty else { return nil }
            return AnyView(
                Menu {
                    ForEach(
                        hiddenSearchForms.sorted { $0.rawValue < $1.rawValue }, id: \.self
                    ) { form in
                        Button("Show \(form.displayName)") { showSearchForm(form) }
                    }
                    Divider()
                    Button("Show All") { showAllSearchForms() }
                } label: {
                    Image(systemName: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("sidebar.showHiddenSearchForms"))

        default:
            return nil
        }
    }

    // MARK: - Mutations

    private func createInboxRootCollection() {
        guard let inbox = snapshot.inboxLibrary else { return }
        if let created = store.createCollection(name: "New Collection", libraryId: inbox.id) {
            Task { await refresh() }
            renamingCollection = created
        }
    }

    private func deleteSmartSearch(_ id: UUID) {
        if case .smartSearch(let selected) = selection, selected == id { selection = nil }
        store.deleteSmartSearch(id: id)
    }

    private func deleteCollection(_ collection: CollectionModel) {
        if case .collection(let id) = selection, id == collection.id { selection = nil }
        store.deleteCollection(id: collection.id)
    }

    private func deleteExplorationCollection(_ collection: CollectionModel) {
        if case .collection(let id) = selection, id == collection.id { selection = nil }
        libraryManager.deleteExplorationCollection(id: collection.id)
        Task { await refresh() }
    }

    /// "Move Up" / "Move Down" for one element of an ordered row set — the
    /// gesture-free replacement for `ForEach.onMove` (see the `onMoveNodes`
    /// note in `chrome`). Each end of the list hides its impossible direction.
    @ViewBuilder
    private func reorderButtons<Item: Equatable>(
        of item: Item, in order: [Item], move: @escaping (Item, Int) -> Void
    ) -> some View {
        if let index = order.firstIndex(of: item) {
            if index > 0 {
                Button {
                    move(item, index - 1)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
            }
            if index < order.count - 1 {
                Button {
                    move(item, index + 1)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
            }
        }
    }

    /// Move `form` to `index` among the VISIBLE forms, keeping the hidden ones
    /// in their existing relative slots (the persisted order holds both).
    private func moveSearchForm(_ form: SearchFormType, to index: Int) {
        var visible = visibleSearchForms
        guard let from = visible.firstIndex(of: form), index >= 0, index < visible.count
        else { return }
        visible.remove(at: from)
        visible.insert(form, at: index)

        var newOrder: [SearchFormType] = []
        var next = 0
        for existing in searchFormOrder {
            if hiddenSearchForms.contains(existing) {
                newOrder.append(existing)
            } else if next < visible.count {
                newOrder.append(visible[next])
                next += 1
            }
        }
        while next < visible.count {
            newOrder.append(visible[next])
            next += 1
        }
        searchFormOrder = newOrder
        chromeRevision += 1
        Task { await SearchFormStore.shared.save(newOrder) }
    }

    private func moveScixLibrary(_ id: UUID, to index: Int) {
        var reordered = SciXLibraryRepository.shared.libraries
        guard let from = reordered.firstIndex(where: { $0.id == id }),
              index >= 0, index < reordered.count
        else { return }
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: index)
        SciXLibraryRepository.shared.updateSortOrder(reordered)
        chromeRevision += 1
    }

    private func hideSearchForm(_ form: SearchFormType) {
        hiddenSearchForms.insert(form)
        chromeRevision += 1
        Task { await SearchFormStore.shared.hide(form) }
    }

    private func showSearchForm(_ form: SearchFormType) {
        hiddenSearchForms.remove(form)
        chromeRevision += 1
        Task { await SearchFormStore.shared.show(form) }
    }

    private func showAllSearchForms() {
        hiddenSearchForms.removeAll()
        chromeRevision += 1
        Task { await SearchFormStore.shared.setHidden([]) }
    }

    // MARK: - Refresh

    @MainActor
    private func refresh() async {
        // Re-entrancy guard. `.refreshable` fires once per pull and the user can
        // pull again mid-flight; each pass does a full store read plus
        // `CitedInManuscriptsSnapshot.refresh()`, and overlapping passes each
        // bump `chromeRevision`, which rebuilds the sidebar, which is exactly
        // the compounding-refresh shape the root CLAUDE.md warns about (an
        // eight-swipe UI-test scroll was enough to take the app down).
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await CitedInManuscriptsSnapshot.shared.refresh()
        snapshot.refresh(store, libraryManager: libraryManager, force: true)
        inboxAgeLimit = await InboxSettingsStore.shared.settings.ageLimit
        chromeRevision += 1
    }

    @MainActor
    private func loadSciXIfAvailable() async {
        guard await CredentialManager.shared.apiKey(for: "ads") != nil else { return }
        snapshot.scixAvailable = true
        SciXLibraryRepository.shared.loadLibraries()
        chromeRevision += 1
        Task.detached { try? await SciXSyncManager.shared.pullLibraries() }
    }

    // MARK: - Add Menu

    @ViewBuilder
    private var addMenu: some View {
        Menu {
            Button {
                showNewLibrarySheet = true
            } label: {
                Label("New Library", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier(AccessibilityID.Sidebar.newLibraryButton)

            if let library = actionLibrary {
                Divider()
                Section("Add to \(library.name)") {
                    Button {
                        NotificationCenter.default.post(
                            name: .navigateToSearchSection, object: library.id)
                    } label: {
                        Label("New Smart Search", systemImage: "magnifyingglass.circle")
                    }
                    Button {
                        showNewCollectionForLibrary = library.id
                    } label: {
                        Label("New Collection", systemImage: "folder")
                    }
                }
            }

            Divider()

            Button {
                showArXivCategoryBrowser = true
            } label: {
                Label("Browse arXiv Categories", systemImage: "list.bullet.rectangle")
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}

// MARK: - Sheets

/// Every sheet/alert the sidebar column presents, factored out so the body
/// above stays readable (SwiftUI type-checking cost, not taste).
private struct SidebarSheets: ViewModifier {
    @Binding var showNewLibrarySheet: Bool
    @Binding var showArXivCategoryBrowser: Bool
    @Binding var showSectionReorderSheet: Bool
    @Binding var showNewCollectionForLibrary: UUID?
    @Binding var showSmartCollectionForLibrary: UUID?
    @Binding var renamingCollection: CollectionModel?
    @Binding var libraryToDelete: LibraryModel?
    @Binding var showDeleteLibraryConfirmation: Bool
    @Binding var sectionOrder: [SidebarSectionType]
    let arXivLibraryID: UUID?
    let onDeleteLibrary: (LibraryModel) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showNewLibrarySheet) {
                NewLibrarySheet(isPresented: $showNewLibrarySheet)
            }
            .sheet(item: $showNewCollectionForLibrary) { libraryID in
                NewCollectionSheet(libraryID: libraryID)
            }
            .sheet(item: $showSmartCollectionForLibrary) { libraryID in
                SmartCollectionEditor(
                    isPresented: Binding(
                        get: { showSmartCollectionForLibrary != nil },
                        set: { if !$0 { showSmartCollectionForLibrary = nil } })
                ) { name, predicate in
                    _ = RustStoreAdapter.shared.createCollection(
                        name: name, libraryId: libraryID, isSmart: true, query: predicate)
                    showSmartCollectionForLibrary = nil
                }
            }
            .sheet(isPresented: $showArXivCategoryBrowser) {
                IOSArXivCategoryBrowserSheet(
                    isPresented: $showArXivCategoryBrowser, libraryID: arXivLibraryID)
            }
            .sheet(isPresented: $showSectionReorderSheet) {
                SectionReorderSheet(
                    sectionOrder: $sectionOrder, isPresented: $showSectionReorderSheet)
            }
            .sheet(item: $renamingCollection) { collection in
                CollectionRenameSheet(collection: collection) { renamingCollection = nil }
            }
            .alert(
                "Delete Library?", isPresented: $showDeleteLibraryConfirmation,
                presenting: libraryToDelete
            ) { library in
                Button("Delete", role: .destructive) { onDeleteLibrary(library) }
                Button("Cancel", role: .cancel) {}
            } message: { library in
                Text(
                    "Are you sure you want to delete \"\(library.name)\"? This will remove all publications and cannot be undone."
                )
            }
    }
}

/// `sheet(item:)` over a bare UUID — the two "new collection" sheets are keyed
/// by library id, and an optional-Bool pair for each was four bindings of
/// boilerplate in the file this replaces.
private struct IdentifiedUUID: Identifiable {
    let id: UUID
}

private extension View {
    func sheet<Content: View>(
        item: Binding<UUID?>, @ViewBuilder content: @escaping (UUID) -> Content
    ) -> some View {
        sheet(
            item: Binding(
                get: { item.wrappedValue.map(IdentifiedUUID.init) },
                set: { if $0 == nil { item.wrappedValue = nil } })
        ) { wrapped in
            content(wrapped.id)
        }
    }
}

// MARK: - New Library Sheet

struct NewLibrarySheet: View {
    @Binding var isPresented: Bool
    @Environment(LibraryManager.self) private var libraryManager

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Library Name", text: $name)
                        .accessibilityIdentifier(AccessibilityID.Dialog.Library.nameField)
                }
                Section {
                    Text("Library will sync across your devices via iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .accessibilityIdentifier(AccessibilityID.Dialog.Library.cancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        _ = libraryManager.createLibrary(
                            name: name.isEmpty ? "New Library" : name)
                        isPresented = false
                    }
                    .disabled(name.isEmpty)
                    .accessibilityIdentifier(AccessibilityID.Dialog.Library.createButton)
                }
            }
        }
    }
}

// MARK: - New Collection Sheet

struct NewCollectionSheet: View {
    let libraryID: UUID

    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Collection Name", text: $name)
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        _ = RustStoreAdapter.shared.createCollection(
                            name: name, libraryId: libraryID)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

// MARK: - Collection Rename Sheet

/// Sheet for renaming a collection.
struct CollectionRenameSheet: View {
    let collection: CollectionModel
    var onDismiss: (() -> Void)?

    @State private var name: String = ""
    @FocusState private var isNameFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Collection Name", text: $name)
                    .focused($isNameFieldFocused)
            }
            .navigationTitle("Rename Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss?(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveChanges() }
                        .disabled(name.isEmpty)
                }
            }
            .onAppear {
                name = collection.name
                isNameFieldFocused = true
            }
        }
    }

    private func saveChanges() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != collection.name {
            _ = RustStoreAdapter.shared.renameCollection(id: collection.id, name: trimmed)
        }
        onDismiss?()
        dismiss()
    }
}

// MARK: - Section Reorder Sheet

/// Sheet for reordering sidebar sections. The order it writes is the SAME
/// persisted order `RecordSidebarBuilder` reads (`SidebarSectionOrderStore`),
/// shared with macOS.
struct SectionReorderSheet: View {
    @Binding var sectionOrder: [SidebarSectionType]
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(sectionOrder) { sectionType in
                    HStack {
                        Image(systemName: sectionType.icon)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(sectionType.displayName)
                        Spacer()
                    }
                }
                // Mutating the binding is the whole job: the HOST persists it
                // and bumps the sidebar's rebuild trigger once the write lands.
                .onMove { source, destination in
                    sectionOrder.move(fromOffsets: source, toOffset: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}

// MARK: - iOS arXiv Category Browser Sheet

/// Sheet wrapper for ArXivCategoryBrowser on iOS. Follows a category to
/// create an inbox-feeding smart search via RustStoreAdapter.
struct IOSArXivCategoryBrowserSheet: View {
    @Binding var isPresented: Bool
    let libraryID: UUID?

    var body: some View {
        NavigationStack {
            ArXivCategoryBrowser(
                onFollow: { category, feedName in
                    createCategoryFeed(category: category, name: feedName)
                },
                onDismiss: { isPresented = false }
            )
            .navigationTitle("arXiv Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    private func createCategoryFeed(category: ArXivCategory, name: String) {
        guard let libraryID else { return }
        _ = RustStoreAdapter.shared.createSmartSearch(
            name: name,
            query: "cat:\(category.id)",
            libraryId: libraryID,
            sourceIdsJson: "[\"arxiv\"]",
            maxResults: 100,
            feedsToInbox: true,
            autoRefreshEnabled: true,
            refreshIntervalSeconds: 86400
        )
        os_log(
            .info, "Created arXiv category feed: %{public}@ for category %{public}@", name,
            category.id)
        isPresented = false
    }
}

// MARK: - iOS arXiv Category Picker Sheet

/// A simple category picker for selecting an arXiv category in smart search editor.
struct IOSArXivCategoryPickerSheet: View {
    @Binding var selectedCategory: String
    @Binding var isPresented: Bool

    @State private var searchText = ""

    private var filteredCategories: [ArXivCategory] {
        if searchText.isEmpty { return ArXivCategories.all }
        let lowercased = searchText.lowercased()
        return ArXivCategories.all.filter { category in
            category.id.lowercased().contains(lowercased)
                || category.name.lowercased().contains(lowercased)
                || category.group.lowercased().contains(lowercased)
        }
    }

    private var groupedCategories: [(String, [ArXivCategory])] {
        Dictionary(grouping: filteredCategories) { $0.group }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.id < $1.id }) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedCategories, id: \.0) { group, categories in
                    Section(group) {
                        ForEach(categories) { category in
                            Button {
                                selectedCategory = category.id
                                isPresented = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(category.id).font(.headline)
                                        Text(category.name)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedCategory == category.id {
                                        Image(systemName: "checkmark").foregroundStyle(.blue)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search categories")
            .navigationTitle("Select Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}
