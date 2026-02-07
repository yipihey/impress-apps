//
//  TabContentView.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

import SwiftUI
import PublicationManagerCore
import CoreData
import ImpressFTUI
import ImpressSidebar
import UniformTypeIdentifiers
import OSLog

/// Root view using NavigationSplitView with a List-based sidebar that has
/// collapsible sections. Each sidebar row maps to an `ImbibTab`, and the
/// content area shows the corresponding publication list + detail.
struct TabContentView: View {

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel

    // MARK: - State

    @State private var selectedTab: ImbibTab? = .inbox

    // Orderable items (mutable copies for drag reordering)
    @State private var searchForms: [SearchFormType] = SearchFormStore.loadVisibleFormsSync()
    @State private var hiddenSearchForms: Set<SearchFormType> = SearchFormStore.loadHiddenSync()
    @State private var flagColors: [FlagColor] = FlagColorOrderStore.loadOrderSync()

    // Library management
    @State private var libraryToDelete: CDLibrary?
    @State private var showDeleteConfirmation = false

    // Library + collection expansion state
    @State private var expandedLibraries: Set<UUID> = []
    @State private var expandedLibraryCollections: [UUID: Set<UUID>] = [:]
    @State private var expandedExplorationCollections: Set<UUID> = []
    @State private var explorationRefreshTrigger = UUID()

    // Hover state for + buttons
    @State private var hoveredRow: ImbibTab?
    @State private var isSectionHeaderHovered = false

    // Inline rename state
    @State private var renamingLibraryID: UUID?
    @State private var renamingCollectionID: UUID?
    @State private var renamingName: String = ""
    @FocusState private var isRenamingFocused: Bool

    // Inbox expansion state
    @SceneStorage("tabSidebar.inboxExpanded") private var inboxExpanded = true
    @State private var expandedInboxCollections: Set<UUID> = []

    // Section expansion state
    @SceneStorage("tabSidebar.librariesExpanded") private var librariesExpanded = true
    @SceneStorage("tabSidebar.sharedExpanded") private var sharedExpanded = true
    @SceneStorage("tabSidebar.scixExpanded") private var scixExpanded = true
    @SceneStorage("tabSidebar.searchExpanded") private var searchExpanded = true
    @SceneStorage("tabSidebar.explorationExpanded") private var explorationExpanded = true
    @SceneStorage("tabSidebar.flaggedExpanded") private var flaggedExpanded = true

    // Drop target state
    @State private var dropTargetedLibrary: UUID?
    @State private var dropTargetedCollection: UUID?

    /// SciX library repository for conditional SciX section
    private let scixRepository = SciXLibraryRepository.shared

    // Drag-drop constants and coordinator
    private static let bibtexUTI = "org.tug.tex.bibtex"
    private static let risUTI = "com.clarivate.ris"
    private let dragDropCoordinator = DragDropCoordinator.shared

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            sidebarList
        } detail: {
            contentForSelection
        }
        .task {
            await libraryViewModel.loadPublications()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { notification in
            if let collection = notification.userInfo?["collection"] as? CDCollection {
                expandAncestors(of: collection)
                selectedTab = .explorationCollection(collection.id)
                explorationRefreshTrigger = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .explorationLibraryDidChange)) { _ in
            explorationRefreshTrigger = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSmartSearch)) { notification in
            if let searchID = notification.object as? UUID {
                selectedTab = .exploration(searchID)
                explorationRefreshTrigger = UUID()
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            switch newTab {
            case .explorationCollection(let id):
                // Set exploration context so drill-down creates children of this collection
                if let explorationLib = libraryManager.explorationLibrary,
                   let collection = findExplorationCollection(by: id, in: explorationLib) {
                    ExplorationService.shared.currentExplorationContext = collection
                }
            default:
                ExplorationService.shared.currentExplorationContext = nil
            }
        }
        .alert("Delete Library", isPresented: $showDeleteConfirmation, presenting: libraryToDelete) { library in
            Button("Delete", role: .destructive) {
                try? libraryManager.deleteLibrary(library)
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Are you sure you want to delete \"\(library.displayName)\"? This cannot be undone.")
        }
    }

    // MARK: - Sidebar

    private var sidebarList: some View {
        List(selection: $selectedTab) {
            // Inbox
            Section(isExpanded: $inboxExpanded) {
                // All Inbox row
                Label("All Inbox", systemImage: "tray")
                    .tag(ImbibTab.inbox)
                    .badge(InboxManager.shared.unreadCount)

                // Top-level feeds (no parent collection)
                let topFeeds = inboxFeeds.filter { $0.inboxParentCollection == nil }
                ForEach(topFeeds, id: \.id) { feed in
                    inboxFeedRow(for: feed)
                }

                // Inbox collections with nested feeds
                if let inboxLib = InboxManager.shared.inboxLibrary,
                   let collections = inboxLib.collections as? Set<CDCollection>,
                   !collections.isEmpty {
                    let flatCollections = flattenedInboxCollections(from: collections)
                    let visibleCollections = filterVisibleInboxCollections(flatCollections)

                    ForEach(visibleCollections, id: \.id) { collection in
                        inboxCollectionRow(
                            collection: collection,
                            allCollections: flatCollections,
                            inboxLibrary: inboxLib
                        )
                    }
                }
            } header: {
                Text("Inbox")
            }

            // Libraries
            Section(isExpanded: $librariesExpanded) {
                ForEach(libraryManager.libraries.filter { !$0.isInbox }) { library in
                    // Library header row with optional disclosure triangle
                    libraryHeaderRow(for: library)

                    // Collection tree (when library expanded)
                    if expandedLibraries.contains(library.id) {
                        libraryCollectionsContent(for: library)
                    }
                }
                .onMove { indices, destination in
                    libraryManager.moveLibraries(from: indices, to: destination)
                }
            } header: {
                HStack {
                    Text("Libraries")
                    Spacer()
                    Button { createLibrary() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(isSectionHeaderHovered ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.15), value: isSectionHeaderHovered)
                }
                .onHover { hovering in isSectionHeaderHovered = hovering }
            }

            // Shared With Me (conditional)
            if !libraryManager.sharedWithMeLibraries.isEmpty {
                Section("Shared With Me", isExpanded: $sharedExpanded) {
                    ForEach(libraryManager.sharedWithMeLibraries) { library in
                        Label(library.displayName, systemImage: "person.2")
                            .tag(ImbibTab.sharedLibrary(library.id))
                    }
                }
            }

            // SciX Libraries (conditional)
            if !scixRepository.libraries.isEmpty {
                Section("SciX Libraries", isExpanded: $scixExpanded) {
                    ForEach(scixRepository.libraries) { library in
                        Label(library.name, systemImage: "sparkles")
                            .tag(ImbibTab.scixLibrary(library.id))
                    }
                }
            }

            // Search
            Section("Search", isExpanded: $searchExpanded) {
                ForEach(searchForms) { formType in
                    Label(formType.displayName, systemImage: formType.icon)
                        .tag(ImbibTab.searchForm(formType))
                        .contextMenu {
                            Button("Hide") {
                                withAnimation {
                                    searchForms.removeAll { $0 == formType }
                                    hiddenSearchForms.insert(formType)
                                }
                                Task { await SearchFormStore.shared.hide(formType) }
                            }
                        }
                }
                .onMove { indices, destination in
                    searchForms.move(fromOffsets: indices, toOffset: destination)
                    Task { await SearchFormStore.shared.save(searchForms) }
                }

                // Show hidden forms menu
                if !hiddenSearchForms.isEmpty {
                    Menu {
                        ForEach(Array(hiddenSearchForms).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { formType in
                            Button("Show \(formType.displayName)") {
                                withAnimation {
                                    hiddenSearchForms.remove(formType)
                                    searchForms = SearchFormStore.loadVisibleFormsSync()
                                }
                                Task { await SearchFormStore.shared.show(formType) }
                            }
                        }
                        Divider()
                        Button("Show All") {
                            withAnimation {
                                hiddenSearchForms.removeAll()
                                searchForms = SearchFormStore.loadVisibleFormsSync()
                            }
                            Task { await SearchFormStore.shared.setHidden([]) }
                        }
                    } label: {
                        Label("Show Hidden Forms...", systemImage: "eye")
                    }
                }
            }

            // Exploration (conditional - show when smart searches or collections exist)
            if let explorationLib = libraryManager.explorationLibrary,
               explorationHasContent(explorationLib) {
                Section("Exploration", isExpanded: $explorationExpanded) {
                    // Smart searches
                    ForEach(explorationSmartSearches) { smartSearch in
                        Label(smartSearch.name, systemImage: "lightbulb")
                            .tag(ImbibTab.exploration(smartSearch.id))
                    }

                    // Collection tree
                    explorationCollectionTree(for: explorationLib)
                }
                .id(explorationRefreshTrigger)
            }

            // Flagged
            Section("Flagged", isExpanded: $flaggedExpanded) {
                Label("Any Flag", systemImage: "flag.fill")
                    .tag(ImbibTab.flagged(nil))

                ForEach(flagColors) { color in
                    Label {
                        Text(color.displayName)
                    } icon: {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(color.defaultLightColor)
                    }
                    .tag(ImbibTab.flagged(color.rawValue))
                }
                .onMove { indices, destination in
                    flagColors.move(fromOffsets: indices, toOffset: destination)
                    Task { await FlagColorOrderStore.shared.save(flagColors) }
                }
            }

            // Dismissed (conditional)
            if let dismissedLib = libraryManager.dismissedLibrary,
               let pubs = dismissedLib.publications, !pubs.isEmpty {
                Label("Dismissed", systemImage: "xmark.circle")
                    .tag(ImbibTab.dismissed)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("imbib")
        // Sidebar-wide catch-all: .bib/.ris dropped on empty space → create new library
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            if hasBibTeXOrRISDrops(providers) {
                handleBibTeXDropForNewLibrary(providers)
                return true
            }
            return false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentForSelection: some View {
        switch selectedTab {
        case .inbox:
            if let inboxLibrary = InboxManager.shared.inboxLibrary {
                SectionContentView(
                    source: .library(inboxLibrary),
                    libraryID: inboxLibrary.id
                )
            } else {
                ContentUnavailableView(
                    "Inbox Empty",
                    systemImage: "tray",
                    description: Text("Add feeds to start discovering papers")
                )
            }

        case .inboxFeed(let id):
            if let feed = inboxFeeds.first(where: { $0.id == id }) {
                SectionContentView(
                    source: .smartSearch(feed),
                    libraryID: InboxManager.shared.inboxLibrary?.id
                )
            }

        case .inboxCollection(let id):
            if let inboxLib = InboxManager.shared.inboxLibrary,
               let collection = findInboxCollection(by: id, in: inboxLib) {
                SectionContentView(
                    source: .collection(collection),
                    libraryID: inboxLib.id
                )
            }

        case .library(let id):
            if let library = libraryManager.libraries.first(where: { $0.id == id }) {
                SectionContentView(
                    source: .library(library),
                    libraryID: library.id
                )
            }

        case .sharedLibrary(let id):
            if let library = libraryManager.sharedWithMeLibraries.first(where: { $0.id == id }) {
                SectionContentView(
                    source: .library(library),
                    libraryID: library.id
                )
            }

        case .scixLibrary(let id):
            if let library = scixRepository.libraries.first(where: { $0.id == id }) {
                SciXLibraryTabContent(library: library)
            }

        case .searchForm(let formType):
            SearchTabContent(formType: formType)

        case .exploration(let id):
            if let explorationLib = libraryManager.explorationLibrary,
               let search = explorationLib.smartSearches?.first(where: { $0.id == id }) {
                SectionContentView(
                    source: .smartSearch(search),
                    libraryID: explorationLib.id
                )
            }

        case .collection(let id):
            if let collection = findCollection(by: id) {
                SectionContentView(
                    source: .collection(collection),
                    libraryID: collection.effectiveLibrary?.id
                )
            }

        case .explorationCollection(let id):
            if let explorationLib = libraryManager.explorationLibrary,
               let collection = findExplorationCollection(by: id, in: explorationLib) {
                SectionContentView(
                    source: .collection(collection),
                    libraryID: explorationLib.id
                )
            }

        case .flagged(let colorRawValue):
            SectionContentView(
                source: .flagged(colorRawValue),
                libraryID: nil
            )

        case .dismissed:
            if let dismissedLib = libraryManager.dismissedLibrary {
                SectionContentView(
                    source: .library(dismissedLib),
                    libraryID: dismissedLib.id
                )
            }

        case nil:
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.left",
                description: Text("Select an item from the sidebar")
            )
        }
    }

    // MARK: - Library Header Row

    @ViewBuilder
    private func libraryHeaderRow(for library: CDLibrary) -> some View {
        let hasCollections = libraryHasCollections(library)
        let isExpanded = expandedLibraries.contains(library.id)

        HStack(spacing: 4) {
            // Disclosure triangle (only if library has collections)
            if hasCollections {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedLibraries.remove(library.id)
                        } else {
                            expandedLibraries.insert(library.id)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)

            if renamingLibraryID == library.id {
                TextField("Name", text: $renamingName)
                    .textFieldStyle(.plain)
                    .focused($isRenamingFocused)
                    .onSubmit { commitLibraryRename(library) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(library.displayName)
            }

            Spacer()

            Button { createCollection(in: library) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hoveredRow == .library(library.id) ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: hoveredRow)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRow = hovering ? .library(library.id) : nil
        }
        .tag(ImbibTab.library(library.id))
        .contextMenu {
            Button {
                startRenamingLibrary(library)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                createCollection(in: library)
            } label: {
                Label("New Collection", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: .showUnifiedExport,
                    object: nil,
                    userInfo: ["library": library]
                )
            } label: {
                Label("Export...", systemImage: "square.and.arrow.up.on.square")
            }

            Button {
                NotificationCenter.default.post(
                    name: .showUnifiedImport,
                    object: nil,
                    userInfo: ["library": library]
                )
            } label: {
                Label("Import...", systemImage: "square.and.arrow.down")
            }

            Divider()

            Button("Delete Library", role: .destructive) {
                libraryToDelete = library
                showDeleteConfirmation = true
            }
        }
        .onDrop(of: DragDropCoordinator.acceptedTypes + [.publicationID], isTargeted: makeLibraryDropBinding(library.id)) { providers in
            // BibTeX/RIS files → import preview
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(Self.bibtexUTI) }) ||
               providers.contains(where: { $0.hasItemConformingToTypeIdentifier(Self.risUTI) }) {
                handleBibTeXDrop(providers, library: library)
            } else if hasFileDrops(providers) || hasURLDrops(providers) {
                handleFileDrop(providers, libraryID: library.id)
            } else {
                handlePublicationDrop(providers: providers) { uuids in
                    Task { await addPublicationsToLibrary(uuids, library: library) }
                }
            }
            return true
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(dropTargetedLibrary == library.id ? Color.accentColor.opacity(0.15) : .clear)
        )
    }

    /// Library collections content (rendered when library is expanded)
    @ViewBuilder
    private func libraryCollectionsContent(for library: CDLibrary) -> some View {
        if let collections = library.collections as? Set<CDCollection>, !collections.isEmpty {
            let flatCollections = flattenedLibraryCollections(from: collections, libraryID: library.id)
            let visibleCollections = filterVisibleLibraryCollections(flatCollections, libraryID: library.id)

            ForEach(visibleCollections, id: \.id) { collection in
                libraryCollectionRow(
                    collection: collection,
                    allCollections: flatCollections,
                    library: library
                )
            }
        }
    }

    // MARK: - Collection Helpers

    /// Find a collection by ID across all regular libraries
    private func findCollection(by id: UUID) -> CDCollection? {
        for library in libraryManager.libraries {
            if let collections = library.collections as? Set<CDCollection>,
               let match = collections.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    /// Find a collection by ID in the exploration library (recursive through children)
    private func findExplorationCollection(by id: UUID, in library: CDLibrary) -> CDCollection? {
        guard let collections = library.collections as? Set<CDCollection> else { return nil }

        func findRecursive(in cols: Set<CDCollection>) -> CDCollection? {
            for col in cols {
                if col.id == id { return col }
                if let children = col.childCollections, !children.isEmpty {
                    if let found = findRecursive(in: children) { return found }
                }
            }
            return nil
        }

        return findRecursive(in: collections)
    }

    /// Expand all ancestors of a collection so it's visible in the exploration tree
    private func expandAncestors(of collection: CDCollection) {
        for ancestor in collection.ancestors {
            expandedExplorationCollections.insert(ancestor.id)
        }
    }

    // MARK: - Inbox Feeds & Collections

    /// Get all smart searches that feed to the Inbox
    private var inboxFeeds: [CDSmartSearch] {
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.predicate = NSPredicate(format: "feedsToInbox == YES")
        request.sortDescriptors = [
            NSSortDescriptor(key: "order", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]
        return (try? PersistenceController.shared.viewContext.fetch(request)) ?? []
    }

    /// Get unread count for a specific inbox feed
    private func unreadCountForFeed(_ feed: CDSmartSearch) -> Int {
        guard let collection = feed.resultCollection,
              let publications = collection.publications else { return 0 }
        return publications.filter { !$0.isRead && !$0.isDeleted }.count
    }

    /// Row for an inbox feed (smart search with feedsToInbox)
    @ViewBuilder
    private func inboxFeedRow(for feed: CDSmartSearch) -> some View {
        HStack {
            Label(feed.name, systemImage: "antenna.radiowaves.left.and.right")
            Spacer()
            let unreadCount = unreadCountForFeed(feed)
            if unreadCount > 0 {
                CountBadge(count: unreadCount, color: .accentColor)
            }
        }
        .tag(ImbibTab.inboxFeed(feed.id))
    }

    /// Row for an inbox collection (folder) with expand/collapse and nested feeds
    @ViewBuilder
    private func inboxCollectionRow(
        collection: CDCollection,
        allCollections: [CDCollection],
        inboxLibrary: CDLibrary
    ) -> some View {
        let isExpanded = expandedInboxCollections.contains(collection.id)
        let nestedFeeds = inboxFeeds.filter { $0.inboxParentCollection?.id == collection.id }
        let hasContent = collection.hasChildren || !nestedFeeds.isEmpty

        HStack(spacing: 0) {
            // Tree indentation with lines
            ForEach(0..<collection.depth, id: \.self) { level in
                treeLineForInboxCollection(collection, at: level, in: allCollections)
            }

            // Disclosure triangle
            if hasContent {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedInboxCollections.remove(collection.id)
                        } else {
                            expandedInboxCollections.insert(collection.id)
                        }
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

            // Icon
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.leading, 2)

            // Name (editable when renaming)
            if renamingCollectionID == collection.id {
                TextField("Name", text: $renamingName)
                    .textFieldStyle(.plain)
                    .padding(.leading, 4)
                    .focused($isRenamingFocused)
                    .onSubmit { commitCollectionRename(collection) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
            }

            Spacer()

            // Count badge
            let count = collection.matchingPublicationCount
            if count > 0 {
                CountBadge(count: count)
            }

            // Hover-revealed + button for subcollections
            Button { createInboxCollection(parent: collection) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hoveredRow == .inboxCollection(collection.id) ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: hoveredRow)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRow = hovering ? .inboxCollection(collection.id) : nil
        }
        .tag(ImbibTab.inboxCollection(collection.id))
        .contextMenu {
            Button {
                startRenamingCollection(collection)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                createInboxCollection(parent: collection)
            } label: {
                Label("New Subcollection", systemImage: "folder.badge.plus")
            }
        }
        .padding(.leading, 16)

        // Show nested feeds when expanded
        if isExpanded {
            ForEach(nestedFeeds, id: \.id) { feed in
                HStack {
                    Label(feed.name, systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    let unreadCount = unreadCountForFeed(feed)
                    if unreadCount > 0 {
                        CountBadge(count: unreadCount, color: .accentColor)
                    }
                }
                .tag(ImbibTab.inboxFeed(feed.id))
                .padding(.leading, CGFloat(collection.depth + 1) * 16 + 28)
            }
        }
    }

    /// Tree line for inbox collection at a specific indentation level
    @ViewBuilder
    private func treeLineForInboxCollection(_ collection: CDCollection, at level: Int, in allCollections: [CDCollection]) -> some View {
        let ancestors = collection.ancestors
        if level == collection.depth - 1 {
            let isLastChild = isLastInboxChildAtLevel(collection, in: allCollections)
            TreeLineView(
                level: level,
                depth: collection.depth,
                isLastChild: isLastChild,
                hasAncestorSiblingBelow: false
            )
        } else if level < ancestors.count {
            let ancestor = ancestors[level]
            let hasSiblingsBelow = !isLastInboxChildAtLevel(ancestor, in: allCollections)
            TreeLineView(
                level: level,
                depth: collection.depth,
                isLastChild: false,
                hasAncestorSiblingBelow: hasSiblingsBelow
            )
        } else {
            Spacer().frame(width: 16)
        }
    }

    /// Check if inbox collection is the last child among its siblings
    private func isLastInboxChildAtLevel(_ collection: CDCollection, in allCollections: [CDCollection]) -> Bool {
        if let parent = collection.parentCollection {
            let siblings = parent.sortedChildren
            return siblings.last?.id == collection.id
        } else {
            let roots = allCollections.filter { $0.parentCollection == nil }
            return roots.last?.id == collection.id
        }
    }

    /// Flatten inbox collections into ordered list respecting hierarchy
    private func flattenedInboxCollections(from collections: Set<CDCollection>) -> [CDCollection] {
        var result: [CDCollection] = []

        func addWithChildren(_ collection: CDCollection) {
            result.append(collection)
            for child in collection.sortedChildren {
                addWithChildren(child)
            }
        }

        let rootCollections = Array(collections)
            .filter { $0.parentCollection == nil }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name < $1.name
            }

        for collection in rootCollections {
            addWithChildren(collection)
        }

        return result
    }

    /// Filter to only visible inbox collections (ancestors expanded)
    private func filterVisibleInboxCollections(_ collections: [CDCollection]) -> [CDCollection] {
        collections.filter { collection in
            guard collection.parentCollection != nil else { return true }
            for ancestor in collection.ancestors {
                if !expandedInboxCollections.contains(ancestor.id) {
                    return false
                }
            }
            return true
        }
    }

    /// Find a collection by ID in the inbox library (recursive through children)
    private func findInboxCollection(by id: UUID, in library: CDLibrary) -> CDCollection? {
        guard let collections = library.collections as? Set<CDCollection> else { return nil }

        func findRecursive(in cols: Set<CDCollection>) -> CDCollection? {
            for col in cols {
                if col.id == id { return col }
                if let children = col.childCollections, !children.isEmpty {
                    if let found = findRecursive(in: children) { return found }
                }
            }
            return nil
        }

        return findRecursive(in: collections)
    }

    /// Create a new collection in the inbox library
    private func createInboxCollection(parent: CDCollection? = nil) {
        guard let inboxLib = InboxManager.shared.inboxLibrary else { return }
        let context = inboxLib.managedObjectContext ?? PersistenceController.shared.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = parent != nil ? "New Subcollection" : "New Collection"
        collection.isSmartCollection = false
        collection.library = inboxLib
        collection.parentCollection = parent
        try? context.save()

        // Expand parent so child is visible
        if let parent = parent {
            expandedInboxCollections.insert(parent.id)
        }

        // Auto-enter rename mode
        cancelRename()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renamingName = collection.name
            renamingCollectionID = collection.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isRenamingFocused = true
        }
    }

    // MARK: - Library Collection Tree Helpers

    /// Flatten library collections into ordered list respecting hierarchy
    private func flattenedLibraryCollections(from collections: Set<CDCollection>, libraryID: UUID) -> [CDCollection] {
        var result: [CDCollection] = []

        func addWithChildren(_ collection: CDCollection) {
            result.append(collection)
            for child in collection.sortedChildren {
                addWithChildren(child)
            }
        }

        let rootCollections = Array(collections)
            .filter { $0.parentCollection == nil }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name < $1.name
            }

        for collection in rootCollections {
            addWithChildren(collection)
        }

        return result
    }

    /// Filter to only visible collections (ancestors expanded)
    private func filterVisibleLibraryCollections(_ collections: [CDCollection], libraryID: UUID) -> [CDCollection] {
        let expandedSet = expandedLibraryCollections[libraryID] ?? []
        return collections.filter { collection in
            guard collection.parentCollection != nil else { return true }
            for ancestor in collection.ancestors {
                if !expandedSet.contains(ancestor.id) {
                    return false
                }
            }
            return true
        }
    }

    /// Check if library has any collections
    private func libraryHasCollections(_ library: CDLibrary) -> Bool {
        (library.collections as? Set<CDCollection>)?.isEmpty == false
    }

    // MARK: - Library Collection Row

    @ViewBuilder
    private func libraryCollectionRow(
        collection: CDCollection,
        allCollections: [CDCollection],
        library: CDLibrary
    ) -> some View {
        let expandedSet = expandedLibraryCollections[library.id] ?? []
        let isExpanded = expandedSet.contains(collection.id)

        HStack(spacing: 0) {
            // Tree indentation with lines
            ForEach(0..<collection.depth, id: \.self) { level in
                treeLineForCollection(collection, at: level, in: allCollections)
            }

            // Disclosure triangle
            if collection.hasChildren {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedLibraryCollections[library.id, default: []].remove(collection.id)
                        } else {
                            expandedLibraryCollections[library.id, default: []].insert(collection.id)
                        }
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

            // Icon
            Image(systemName: collection.isSmartCollection ? "folder.badge.gearshape" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.leading, 2)

            // Name
            if renamingCollectionID == collection.id {
                TextField("Name", text: $renamingName)
                    .textFieldStyle(.plain)
                    .padding(.leading, 4)
                    .focused($isRenamingFocused)
                    .onSubmit { commitCollectionRename(collection) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
            }

            Spacer()

            // Count badge
            let count = collection.matchingPublicationCount
            if count > 0 {
                CountBadge(count: count)
            }

            // Hover-revealed + button (non-smart collections only)
            if !collection.isSmartCollection {
                Button { createCollection(in: library, parent: collection) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(hoveredRow == .collection(collection.id) ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: hoveredRow)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRow = hovering ? .collection(collection.id) : nil
        }
        .tag(ImbibTab.collection(collection.id))
        .contextMenu {
            if !collection.isSmartCollection {
                Button {
                    startRenamingCollection(collection)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    createCollection(in: library, parent: collection)
                } label: {
                    Label("New Subcollection", systemImage: "folder.badge.plus")
                }
            }
        }
        .onDrop(of: DragDropCoordinator.acceptedTypes + [.publicationID], isTargeted: makeCollectionDropBinding(collection.id)) { providers in
            guard !collection.isSmartCollection else { return false }
            let libraryID = collection.effectiveLibrary?.id ?? collection.library?.id ?? UUID()
            let targetLibrary = libraryManager.libraries.first(where: { $0.id == libraryID })

            // BibTeX/RIS files → import preview (same as library header, with collection target)
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(Self.bibtexUTI) }) ||
               providers.contains(where: { $0.hasItemConformingToTypeIdentifier(Self.risUTI) }) {
                if let targetLibrary {
                    handleBibTeXDrop(providers, library: targetLibrary, collection: collection)
                }
            } else if hasFileDrops(providers) || hasURLDrops(providers) {
                handleFileDropOnCollection(providers, collectionID: collection.id, libraryID: libraryID)
            } else {
                handlePublicationDrop(providers: providers) { uuids in
                    Task { await addPublications(uuids, to: collection) }
                }
            }
            return true
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(dropTargetedCollection == collection.id ? Color.accentColor.opacity(0.15) : .clear)
        )
        .padding(.leading, 16)
    }

    /// Renders tree line for a collection at a specific indentation level
    @ViewBuilder
    private func treeLineForCollection(_ collection: CDCollection, at level: Int, in allCollections: [CDCollection]) -> some View {
        let ancestors = collection.ancestors
        if level == collection.depth - 1 {
            let isLastChild = isLastChildAtLevel(collection, in: allCollections)
            TreeLineView(
                level: level,
                depth: collection.depth,
                isLastChild: isLastChild,
                hasAncestorSiblingBelow: false
            )
        } else if level < ancestors.count {
            let ancestor = ancestors[level]
            let hasSiblingsBelow = !isLastChildAtLevel(ancestor, in: allCollections)
            TreeLineView(
                level: level,
                depth: collection.depth,
                isLastChild: false,
                hasAncestorSiblingBelow: hasSiblingsBelow
            )
        } else {
            Spacer().frame(width: 16)
        }
    }

    /// Checks if a collection is the last child among its siblings
    private func isLastChildAtLevel(_ collection: CDCollection, in allCollections: [CDCollection]) -> Bool {
        if let parent = collection.parentCollection {
            let siblings = parent.sortedChildren
            return siblings.last?.id == collection.id
        } else {
            let roots = allCollections.filter { $0.parentCollection == nil }
            return roots.last?.id == collection.id
        }
    }

    // MARK: - Creation Helpers

    private func createLibrary() {
        let library = libraryManager.createLibrary(name: "New Library")
        // Auto-enter rename mode
        cancelRename()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renamingName = library.name
            renamingLibraryID = library.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isRenamingFocused = true
        }
    }

    private func createCollection(in library: CDLibrary, parent: CDCollection? = nil) {
        let context = library.managedObjectContext ?? PersistenceController.shared.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = parent != nil ? "New Subcollection" : "New Collection"
        collection.isSmartCollection = false
        collection.library = library
        collection.parentCollection = parent
        try? context.save()

        // Expand parent collection so child is visible
        if let parent = parent {
            expandedLibraryCollections[library.id, default: []].insert(parent.id)
        }
        // Expand library so collection tree is visible
        expandedLibraries.insert(library.id)

        // Auto-enter rename mode
        cancelRename()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renamingName = collection.name
            renamingCollectionID = collection.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isRenamingFocused = true
        }
    }

    // MARK: - Rename Helpers

    private func startRenamingLibrary(_ library: CDLibrary) {
        cancelRename()
        renamingName = library.name
        renamingLibraryID = library.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isRenamingFocused = true
        }
    }

    private func startRenamingCollection(_ collection: CDCollection) {
        cancelRename()
        renamingName = collection.name
        renamingCollectionID = collection.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isRenamingFocused = true
        }
    }

    private func commitLibraryRename(_ library: CDLibrary) {
        isRenamingFocused = false
        let newName = renamingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty {
            libraryManager.rename(library, to: newName)
        }
        renamingLibraryID = nil
    }

    private func commitCollectionRename(_ collection: CDCollection) {
        isRenamingFocused = false
        let newName = renamingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty {
            collection.name = newName
            try? collection.managedObjectContext?.save()
        }
        renamingCollectionID = nil
    }

    private func cancelRename() {
        isRenamingFocused = false
        renamingLibraryID = nil
        renamingCollectionID = nil
    }

    // MARK: - Exploration Collection Tree Helpers

    /// Check if exploration library has any content (smart searches or collections)
    private func explorationHasContent(_ library: CDLibrary) -> Bool {
        let hasSearches = library.smartSearches?.isEmpty == false
        let hasCollections: Bool
        if let collections = library.collections as? Set<CDCollection> {
            hasCollections = collections.contains { !$0.isSmartSearchResults }
        } else {
            hasCollections = false
        }
        return hasSearches || hasCollections
    }

    /// Exploration collection tree view
    @ViewBuilder
    private func explorationCollectionTree(for library: CDLibrary) -> some View {
        if let collections = library.collections as? Set<CDCollection>,
           !collections.isEmpty {
            let allCollections = flattenedExplorationCollections(from: collections)
            let rootAdapters = explorationRootCollections(from: collections)
                .map { ExplorationCollectionAdapter(collection: $0, allCollections: allCollections) }

            if !rootAdapters.isEmpty {
                // Divider between smart searches and collections
                if !explorationSmartSearches.isEmpty {
                    Divider()
                        .padding(.vertical, 4)
                }

                let flattenedNodes = rootAdapters.flattened(
                    children: { adapter in
                        adapter.collection.sortedChildren
                            .filter { !$0.isSmartSearchResults }
                            .map { ExplorationCollectionAdapter(collection: $0, allCollections: allCollections) }
                    },
                    isExpanded: { expandedExplorationCollections.contains($0.id) }
                )

                ForEach(flattenedNodes) { flattenedNode in
                    let collection = flattenedNode.node.collection

                    GenericTreeRow(
                        flattenedNode: flattenedNode,
                        capabilities: .explorationCollection,
                        isExpanded: Binding(
                            get: { expandedExplorationCollections.contains(collection.id) },
                            set: { isExpanded in
                                if isExpanded {
                                    expandedExplorationCollections.insert(collection.id)
                                } else {
                                    expandedExplorationCollections.remove(collection.id)
                                }
                            }
                        )
                    )
                    .tag(ImbibTab.explorationCollection(collection.id))
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            deleteExplorationCollection(collection)
                        }
                    }
                }
            }
        }
    }

    /// Get smart searches for the exploration library
    private var explorationSmartSearches: [CDSmartSearch] {
        guard let library = libraryManager.explorationLibrary,
              let searches = library.smartSearches else { return [] }
        return Array(searches).sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.dateCreated > $1.dateCreated
        }
    }

    /// Get root collections for exploration (excluding smart search results)
    private func explorationRootCollections(from collections: Set<CDCollection>) -> [CDCollection] {
        Array(collections)
            .filter { $0.parentCollection == nil && !$0.isSmartSearchResults }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.name < $1.name
            }
    }

    /// Flatten exploration collection hierarchy (excluding smart search results)
    private func flattenedExplorationCollections(from collections: Set<CDCollection>) -> [CDCollection] {
        var result: [CDCollection] = []

        func addWithChildren(_ collection: CDCollection) {
            guard !collection.isSmartSearchResults else { return }
            result.append(collection)
            for child in collection.sortedChildren {
                addWithChildren(child)
            }
        }

        let rootCollections = explorationRootCollections(from: collections)
        for collection in rootCollections {
            addWithChildren(collection)
        }

        return result
    }

    /// Delete an exploration collection
    private func deleteExplorationCollection(_ collection: CDCollection) {
        if case .explorationCollection(let id) = selectedTab, id == collection.id {
            selectedTab = nil
        }
        libraryManager.deleteExplorationCollection(collection)
        explorationRefreshTrigger = UUID()
    }

    // MARK: - Drag & Drop Helpers

    private static let dropLogger = Logger(subsystem: "com.imbib.app", category: "tabsidebar-dragdrop")

    /// Check if providers contain file drops (PDF, .bib, .ris)
    private func hasFileDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ||
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) ||
            provider.hasItemConformingToTypeIdentifier(Self.risUTI)
        }
    }

    /// Check if providers contain web URL drops (from browser address bar)
    private func hasURLDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
            !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
    }

    /// Check if providers contain BibTeX or RIS drops (by UTI or file URL extension)
    private func hasBibTeXOrRISDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) ||
            provider.hasItemConformingToTypeIdentifier(Self.risUTI) ||
            provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier)
        }
    }

    /// Handle BibTeX/RIS drops with no target library — posts notification without library to trigger "create new library" flow
    private func handleBibTeXDropForNewLibrary(_ providers: [NSItemProvider]) {
        Self.dropLogger.info("Routing to BibTeX import handler (new library)")

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) {
                provider.loadItem(forTypeIdentifier: Self.bibtexUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    }
                }
                return
            }

            if provider.hasItemConformingToTypeIdentifier(Self.risUTI) {
                provider.loadItem(forTypeIdentifier: Self.risUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    }
                }
                return
            }

            // Fall back to generic file URL — check extension
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    let ext = url.pathExtension.lowercased()
                    if ext == "bib" || ext == "bibtex" || ext == "ris" {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    }
                }
                return
            }
        }
    }

    /// Handle BibTeX/RIS file drops — opens import preview with target library pre-selected
    private func handleBibTeXDrop(_ providers: [NSItemProvider], library: CDLibrary, collection: CDCollection? = nil) {
        Self.dropLogger.info("Routing to BibTeX import handler\(collection != nil ? " (collection: \(collection!.name))" : "")")

        /// Build userInfo with library and optional collection
        func makeUserInfo(fileURL: URL) -> [String: Any] {
            var info: [String: Any] = ["fileURL": fileURL, "library": library]
            if let collection { info["collection"] = collection }
            return info
        }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) {
                provider.loadItem(forTypeIdentifier: Self.bibtexUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .importBibTeXToLibrary, object: nil, userInfo: makeUserInfo(fileURL: url))
                        }
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .importBibTeXToLibrary, object: nil, userInfo: makeUserInfo(fileURL: url))
                        }
                    }
                }
                return
            }

            if provider.hasItemConformingToTypeIdentifier(Self.risUTI) {
                provider.loadItem(forTypeIdentifier: Self.risUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .importBibTeXToLibrary, object: nil, userInfo: makeUserInfo(fileURL: url))
                        }
                    }
                }
                return
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    let ext = url.pathExtension.lowercased()
                    if ext == "bib" || ext == "bibtex" || ext == "ris" {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .importBibTeXToLibrary, object: nil, userInfo: makeUserInfo(fileURL: url))
                        }
                    }
                }
                return
            }
        }
    }

    /// Handle file drops on a library target
    private func handleFileDrop(_ providers: [NSItemProvider], libraryID: UUID) {
        let info = DragDropInfo(providers: providers)
        let target = DropTarget.library(libraryID: libraryID)
        Task {
            _ = await dragDropCoordinator.performDrop(info, target: target)
        }
    }

    /// Handle file drops on a collection target
    private func handleFileDropOnCollection(_ providers: [NSItemProvider], collectionID: UUID, libraryID: UUID) {
        let info = DragDropInfo(providers: providers)
        let target = DropTarget.collection(collectionID: collectionID, libraryID: libraryID)
        Task {
            _ = await dragDropCoordinator.performDrop(info, target: target)
        }
    }

    /// Handle publication UUID drops — decodes UUIDs from drag providers and calls action
    private func handlePublicationDrop(providers: [NSItemProvider], action: @escaping ([UUID]) -> Void) {
        var collectedUUIDs: [UUID] = []
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.publicationID.identifier) { data, error in
                    defer { group.leave() }
                    guard let data else { return }

                    // Try JSON array first (multi-selection format)
                    if let uuidStrings = try? JSONDecoder().decode([String].self, from: data) {
                        for idString in uuidStrings {
                            if let uuid = UUID(uuidString: idString) {
                                collectedUUIDs.append(uuid)
                            }
                        }
                    }
                    // Fallback: single UUID
                    else if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                        collectedUUIDs.append(uuid)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !collectedUUIDs.isEmpty {
                action(collectedUUIDs)
            }
        }
    }

    /// Add publications to a library
    private func addPublicationsToLibrary(_ uuids: [UUID], library: CDLibrary) async {
        let context = PersistenceController.shared.viewContext

        await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id IN %@", uuids)

            guard let publications = try? context.fetch(request) else { return }

            for publication in publications {
                publication.addToLibrary(library)
            }

            try? context.save()
        }
    }

    /// Add publications to a static collection
    private func addPublications(_ uuids: [UUID], to collection: CDCollection) async {
        guard !collection.isSmartCollection else { return }
        let context = PersistenceController.shared.viewContext

        await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id IN %@", uuids)

            guard let publications = try? context.fetch(request) else { return }

            var current = collection.publications ?? []
            let collectionLibrary = collection.effectiveLibrary

            for publication in publications {
                current.insert(publication)
                if let library = collectionLibrary {
                    publication.addToLibrary(library)
                }
            }
            collection.publications = current

            try? context.save()
        }
    }

    /// Create a binding for library drop targeting
    private func makeLibraryDropBinding(_ libraryID: UUID) -> Binding<Bool> {
        Binding(
            get: { dropTargetedLibrary == libraryID },
            set: { isTargeted in
                dropTargetedLibrary = isTargeted ? libraryID : nil
                // Auto-expand library after hovering for a moment
                if isTargeted && !expandedLibraries.contains(libraryID) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if dropTargetedLibrary == libraryID {
                            expandedLibraries.insert(libraryID)
                        }
                    }
                }
            }
        )
    }

    /// Create a binding for collection drop targeting
    private func makeCollectionDropBinding(_ collectionID: UUID) -> Binding<Bool> {
        Binding(
            get: { dropTargetedCollection == collectionID },
            set: { isTargeted in
                dropTargetedCollection = isTargeted ? collectionID : nil
            }
        )
    }
}

// MARK: - SciX Library Tab Content

/// Wrapper for SciX library content within a tab.
/// SciX uses its own list view instead of UnifiedPublicationListWrapper.
private struct SciXLibraryTabContent: View {
    let library: CDSciXLibrary

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @State private var selectedPublicationIDs = Set<UUID>()
    @State private var displayedPublicationID: UUID?
    @State private var selectedDetailTab: DetailTab = .info

    private var selectedPublicationBinding: Binding<CDPublication?> {
        Binding(
            get: {
                guard let id = selectedPublicationIDs.first else { return nil }
                return libraryViewModel.publication(for: id)
            },
            set: { newPublication in
                let newID = newPublication?.id
                if let id = newID {
                    if !selectedPublicationIDs.contains(id) {
                        selectedPublicationIDs = [id]
                    }
                } else {
                    selectedPublicationIDs.removeAll()
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    displayedPublicationID = newID
                }
            }
        )
    }

    private var displayedPublication: CDPublication? {
        guard let id = displayedPublicationID else { return nil }
        return libraryViewModel.publication(for: id)
    }

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                SciXLibraryListView(
                    library: library,
                    selection: selectedPublicationBinding,
                    multiSelection: $selectedPublicationIDs
                )
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 450)

                Group {
                    if let publication = displayedPublication,
                       !publication.isDeleted,
                       publication.managedObjectContext != nil,
                       let detail = DetailView(
                           publication: publication,
                           libraryID: library.id,
                           selectedTab: $selectedDetailTab
                       ) {
                        detail
                    } else {
                        ContentUnavailableView(
                            "No Selection",
                            systemImage: "doc.text",
                            description: Text("Select a publication to view details")
                        )
                    }
                }
                .frame(minWidth: 300, idealWidth: 500)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
