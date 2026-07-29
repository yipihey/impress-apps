//
//  IOSSidebarView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//  Revived 2026-07-20: ported off Core Data (CDLibrary / CDCollection /
//  CDSmartSearch / CDPublication) to the value-type + RustStoreAdapter
//  world. Navigation is complete (inbox subtree, libraries with smart
//  searches + collections, exploration, flagged, SciX, cited, search
//  forms). Delete/rename collection and delete smart search are now wired
//  through RustStoreAdapter. Remaining degraded ops (nested subcollection
//  creation) still lack a RustStoreAdapter API — see the `iOS: … not yet
//  supported` warningCapture calls and docs/adr/ios-migration-debt.md.
//

import SwiftUI
import PublicationManagerCore
import os
import UniformTypeIdentifiers

// MARK: - Library Drag Item

/// Transferable wrapper for dragging libraries (for reordering).
struct LibraryDragItem: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .libraryID) { item in
            item.id.uuidString.data(using: .utf8) ?? Data()
        } importing: { data in
            guard let string = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return LibraryDragItem(id: uuid)
        }
    }
}

/// iOS sidebar with library navigation, smart searches, and collections.
///
/// Adapts the macOS sidebar for iOS with appropriate touch targets and
/// navigation patterns. All data is sourced from `RustStoreAdapter`.
struct IOSSidebarView: View {

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(LibraryViewModel.self) private var libraryViewModel

    // MARK: - Bindings

    @Binding var selection: SidebarSection?

    /// iPhone drill-down callback: fires with a smart-search id.
    var onNavigateToSmartSearch: ((UUID) -> Void)?

    // MARK: - Store

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    /// SciX library repository (uses @Observable).
    private var scixRepository: SciXLibraryRepository { SciXLibraryRepository.shared }

    // MARK: - Loaded Data (value types)

    @State private var libraries: [LibraryModel] = []
    @State private var inboxLibrary: LibraryModel?
    @State private var inboxCollections: [CollectionModel] = []
    @State private var explorationLibrary: LibraryModel?
    @State private var explorationCollections: [CollectionModel] = []
    @State private var libSmartSearches: [UUID: [SmartSearch]] = [:]
    @State private var libCollections: [UUID: [CollectionModel]] = [:]
    @State private var citedCount: Int = 0
    @State private var manuscriptCount: Int = 0
    @State private var hasSciXAPIKey = false
    @State private var inboxAgeLimit: AgeLimitPreset = .threeMonths

    // MARK: - Sheet / UI State

    @State private var showNewLibrarySheet = false
    @State private var showArXivCategoryBrowser = false
    @State private var selectedLibraryForAction: UUID?
    @State private var libraryToDelete: LibraryModel?
    @State private var showDeleteLibraryConfirmation = false
    @State private var showNewCollectionForLibrary: UUID?
    @State private var showSmartCollectionForLibrary: UUID?
    @State private var renamingCollection: CollectionModel?
    @State private var showSectionReorderSheet = false

    // Expansion state
    @State private var expandedLibraries: Set<UUID> = []
    @State private var expandedLibraryCollections: [UUID: Set<UUID>] = [:]
    @State private var expandedInboxCollections: Set<UUID> = []

    // Section ordering and collapsed state (persisted, synced with macOS)
    @State private var sectionOrder: [SidebarSectionType] = SidebarSectionOrderStore.loadOrderSync()
    @State private var collapsedSections: Set<SidebarSectionType> = SidebarCollapsedStateStore.loadCollapsedSync()

    // Search form ordering and visibility (persisted)
    @State private var searchFormOrder: [SearchFormType] = SearchFormStore.loadOrderSync()
    @State private var hiddenSearchForms: Set<SearchFormType> = SearchFormStore.loadHiddenSync()

    // MARK: - Body

    var body: some View {
        List(selection: $selection) {
            ForEach(sectionOrder) { sectionType in
                sectionView(for: sectionType)
            }
        }
        .listStyle(.sidebar)
        .refreshable {
            await refresh()
        }
        .task {
            await refresh()
            await loadSciXIfAvailable()
            // Auto-expand the first library if none expanded.
            if expandedLibraries.isEmpty, let first = libraries.first {
                expandedLibraries.insert(first.id)
            }
        }
        .onChange(of: store.dataVersion) { _, _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .explorationLibraryDidChange)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSmartSearch)) { notification in
            if let searchID = notification.object as? UUID {
                selection = .smartSearch(searchID)
                onNavigateToSmartSearch?(searchID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { notification in
            if let collectionID = notification.userInfo?["collectionID"] as? UUID {
                selection = .collection(collectionID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncedSettingsDidChange)) { _ in
            Task {
                let settings = await InboxSettingsStore.shared.settings
                inboxAgeLimit = settings.ageLimit
            }
        }
        .navigationTitle("imbib")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSectionReorderSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    addMenu
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showNewLibrarySheet) {
            NewLibrarySheet(isPresented: $showNewLibrarySheet)
        }
        .sheet(isPresented: Binding(
            get: { showNewCollectionForLibrary != nil },
            set: { if !$0 { showNewCollectionForLibrary = nil } }
        )) {
            if let libraryID = showNewCollectionForLibrary {
                NewCollectionSheet(
                    isPresented: Binding(
                        get: { showNewCollectionForLibrary != nil },
                        set: { if !$0 { showNewCollectionForLibrary = nil } }
                    ),
                    libraryID: libraryID
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { showSmartCollectionForLibrary != nil },
            set: { if !$0 { showSmartCollectionForLibrary = nil } }
        )) {
            if let libraryID = showSmartCollectionForLibrary {
                SmartCollectionEditor(
                    isPresented: Binding(
                        get: { showSmartCollectionForLibrary != nil },
                        set: { if !$0 { showSmartCollectionForLibrary = nil } }
                    )
                ) { name, predicate in
                    _ = store.createCollection(name: name, libraryId: libraryID, isSmart: true, query: predicate)
                    showSmartCollectionForLibrary = nil
                }
            }
        }
        .sheet(isPresented: $showArXivCategoryBrowser) {
            IOSArXivCategoryBrowserSheet(
                isPresented: $showArXivCategoryBrowser,
                libraryID: selectedLibraryForAction ?? libraries.first?.id
            )
        }
        .sheet(isPresented: $showSectionReorderSheet) {
            SectionReorderSheet(
                sectionOrder: $sectionOrder,
                isPresented: $showSectionReorderSheet
            )
        }
        .sheet(item: $renamingCollection) { collection in
            CollectionRenameSheet(collection: collection) {
                renamingCollection = nil
            }
        }
        .alert("Delete Library?", isPresented: $showDeleteLibraryConfirmation, presenting: libraryToDelete) { library in
            Button("Delete", role: .destructive) {
                try? libraryManager.deleteLibrary(id: library.id)
                Task { await refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Are you sure you want to delete \"\(library.name)\"? This will remove all publications and cannot be undone.")
        }
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

            if let library = (selectedLibraryForAction.flatMap { id in libraries.first(where: { $0.id == id }) }) ?? libraries.first {
                Divider()
                Section("Add to \(library.name)") {
                    Button {
                        NotificationCenter.default.post(name: .navigateToSearchSection, object: library.id)
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

    // MARK: - Section Dispatch

    @ViewBuilder
    private func sectionView(for sectionType: SidebarSectionType) -> some View {
        switch sectionType {
        case .inbox:
            selectableCollapsibleSection(for: .inbox, tag: .inbox) {
                inboxSectionContent
            }
        case .libraries:
            collapsibleSection(for: .libraries) {
                librariesSectionContent
            }
        case .scixLibraries:
            if hasSciXAPIKey && !scixRepository.libraries.isEmpty {
                collapsibleSection(for: .scixLibraries) {
                    scixLibrariesSectionContent
                }
            }
        case .search:
            collapsibleSection(for: .search) {
                searchSectionContent
            }
        case .exploration:
            if !explorationCollections.isEmpty {
                collapsibleSection(for: .exploration) {
                    explorationSectionContent
                }
            }
        case .flagged:
            selectableCollapsibleSection(for: .flagged, tag: .flagged(nil)) {
                flaggedSectionContent
            }
        case .citedInManuscripts:
            if citedCount > 0 {
                citedInManuscriptsSection
            }
        case .manuscripts:
            manuscriptsSection
        case .sharedWithMe, .artifacts, .figures, .mail, .agents, .reviewQueue, .dismissed:
            // Not representable in the iOS SidebarSection routing table yet.
            // (.figures/.mail/.agents are implore/impart/impel-only facets
            // on macOS anyway — Stage 2; imbib itself is publications-only
            // since the ADR-0022 purification.)
            EmptyView()
        }
    }

    // MARK: - Collapsible Section Chrome

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        for sectionType: SidebarSectionType,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(sectionType)
        Section {
            if !isCollapsed { content() }
        } header: {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { toggleSectionCollapsed(sectionType) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Text(sectionType.displayName).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                sectionHeaderExtras(for: sectionType)
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func selectableCollapsibleSection<Content: View>(
        for sectionType: SidebarSectionType,
        tag: SidebarSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(sectionType)
        Section {
            if !isCollapsed { content() }
        } header: {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { toggleSectionCollapsed(sectionType) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Text(sectionType.displayName).foregroundStyle(.primary)
                    if sectionType == .inbox && InboxManager.shared.unreadCount > 0 {
                        Text("\(InboxManager.shared.unreadCount)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selection = tag }

                Spacer()
                sectionHeaderExtras(for: sectionType)
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func sectionHeaderExtras(for sectionType: SidebarSectionType) -> some View {
        switch sectionType {
        case .inbox:
            HStack(spacing: 6) {
                Text(inboxRetentionLabel)
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
            }
        default:
            EmptyView()
        }
    }

    private var inboxRetentionLabel: String {
        inboxAgeLimit == .unlimited ? "∞" : inboxAgeLimit.displayName
    }

    private func toggleSectionCollapsed(_ sectionType: SidebarSectionType) {
        if collapsedSections.contains(sectionType) {
            collapsedSections.remove(sectionType)
        } else {
            collapsedSections.insert(sectionType)
        }
        Task { await SidebarCollapsedStateStore.shared.save(collapsedSections) }
    }

    // MARK: - Inbox Section

    @ViewBuilder
    private var inboxSectionContent: some View {
        // "Recent" — papers the user viewed or added by hand. Sits above the
        // inbox collections because it is about the user's own activity, not
        // ingest. Mirrors the macOS sidebar's Inbox-section node.
        Label("Recent", systemImage: "clock.arrow.circlepath")
            .tag(SidebarSection.recent)

        let roots = inboxCollections
            .filter { $0.parentID == nil && !$0.isSmart }
            .sorted { $0.name < $1.name }
        ForEach(roots, id: \.id) { collection in
            iosInboxCollectionRow(collection: collection, depth: 0)
        }
    }

    @ViewBuilder
    private func iosInboxCollectionRow(collection: CollectionModel, depth: Int) -> some View {
        let children = inboxCollections.filter { $0.parentID == collection.id }
        let isExpanded = expandedInboxCollections.contains(collection.id)

        HStack {
            if !children.isEmpty {
                Button {
                    toggleInboxCollectionExpanded(collection)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Label(collection.name, systemImage: "folder")
            Spacer()
            if collection.publicationCount > 0 {
                Text("\(collection.publicationCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .tag(SidebarSection.inboxCollection(collection.id))
        .contextMenu {
            Button { renamingCollection = collection } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button { createSubcollectionInInbox(parent: collection) } label: {
                Label("New Subcollection", systemImage: "folder.badge.plus")
            }
            Divider()
            Button(role: .destructive) { deleteCollection(collection) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteCollection(collection) } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        if isExpanded {
            ForEach(children, id: \.id) { child in
                AnyView(iosInboxCollectionRow(collection: child, depth: depth + 1))
            }
        }
    }

    private func toggleInboxCollectionExpanded(_ collection: CollectionModel) {
        if expandedInboxCollections.contains(collection.id) {
            expandedInboxCollections.remove(collection.id)
        } else {
            expandedInboxCollections.insert(collection.id)
        }
    }

    private func createInboxRootCollection() {
        guard let inbox = inboxLibrary else { return }
        if let created = store.createCollection(name: "New Collection", libraryId: inbox.id) {
            Task { await refresh() }
            renamingCollection = created
        }
    }

    private func createSubcollectionInInbox(parent: CollectionModel) {
        guard let inbox = inboxLibrary else { return }
        // DEGRADED: RustStoreAdapter.createCollection has no parent parameter,
        // so the subcollection is created at the inbox root instead of nested
        // under `parent`. Needs createCollection(parentId:).
        Logger.library.warningCapture(
            "iOS: create nested inbox subcollection not yet supported by RustStoreAdapter — creating at root",
            category: "sidebar"
        )
        if let created = store.createCollection(name: "New Subcollection", libraryId: inbox.id) {
            expandedInboxCollections.insert(parent.id)
            Task { await refresh() }
            renamingCollection = created
        }
    }

    // MARK: - Libraries Section

    @ViewBuilder
    private var librariesSectionContent: some View {
        ForEach(libraries) { library in
            librarySection(for: library)
        }
    }

    @ViewBuilder
    private func librarySection(for library: LibraryModel) -> some View {
        let searches = (libSmartSearches[library.id] ?? []).filter { !$0.feedsToInbox }
        let collections = libCollections[library.id] ?? []

        DisclosureGroup(isExpanded: expansionBinding(for: library.id)) {
            // Smart Searches
            if !searches.isEmpty {
                DisclosureGroup("Smart Searches") {
                    ForEach(searches) { search in
                        Label(search.name, systemImage: "magnifyingglass.circle")
                            .tag(SidebarSection.smartSearch(search.id))
                            .contextMenu {
                                Button {
                                    NotificationCenter.default.post(name: .editSmartSearch, object: search.id)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deleteSmartSearch(search)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleteSmartSearch(search) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }

            // Collections (hierarchical)
            if !collections.isEmpty {
                DisclosureGroup("Collections") {
                    let flat = flattenedCollections(collections)
                    let visible = filterVisibleCollections(flat, libraryID: library.id)
                    ForEach(visible, id: \.id) { collection in
                        libraryCollectionRow(collection, allCollections: flat, library: library)
                    }
                }
            }
        } label: {
            HStack {
                Label(library.name, systemImage: "folder")
                Spacer()
                if library.publicationCount > 0 {
                    Text("\(library.publicationCount)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }
                Menu {
                    Button {
                        showSmartCollectionForLibrary = library.id
                    } label: {
                        Label("New Smart Collection", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        showNewCollectionForLibrary = library.id
                    } label: {
                        Label("New Collection", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                Button("Delete Library", role: .destructive) {
                    libraryToDelete = library
                    showDeleteLibraryConfirmation = true
                }
            }
        }
        .tag(SidebarSection.library(library.id))
        .accessibilityIdentifier(AccessibilityID.Sidebar.libraryRow(library.id))
    }

    private func expansionBinding(for libraryID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedLibraries.contains(libraryID) },
            set: { isExpanded in
                if isExpanded {
                    expandedLibraries.insert(libraryID)
                    selectedLibraryForAction = libraryID
                } else {
                    expandedLibraries.remove(libraryID)
                }
            }
        )
    }

    // MARK: - Library Collection Rows

    @ViewBuilder
    private func libraryCollectionRow(_ collection: CollectionModel, allCollections: [CollectionModel], library: LibraryModel) -> some View {
        let depth = depthOf(collection, in: allCollections)
        let hasChildren = allCollections.contains { $0.parentID == collection.id }
        let isExpanded = expandedLibraryCollections[library.id]?.contains(collection.id) ?? false

        HStack(spacing: 0) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }
            if hasChildren {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        var expanded = expandedLibraryCollections[library.id] ?? []
                        if isExpanded { expanded.remove(collection.id) } else { expanded.insert(collection.id) }
                        expandedLibraryCollections[library.id] = expanded
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            Image(systemName: collection.isSmart ? "folder.badge.gearshape" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.trailing, 4)

            Text(collection.name).lineLimit(1)
            Spacer()
            if collection.publicationCount > 0 {
                Text("\(collection.publicationCount)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .tag(SidebarSection.collection(collection.id))
        .contextMenu {
            Button { renamingCollection = collection } label: {
                Label("Rename", systemImage: "pencil")
            }
            if !collection.isSmart {
                Button { createSubcollection(in: library, parent: collection) } label: {
                    Label("New Subcollection", systemImage: "folder.badge.plus")
                }
            }
            Divider()
            Button(role: .destructive) { deleteCollection(collection) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteCollection(collection) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func createSubcollection(in library: LibraryModel, parent: CollectionModel) {
        // DEGRADED: no parent parameter on createCollection — created at root.
        Logger.library.warningCapture(
            "iOS: create nested library subcollection not yet supported by RustStoreAdapter — creating at root",
            category: "sidebar"
        )
        if let created = store.createCollection(name: "New Subcollection", libraryId: library.id) {
            var expanded = expandedLibraryCollections[library.id] ?? []
            expanded.insert(parent.id)
            expandedLibraryCollections[library.id] = expanded
            Task { await refresh() }
            renamingCollection = created
        }
    }

    // MARK: - Exploration Section

    @ViewBuilder
    private var explorationSectionContent: some View {
        let flat = flattenedCollections(explorationCollections.filter { !$0.isSmart })
        ForEach(flat, id: \.id) { collection in
            explorationCollectionRow(collection, allCollections: flat)
        }
    }

    @ViewBuilder
    private func explorationCollectionRow(_ collection: CollectionModel, allCollections: [CollectionModel]) -> some View {
        let depth = depthOf(collection, in: allCollections)
        HStack(spacing: 0) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.trailing, 4)
            Text(collection.name).lineLimit(1)
            Spacer()
            if collection.publicationCount > 0 {
                Text("\(collection.publicationCount)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .tag(SidebarSection.collection(collection.id))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteExplorationCollection(collection) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func deleteExplorationCollection(_ collection: CollectionModel) {
        if case .collection(let id) = selection, id == collection.id {
            selection = nil
        }
        libraryManager.deleteExplorationCollection(id: collection.id)
        Task { await refresh() }
    }

    // MARK: - SciX Libraries Section

    @ViewBuilder
    private var scixLibrariesSectionContent: some View {
        ForEach(scixRepository.libraries, id: \.id) { library in
            HStack {
                Label(library.name, systemImage: "building.columns")
                Spacer()
                Text("\(library.documentCount)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .tag(SidebarSection.scixLibrary(library.id))
            .contextMenu {
                Button {
                    if let url = URL(string: "https://ui.adsabs.harvard.edu/user/libraries/\(library.remoteID)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open on SciX", systemImage: "safari")
                }
                Button {
                    Task { try? await SciXSyncManager.shared.pullLibraryPapers(libraryID: library.remoteID) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onMove(perform: moveScixLibraries)
    }

    private func moveScixLibraries(from source: IndexSet, to destination: Int) {
        var reordered = scixRepository.libraries
        reordered.move(fromOffsets: source, toOffset: destination)
        scixRepository.updateSortOrder(reordered)
    }

    // MARK: - Search Section

    @ViewBuilder
    private var searchSectionContent: some View {
        ForEach(visibleSearchForms) { formType in
            Label(formType.displayName, systemImage: formType.icon)
                .tag(SidebarSection.searchForm(formType))
                .contextMenu {
                    Button("Hide", role: .destructive) { hideSearchForm(formType) }
                }
        }
        .onMove(perform: moveSearchForms)

        if !hiddenSearchForms.isEmpty {
            Menu {
                ForEach(Array(hiddenSearchForms).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { formType in
                    Button("Show \(formType.displayName)") { showSearchForm(formType) }
                }
                Divider()
                Button("Show All") { showAllSearchForms() }
            } label: {
                Label("Show Hidden Forms...", systemImage: "eye")
            }
        }
    }

    private var visibleSearchForms: [SearchFormType] {
        searchFormOrder.filter { !hiddenSearchForms.contains($0) }
    }

    private func moveSearchForms(from source: IndexSet, to destination: Int) {
        var visible = visibleSearchForms
        visible.move(fromOffsets: source, toOffset: destination)
        var newOrder: [SearchFormType] = []
        var visibleIndex = 0
        for formType in searchFormOrder {
            if hiddenSearchForms.contains(formType) {
                newOrder.append(formType)
            } else if visibleIndex < visible.count {
                newOrder.append(visible[visibleIndex]); visibleIndex += 1
            }
        }
        while visibleIndex < visible.count {
            newOrder.append(visible[visibleIndex]); visibleIndex += 1
        }
        withAnimation { searchFormOrder = newOrder }
        Task { await SearchFormStore.shared.save(newOrder) }
    }

    private func hideSearchForm(_ formType: SearchFormType) {
        withAnimation { hiddenSearchForms.insert(formType) }
        Task { await SearchFormStore.shared.hide(formType) }
    }

    private func showSearchForm(_ formType: SearchFormType) {
        withAnimation { hiddenSearchForms.remove(formType) }
        Task { await SearchFormStore.shared.show(formType) }
    }

    private func showAllSearchForms() {
        withAnimation { hiddenSearchForms.removeAll() }
        Task { await SearchFormStore.shared.setHidden([]) }
    }

    // MARK: - Flagged Section

    /// One row per flag colour, from `FlagColor.allCases` and the shared
    /// cross-platform mapping (ImpressFTUI) — not a literal list. A local
    /// table here is a second truth: it is how this section came to show
    /// SwiftUI's `.red/.orange/.blue/.gray` while macOS showed the flag
    /// palette's hexes, and how a fifth flag colour would silently never
    /// appear on iOS.
    @ViewBuilder
    private var flaggedSectionContent: some View {
        ForEach(FlagColor.allCases) { flag in
            NavigationLink(value: SidebarSection.flagged(flag.rawValue)) {
                Label {
                    Text(flag.displayName)
                } icon: {
                    Image(systemName: flag.systemImage)
                        .foregroundStyle(flag.displayColor)
                }
            }
        }
    }

    // MARK: - Manuscripts Section

    @ViewBuilder
    private var manuscriptsSection: some View {
        Section("Manuscripts") {
            NavigationLink(value: SidebarSection.manuscripts) {
                Label {
                    Text("All Manuscripts")
                } icon: {
                    Image(systemName: "doc.text.image")
                }
                .badge(manuscriptCount)
            }
        }
    }

    // MARK: - Cited in Manuscripts Section

    @ViewBuilder
    private var citedInManuscriptsSection: some View {
        Section("Cited in Manuscripts") {
            NavigationLink(value: SidebarSection.citedInManuscripts) {
                Label {
                    Text("All Cited Papers")
                } icon: {
                    Image(systemName: "text.book.closed.fill")
                }
                .badge(citedCount)
            }
        }
    }

    // MARK: - Degraded Mutations

    private func deleteSmartSearch(_ search: SmartSearch) {
        if case .smartSearch(let id) = selection, id == search.id {
            selection = nil
        }
        store.deleteSmartSearch(id: search.id)
    }

    private func deleteCollection(_ collection: CollectionModel) {
        if case .collection(let id) = selection, id == collection.id {
            selection = nil
        }
        if case .inboxCollection(let id) = selection, id == collection.id {
            selection = nil
        }
        store.deleteCollection(id: collection.id)
    }

    // MARK: - Collection Tree Helpers

    /// Flatten a collection list (parent-before-children) using parentID links,
    /// sorted by sortOrder then name within each sibling group.
    private func flattenedCollections(_ collections: [CollectionModel]) -> [CollectionModel] {
        var result: [CollectionModel] = []
        func children(of parentID: UUID?) -> [CollectionModel] {
            collections
                .filter { $0.parentID == parentID }
                .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name }
        }
        func add(_ collection: CollectionModel) {
            result.append(collection)
            for child in children(of: collection.id) { add(child) }
        }
        for root in children(of: nil) { add(root) }
        return result
    }

    /// Filter to collections whose ancestors are all expanded.
    private func filterVisibleCollections(_ collections: [CollectionModel], libraryID: UUID) -> [CollectionModel] {
        let expandedSet = expandedLibraryCollections[libraryID] ?? []
        let byID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        return collections.filter { collection in
            var current = collection.parentID
            while let parentID = current {
                if !expandedSet.contains(parentID) { return false }
                current = byID[parentID]?.parentID
            }
            return true
        }
    }

    private func depthOf(_ collection: CollectionModel, in collections: [CollectionModel]) -> Int {
        let byID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        var depth = 0
        var current = collection.parentID
        while let parentID = current {
            depth += 1
            current = byID[parentID]?.parentID
        }
        return depth
    }

    // MARK: - Refresh

    @MainActor
    private func refresh() async {
        // Special libraries excluded from the "Libraries" section.
        var specialIDs = Set<UUID>()
        if let inbox = store.getInboxLibrary() { specialIDs.insert(inbox.id) }
        if let exploration = libraryManager.explorationLibrary { specialIDs.insert(exploration.id) }
        if let save = libraryManager.saveLibrary { specialIDs.insert(save.id) }
        if let dismissed = libraryManager.dismissedLibrary { specialIDs.insert(dismissed.id) }

        let allLibraries = store.listLibraries()
        libraries = allLibraries.filter { !$0.isInbox && !specialIDs.contains($0.id) }

        // Per-library subtrees.
        var searches: [UUID: [SmartSearch]] = [:]
        var collections: [UUID: [CollectionModel]] = [:]
        for library in libraries {
            searches[library.id] = store.listSmartSearches(libraryId: library.id)
            collections[library.id] = store.listCollections(libraryId: library.id)
        }
        libSmartSearches = searches
        libCollections = collections

        // Inbox subtree.
        inboxLibrary = store.getInboxLibrary()
        if let inbox = inboxLibrary {
            inboxCollections = store.listCollections(libraryId: inbox.id)
        } else {
            inboxCollections = []
        }

        // Exploration subtree.
        explorationLibrary = libraryManager.explorationLibrary
        if let exploration = explorationLibrary {
            explorationCollections = store.listCollections(libraryId: exploration.id)
        } else {
            explorationCollections = []
        }

        // Cited count.
        await CitedInManuscriptsSnapshot.shared.refresh()
        citedCount = CitedInManuscriptsSnapshot.shared.citedPaperIDs.count

        // Manuscript count (Manuscripts section badge).
        manuscriptCount = store.countManuscripts()

        // Inbox retention label.
        let settings = await InboxSettingsStore.shared.settings
        inboxAgeLimit = settings.ageLimit
    }

    @MainActor
    private func loadSciXIfAvailable() async {
        if let _ = await CredentialManager.shared.apiKey(for: "ads") {
            hasSciXAPIKey = true
            scixRepository.loadLibraries()
            Task.detached { try? await SciXSyncManager.shared.pullLibraries() }
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
                    Button("Create") { createLibrary() }
                        .disabled(name.isEmpty)
                        .accessibilityIdentifier(AccessibilityID.Dialog.Library.createButton)
                }
            }
        }
    }

    private func createLibrary() {
        _ = libraryManager.createLibrary(name: name.isEmpty ? "New Library" : name)
        isPresented = false
    }
}

// MARK: - New Collection Sheet

struct NewCollectionSheet: View {
    @Binding var isPresented: Bool
    let libraryID: UUID

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Collection Name", text: $name)
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createCollection() }
                        .disabled(name.isEmpty)
                }
            }
        }
    }

    private func createCollection() {
        _ = RustStoreAdapter.shared.createCollection(name: name, libraryId: libraryID)
        isPresented = false
    }
}

// MARK: - arXiv Search Field Enum

/// Search field options for arXiv queries.
enum ArXivSearchField: String, CaseIterable, Identifiable {
    case all = "all"
    case title = "ti"
    case author = "au"
    case abstract = "abs"
    case category = "cat"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All Fields"
        case .title: return "Title"
        case .author: return "Author"
        case .abstract: return "Abstract"
        case .category: return "Category"
        }
    }

    var helpText: String {
        switch self {
        case .all: return "Search across all fields"
        case .title: return "Search in paper titles"
        case .author: return "Search by author name"
        case .abstract: return "Search in abstracts"
        case .category: return "Filter by arXiv category (e.g., cs.LG)"
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
        os_log(.info, "Created arXiv category feed: %{public}@ for category %{public}@", name, category.id)
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
            category.id.lowercased().contains(lowercased) ||
            category.name.lowercased().contains(lowercased) ||
            category.group.lowercased().contains(lowercased)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isNameFieldFocused = true
                }
            }
        }
    }

    private func saveChanges() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != collection.name {
            RustStoreAdapter.shared.renameCollection(id: collection.id, name: trimmed)
        }
        onDismiss?()
        dismiss()
    }
}

// MARK: - Section Reorder Sheet

/// Sheet for reordering sidebar sections.
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
                .onMove(perform: moveSections)
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

    private func moveSections(from source: IndexSet, to destination: Int) {
        sectionOrder.move(fromOffsets: source, toOffset: destination)
        Task { await SidebarSectionOrderStore.shared.save(sectionOrder) }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        IOSSidebarView(selection: .constant(nil))
            .environment(LibraryManager())
            .environment(LibraryViewModel())
    }
}
