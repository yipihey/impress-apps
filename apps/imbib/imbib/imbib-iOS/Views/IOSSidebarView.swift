//
//  IOSSidebarView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import CoreData
import os

/// iOS sidebar with library navigation, smart searches, and collections.
///
/// Adapts the macOS sidebar for iOS with appropriate touch targets and navigation patterns.
struct IOSSidebarView: View {

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(\.themeColors) private var theme

    // MARK: - Bindings

    @Binding var selection: SidebarSection?
    var onNavigateToSmartSearch: ((CDSmartSearch) -> Void)?  // Callback for iPhone navigation

    // MARK: - Observed Objects

    /// Observe SciXLibraryRepository for SciX libraries
    @ObservedObject private var scixRepository = SciXLibraryRepository.shared

    // MARK: - State

    @State private var showNewLibrarySheet = false
    @State private var showNewCollectionSheet = false
    @State private var showArXivCategoryBrowser = false
    @State private var selectedLibraryForAction: CDLibrary?
    @State private var refreshID = UUID()  // Used to force list refresh
    @State private var hasSciXAPIKey = false  // Whether SciX/ADS API key is configured
    @State private var explorationRefreshID = UUID()  // Refresh exploration section
    @State private var explorationMultiSelection: Set<UUID> = []  // Multi-selection for bulk delete
    @State private var isExplorationEditMode = false  // Edit mode for exploration section

    // Inbox feed creation sheets
    @State private var showArXivFeedForInbox = false
    @State private var showGroupFeedForInbox = false

    // Library collection creation
    @State private var showNewCollectionForLibrary: CDLibrary?
    @State private var showSmartCollectionForLibrary: CDLibrary?

    // Section ordering and collapsed state (persisted, synced with macOS)
    @State private var sectionOrder: [SidebarSectionType] = SidebarSectionOrderStore.loadOrderSync()
    @State private var collapsedSections: Set<SidebarSectionType> = SidebarCollapsedStateStore.loadCollapsedSync()

    // Library expansion state (for DisclosureGroups)
    @State private var expandedLibraries: Set<UUID> = []

    // Search form ordering and visibility (persisted)
    @State private var searchFormOrder: [SearchFormType] = SearchFormStore.loadOrderSync()
    @State private var hiddenSearchForms: Set<SearchFormType> = SearchFormStore.loadHiddenSync()

    // MARK: - Body

    var body: some View {
        List(selection: $selection) {
            // All sections in user-defined order, all collapsible and moveable
            ForEach(sectionOrder) { sectionType in
                sectionView(for: sectionType)
                    .id(sectionType == .exploration ? explorationRefreshID : nil)
            }
            .onMove(perform: moveSections)
            .id(refreshID)  // Force refresh when smart searches change
        }
        .listStyle(.sidebar)
        .refreshable {
            // Trigger iCloud sync on pull-to-refresh
            do {
                try await SyncService.shared.triggerSync()
            } catch {
                os_log(.error, "iCloud sync failed: %{public}@", error.localizedDescription)
            }
        }
        // Apply sidebar tint from theme
        .scrollContentBackground(theme.sidebarTint != nil ? .hidden : .automatic)
        .background {
            if let tint = theme.sidebarTint {
                tint.opacity(theme.sidebarTintOpacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
            // Refresh when Core Data saves (new smart search, collection, etc.)
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .explorationLibraryDidChange)) { _ in
            explorationRefreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSmartSearch)) { notification in
            // Navigate to a smart search in the sidebar (from share extension or other source)
            if let searchID = notification.object as? UUID,
               let library = libraryManager.explorationLibrary,
               let searches = library.smartSearches,
               let smartSearch = searches.first(where: { $0.id == searchID }) {
                selection = .smartSearch(smartSearch)
                // For iPhone, also trigger the callback for programmatic navigation
                onNavigateToSmartSearch?(smartSearch)
            }
            // Refresh exploration to show the new/updated search
            explorationRefreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { notification in
            if let collection = notification.userInfo?["collection"] as? CDCollection {
                selection = .collection(collection)
                explorationRefreshID = UUID()
            }
        }
        .task {
            // Auto-expand the first library if none expanded
            if expandedLibraries.isEmpty,
               let firstLibrary = libraryManager.libraries.first(where: { !$0.isInbox }) {
                expandedLibraries.insert(firstLibrary.id)
            }

            // Check for ADS API key (SciX uses ADS API)
            if let _ = await CredentialManager.shared.apiKey(for: "ads") {
                hasSciXAPIKey = true
                scixRepository.loadLibraries()
                // Optionally trigger background refresh
                Task.detached {
                    try? await SciXSyncManager.shared.pullLibraries()
                }
            }
        }
        .navigationTitle("imbib")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Menu {
                        Button {
                            showNewLibrarySheet = true
                        } label: {
                            Label("New Library", systemImage: "folder.badge.plus")
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.newLibraryButton)

                        // Use selected library or default to first non-inbox library
                        if let library = selectedLibraryForAction ?? libraryManager.libraries.first(where: { !$0.isInbox }) {
                            Divider()

                            // Show which library is targeted
                            Section("Add to \(library.displayName)") {
                                Button {
                                    // Navigate to Search section for creating new smart search
                                    NotificationCenter.default.post(name: .navigateToSearchSection, object: library.id)
                                } label: {
                                    Label("New Smart Search", systemImage: "magnifyingglass.circle")
                                }

                                Button {
                                    selectedLibraryForAction = library
                                    showNewCollectionSheet = true
                                } label: {
                                    Label("New Collection", systemImage: "folder")
                                }
                            }
                        }

                        Divider()

                        // arXiv category browser
                        Button {
                            showArXivCategoryBrowser = true
                        } label: {
                            Label("Browse arXiv Categories", systemImage: "list.bullet.rectangle")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }

                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showNewLibrarySheet) {
            NewLibrarySheet(isPresented: $showNewLibrarySheet)
        }
        // Smart search creation/editing now uses Search section forms
        .sheet(isPresented: $showNewCollectionSheet) {
            if let library = selectedLibraryForAction {
                NewCollectionSheet(
                    isPresented: $showNewCollectionSheet,
                    library: library
                )
            }
        }
        .sheet(isPresented: $showArXivCategoryBrowser) {
            IOSArXivCategoryBrowserSheet(
                isPresented: $showArXivCategoryBrowser,
                library: selectedLibraryForAction ?? libraryManager.libraries.first(where: { !$0.isInbox })
            )
        }
        // Inbox feed creation sheets
        .sheet(isPresented: $showArXivFeedForInbox) {
            NavigationStack {
                ArXivFeedFormView(mode: .inboxFeed)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showArXivFeedForInbox = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showGroupFeedForInbox) {
            NavigationStack {
                GroupArXivFeedFormView(mode: .inboxFeed)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showGroupFeedForInbox = false
                            }
                        }
                    }
            }
        }
        .sheet(item: $showNewCollectionForLibrary) { library in
            NewCollectionSheet(
                isPresented: Binding(
                    get: { showNewCollectionForLibrary != nil },
                    set: { if !$0 { showNewCollectionForLibrary = nil } }
                ),
                library: library
            )
        }
        .sheet(item: $showSmartCollectionForLibrary) { library in
            SmartCollectionEditor(
                isPresented: Binding(
                    get: { showSmartCollectionForLibrary != nil },
                    set: { if !$0 { showSmartCollectionForLibrary = nil } }
                )
            ) { name, predicate in
                Task {
                    await createSmartCollection(name: name, predicate: predicate, in: library)
                }
                showSmartCollectionForLibrary = nil
            }
        }
        .onChange(of: selection) { _, newValue in
            // Track which library is selected for contextual actions
            switch newValue {
            case .library(let lib):
                selectedLibraryForAction = lib
            case .smartSearch(let ss):
                selectedLibraryForAction = ss.library
            case .collection(let col):
                selectedLibraryForAction = col.effectiveLibrary
            default:
                break
            }
        }
    }

    // MARK: - Section Views

    /// Returns the appropriate section view for a given section type
    @ViewBuilder
    private func sectionView(for sectionType: SidebarSectionType) -> some View {
        switch sectionType {
        case .inbox:
            collapsibleSection(for: .inbox) {
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
            if let library = libraryManager.explorationLibrary,
               let collections = library.collections,
               !collections.isEmpty {
                collapsibleSection(for: .exploration) {
                    explorationSectionContent
                }
            }
        case .dismissed:
            // Dismissed section (not implemented on iOS yet)
            EmptyView()
        }
    }

    /// Wraps section content in a collapsible Section with standard header
    @ViewBuilder
    private func collapsibleSection<Content: View>(
        for sectionType: SidebarSectionType,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedSections.contains(sectionType)

        Section {
            if !isCollapsed {
                content()
            }
        } header: {
            HStack(spacing: 6) {
                // Collapse/expand button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toggleSectionCollapsed(sectionType)
                    }
                } label: {
                    HStack(spacing: 6) {
                        // Chevron indicator
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))

                        // Section title
                        Text(sectionType.displayName)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Section-specific header extras
                sectionHeaderExtras(for: sectionType)
            }
            .contentShape(Rectangle())
        }
    }

    /// Additional header content for specific section types
    @ViewBuilder
    private func sectionHeaderExtras(for sectionType: SidebarSectionType) -> some View {
        switch sectionType {
        case .inbox:
            // Add feed menu - creates feeds that auto-refresh and populate inbox
            Menu {
                Button {
                    showArXivFeedForInbox = true
                } label: {
                    Label("arXiv Category Feed", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    showGroupFeedForInbox = true
                } label: {
                    Label("arXiv Group Feed", systemImage: "person.3")
                }

                Divider()

                Button {
                    // Navigate to Search section
                    selection = .searchForm(.adsModern)
                } label: {
                    Label("ADS Modern Search", systemImage: "magnifyingglass")
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    /// Toggle collapsed state for a section
    private func toggleSectionCollapsed(_ sectionType: SidebarSectionType) {
        if collapsedSections.contains(sectionType) {
            collapsedSections.remove(sectionType)
        } else {
            collapsedSections.insert(sectionType)
        }
        // Persist
        Task {
            await SidebarCollapsedStateStore.shared.save(collapsedSections)
        }
    }

    /// Handle drag-and-drop reordering of sections
    private func moveSections(from source: IndexSet, to destination: Int) {
        withAnimation {
            sectionOrder.move(fromOffsets: source, toOffset: destination)
        }
        Task {
            await SidebarSectionOrderStore.shared.save(sectionOrder)
        }
    }

    /// Libraries section content (without Section wrapper)
    @ViewBuilder
    private var librariesSectionContent: some View {
        ForEach(libraryManager.libraries.filter { !$0.isInbox }) { library in
            librarySection(for: library)
        }
    }

    /// SciX Libraries section content (without Section wrapper)
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
            .tag(SidebarSection.scixLibrary(library))
            .contextMenu {
                Button {
                    // Open library on SciX/ADS web interface
                    if let url = URL(string: "https://ui.adsabs.harvard.edu/user/libraries/\(library.remoteID)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open on SciX", systemImage: "safari")
                }

                Button {
                    Task {
                        try? await SciXSyncManager.shared.pullLibraryPapers(libraryID: library.remoteID)
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    /// Search section content (without Section wrapper)
    @ViewBuilder
    private var searchSectionContent: some View {
        // Visible search forms in user-defined order
        ForEach(visibleSearchForms) { formType in
            Label(formType.displayName, systemImage: formType.icon)
                .tag(SidebarSection.searchForm(formType))
                .contextMenu {
                    Button("Hide", role: .destructive) {
                        hideSearchForm(formType)
                    }
                }
        }
        .onMove(perform: moveSearchForms)

        // Show hidden forms menu if any are hidden
        if !hiddenSearchForms.isEmpty {
            Menu {
                ForEach(Array(hiddenSearchForms).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { formType in
                    Button("Show \(formType.displayName)") {
                        showSearchForm(formType)
                    }
                }

                Divider()

                Button("Show All") {
                    showAllSearchForms()
                }
            } label: {
                Label("Show Hidden Forms...", systemImage: "eye")
            }
        }
    }

    /// Get visible search forms in order
    private var visibleSearchForms: [SearchFormType] {
        searchFormOrder.filter { !hiddenSearchForms.contains($0) }
    }

    /// Move search forms via drag-and-drop
    private func moveSearchForms(from source: IndexSet, to destination: Int) {
        var visible = visibleSearchForms
        visible.move(fromOffsets: source, toOffset: destination)

        // Rebuild full order preserving hidden forms
        var newOrder: [SearchFormType] = []
        var visibleIndex = 0

        for formType in searchFormOrder {
            if hiddenSearchForms.contains(formType) {
                newOrder.append(formType)
            } else if visibleIndex < visible.count {
                newOrder.append(visible[visibleIndex])
                visibleIndex += 1
            }
        }

        while visibleIndex < visible.count {
            newOrder.append(visible[visibleIndex])
            visibleIndex += 1
        }

        withAnimation {
            searchFormOrder = newOrder
        }

        Task {
            await SearchFormStore.shared.save(newOrder)
        }
    }

    /// Hide a search form
    private func hideSearchForm(_ formType: SearchFormType) {
        withAnimation {
            hiddenSearchForms.insert(formType)
        }
        Task {
            await SearchFormStore.shared.hide(formType)
        }
    }

    /// Show a hidden search form
    private func showSearchForm(_ formType: SearchFormType) {
        withAnimation {
            hiddenSearchForms.remove(formType)
        }
        Task {
            await SearchFormStore.shared.show(formType)
        }
    }

    /// Show all hidden search forms
    private func showAllSearchForms() {
        withAnimation {
            hiddenSearchForms.removeAll()
        }
        Task {
            await SearchFormStore.shared.setHidden([])
        }
    }

    /// Exploration section content (without Section wrapper)
    @ViewBuilder
    private var explorationSectionContent: some View {
        if let library = libraryManager.explorationLibrary,
           let collections = library.collections,
           !collections.isEmpty {
            let flatCollections = flattenedExplorationCollections(from: collections)
            ForEach(flatCollections, id: \.id) { collection in
                explorationCollectionRow(collection, allCollections: flatCollections)
            }
        }
    }

    /// Delete all selected exploration collections
    private func deleteSelectedExplorationCollections() {
        if case .collection(let selected) = selection,
           explorationMultiSelection.contains(selected.id) {
            selection = nil
        }

        if let library = libraryManager.explorationLibrary,
           let collections = library.collections {
            for collection in collections where explorationMultiSelection.contains(collection.id) {
                libraryManager.deleteExplorationCollection(collection)
            }
        }

        explorationMultiSelection.removeAll()
        isExplorationEditMode = false
        explorationRefreshID = UUID()
    }

    /// Flatten collection hierarchy into a list with proper ordering
    /// Determine the SF Symbol icon for an exploration collection based on its name prefix.
    private func explorationIcon(for collection: CDCollection) -> String {
        if collection.name.hasPrefix("Refs:") { return "arrow.down.doc" }
        if collection.name.hasPrefix("Cites:") { return "arrow.up.doc" }
        if collection.name.hasPrefix("Similar:") { return "doc.on.doc" }
        if collection.name.hasPrefix("Co-Reads:") { return "person.2.fill" }
        return "doc.text.magnifyingglass"
    }

    /// Check if this collection is the last child of its parent.
    private func isLastChild(_ collection: CDCollection, in allCollections: [CDCollection]) -> Bool {
        guard let parentID = collection.parentCollection?.id else {
            let rootCollections = allCollections.filter { $0.parentCollection == nil }
            return rootCollections.last?.id == collection.id
        }
        let siblings = allCollections.filter { $0.parentCollection?.id == parentID }
        return siblings.last?.id == collection.id
    }

    /// Check if an ancestor at the given depth level has siblings after it.
    private func hasAncestorSiblingBelow(_ collection: CDCollection, at level: Int, in allCollections: [CDCollection]) -> Bool {
        var current: CDCollection? = collection
        var currentLevel = Int(collection.depth)

        while currentLevel > level, let c = current {
            current = c.parentCollection
            currentLevel -= 1
        }

        guard let ancestor = current else { return false }
        return !isLastChild(ancestor, in: allCollections)
    }

    /// Flatten collection hierarchy into a list with proper ordering
    /// Excludes smart search result collections (they're shown as smart search rows instead)
    private func flattenedExplorationCollections(from collections: Set<CDCollection>) -> [CDCollection] {
        var result: [CDCollection] = []

        func addWithChildren(_ collection: CDCollection) {
            // Skip smart search result collections - they're displayed as smart search rows
            guard !collection.isSmartSearchResults else { return }

            result.append(collection)
            for child in collection.sortedChildren {
                addWithChildren(child)
            }
        }

        // Start with root collections (excluding smart search results)
        for collection in Array(collections)
            .filter({ $0.parentCollection == nil && !$0.isSmartSearchResults })
            .sorted(by: { $0.name < $1.name }) {
            addWithChildren(collection)
        }

        return result
    }

    /// Row for an exploration collection (with tree lines and type-specific icons)
    @ViewBuilder
    private func explorationCollectionRow(_ collection: CDCollection, allCollections: [CDCollection]) -> some View {
        let isSelected = explorationMultiSelection.contains(collection.id)
        let depth = Int(collection.depth)
        let isLast = isLastChild(collection, in: allCollections)

        HStack(spacing: 0) {
            // Checkbox in edit mode
            if isExplorationEditMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .padding(.trailing, 8)
            }

            // Tree lines for each level
            if depth > 0 {
                ForEach(0..<depth, id: \.self) { level in
                    if level == depth - 1 {
                        Text(isLast ? "└" : "├")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .frame(width: 12)
                    } else {
                        if hasAncestorSiblingBelow(collection, at: level, in: allCollections) {
                            Text("│")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .frame(width: 12)
                        } else {
                            Spacer().frame(width: 12)
                        }
                    }
                }
            }

            // Type-specific icon
            Image(systemName: explorationIcon(for: collection))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.trailing, 4)

            // Collection name
            Text(collection.name)
                .lineLimit(1)

            Spacer()

            if collection.matchingPublicationCount > 0 {
                Text("\(collection.matchingPublicationCount)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isExplorationEditMode {
                // Toggle multi-selection in edit mode
                if isSelected {
                    explorationMultiSelection.remove(collection.id)
                } else {
                    explorationMultiSelection.insert(collection.id)
                }
            } else {
                // Normal navigation
                selection = .collection(collection)
            }
        }
        // Only allow List selection when not in edit mode
        .tag(isExplorationEditMode ? nil : SidebarSection.collection(collection))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteExplorationCollection(collection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Delete an exploration collection
    private func deleteExplorationCollection(_ collection: CDCollection) {
        if case .collection(let selected) = selection, selected.id == collection.id {
            selection = nil
        }
        libraryManager.deleteExplorationCollection(collection)
        explorationRefreshID = UUID()
    }

    // MARK: - Inbox Section

    /// Get all smart searches that feed to the Inbox (using Core Data fetch like macOS)
    private var inboxFeeds: [CDSmartSearch] {
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.predicate = NSPredicate(format: "feedsToInbox == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        do {
            return try PersistenceController.shared.viewContext.fetch(request)
        } catch {
            return []
        }
    }

    /// Get unread count for a specific inbox feed
    private func unreadCountForFeed(_ feed: CDSmartSearch) -> Int {
        guard let collection = feed.resultCollection,
              let publications = collection.publications else {
            return 0
        }
        return publications.filter { !$0.isRead && !$0.isDeleted }.count
    }

    /// Inbox section content (without Section wrapper)
    @ViewBuilder
    private var inboxSectionContent: some View {
        // Main Inbox
        HStack {
            Label("Inbox", systemImage: "tray")
            Spacer()
            if InboxManager.shared.unreadCount > 0 {
                Text("\(InboxManager.shared.unreadCount)")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .tag(SidebarSection.inbox)
        .accessibilityIdentifier(AccessibilityID.Sidebar.inbox)

        // Inbox Feeds (Smart Searches that feed to inbox)
        let feeds = inboxFeeds
        if !feeds.isEmpty {
            ForEach(feeds, id: \.id) { feed in
                HStack {
                    Label(feed.name, systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    let unread = unreadCountForFeed(feed)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                .tag(SidebarSection.inboxFeed(feed))
            }
        }
    }

    // MARK: - Library Section

    /// Check if this library is the currently selected one for actions
    private func isLibrarySelected(_ library: CDLibrary) -> Bool {
        selectedLibraryForAction?.id == library.id
    }

    /// Creates a binding for DisclosureGroup expansion state
    private func expansionBinding(for libraryID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedLibraries.contains(libraryID) },
            set: { isExpanded in
                if isExpanded {
                    expandedLibraries.insert(libraryID)
                } else {
                    expandedLibraries.remove(libraryID)
                }
            }
        )
    }

    /// Check if library has any visible children (smart searches or collections).
    /// Used to determine whether to show "All Publications" row - if no children exist,
    /// the row is redundant with the library header itself.
    private func libraryHasChildren(_ library: CDLibrary) -> Bool {
        let hasSmartSearches = library.smartSearches?.contains { !$0.feedsToInbox } ?? false
        let hasCollections = library.collections?.isEmpty == false
        return hasSmartSearches || hasCollections
    }

    /// Whether a library should always show "All Publications" even without children.
    /// Keep and Dismissed libraries need this since they have no children but users
    /// need to navigate to them to see triaged papers.
    private func shouldAlwaysShowAllPublications(_ library: CDLibrary) -> Bool {
        library.isKeepLibrary || library.isDismissedLibrary
    }

    @ViewBuilder
    private func librarySection(for library: CDLibrary) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: library.id)) {
            // All Publications - show if library has children OR is a special library (Keep/Dismissed)
            // that users need to navigate to even without children
            if libraryHasChildren(library) || shouldAlwaysShowAllPublications(library) {
                HStack {
                    Label("All Publications", systemImage: "books.vertical")
                    Spacer()
                    Text("\(allPublications(for: library).count)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .tag(SidebarSection.library(library))
                .accessibilityIdentifier(AccessibilityID.Sidebar.libraryRow(library.id))
            }

            // Smart Searches
            if let searchSet = library.smartSearches?.filter({ !$0.feedsToInbox }), !searchSet.isEmpty {
                DisclosureGroup("Smart Searches") {
                    ForEach(Array(searchSet)) { search in
                        Label(search.name, systemImage: "magnifyingglass.circle")
                            .tag(SidebarSection.smartSearch(search))
                            .contextMenu {
                                Button {
                                    // Navigate to Search section with this smart search's query
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
                                Button(role: .destructive) {
                                    deleteSmartSearch(search)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    // Navigate to Search section with this smart search's query
                                    NotificationCenter.default.post(name: .editSmartSearch, object: search.id)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }

            // Collections
            if let collectionSet = library.collections, !collectionSet.isEmpty {
                DisclosureGroup("Collections") {
                    ForEach(Array(collectionSet)) { collection in
                        HStack {
                            Label(collection.name, systemImage: "folder")
                            Spacer()
                            Text("\(collection.publications?.count ?? 0)")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .tag(SidebarSection.collection(collection))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteCollection(collection)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label(library.displayName, systemImage: "folder")
                if isLibrarySelected(library) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                }

                Spacer()

                // + menu for adding collections to this library
                Menu {
                    Button {
                        showSmartCollectionForLibrary = library
                    } label: {
                        Label("New Smart Collection", systemImage: "folder.badge.gearshape")
                    }

                    Button {
                        showNewCollectionForLibrary = library
                    } label: {
                        Label("New Collection", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Returns all publications for a library, including those from smart search results
    private func allPublications(for library: CDLibrary) -> Set<CDPublication> {
        var allPubs = Set<CDPublication>()

        // Direct library publications
        if let directPubs = library.publications as? Set<CDPublication> {
            allPubs.formUnion(directPubs.filter { !$0.isDeleted })
        }

        // Publications from smart searches
        if let smartSearches = library.smartSearches as? Set<CDSmartSearch> {
            for smartSearch in smartSearches {
                if let collection = smartSearch.resultCollection,
                   let collectionPubs = collection.publications {
                    allPubs.formUnion(collectionPubs.filter { !$0.isDeleted })
                }
            }
        }

        return allPubs
    }

    // MARK: - Actions

    private func deleteSmartSearch(_ search: CDSmartSearch) {
        if case .smartSearch(search) = selection {
            selection = nil
        }
        Task {
            await SmartSearchRepository().delete(search)
        }
    }

    private func deleteCollection(_ collection: CDCollection) {
        if case .collection(collection) = selection {
            selection = nil
        }
        // Delete collection using its managed object context
        if let context = collection.managedObjectContext {
            context.delete(collection)
            try? context.save()
        }
    }

    private func createSmartCollection(name: String, predicate: String, in library: CDLibrary) async {
        // Create collection directly in Core Data
        let context = library.managedObjectContext ?? PersistenceController.shared.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = name
        collection.isSmartCollection = true
        collection.predicate = predicate
        collection.library = library
        try? context.save()

        // Trigger sidebar refresh to show the new collection
        await MainActor.run {
            refreshID = UUID()
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
                    Button("Cancel") {
                        isPresented = false
                    }
                    .accessibilityIdentifier(AccessibilityID.Dialog.Library.cancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createLibrary()
                    }
                    .disabled(name.isEmpty)
                    .accessibilityIdentifier(AccessibilityID.Dialog.Library.createButton)
                }
            }
        }
    }

    private func createLibrary() {
        // Create iCloud library (synced via CloudKit)
        _ = libraryManager.createLibrary(name: name.isEmpty ? "New Library" : name)
        isPresented = false
    }
}

// MARK: - New Collection Sheet

struct NewCollectionSheet: View {
    @Binding var isPresented: Bool
    let library: CDLibrary

    @Environment(LibraryViewModel.self) private var libraryViewModel
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
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createCollection()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }

    private func createCollection() {
        // Create collection directly in Core Data
        guard let context = library.managedObjectContext else {
            isPresented = false
            return
        }

        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = name
        collection.isSmartCollection = false
        collection.library = library

        try? context.save()
        isPresented = false
    }
}

// MARK: - arXiv Search Field Enum

/// Search field options for arXiv queries
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

// NOTE: IOSSmartSearchEditorSheet has been removed.
// Smart search creation/editing now uses the Search section forms.
// See .navigateToSearchSection and .editSmartSearch notifications.

// MARK: - iOS arXiv Category Browser Sheet

/// Sheet wrapper for ArXivCategoryBrowser on iOS.
///
/// Allows users to browse arXiv categories and create feeds to track new papers.
struct IOSArXivCategoryBrowserSheet: View {
    @Binding var isPresented: Bool
    let library: CDLibrary?

    var body: some View {
        NavigationStack {
            ArXivCategoryBrowser(
                onFollow: { category, feedName in
                    createCategoryFeed(category: category, name: feedName)
                },
                onDismiss: {
                    isPresented = false
                }
            )
            .navigationTitle("arXiv Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }

    private func createCategoryFeed(category: ArXivCategory, name: String) {
        guard let library else { return }

        // Create smart search with category query
        let smartSearch = SmartSearchRepository.shared.create(
            name: name,
            query: "cat:\(category.id)",
            sourceIDs: ["arxiv"],
            library: library,
            maxResults: 100
        )

        // Set inbox feed settings
        smartSearch.feedsToInbox = true
        smartSearch.autoRefreshEnabled = true
        smartSearch.refreshIntervalSeconds = 86400  // Daily refresh
        try? smartSearch.managedObjectContext?.save()

        // Log creation
        os_log(.info, "Created arXiv category feed: %{public}@ for category %{public}@",
               smartSearch.name, category.id)

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
        if searchText.isEmpty {
            return ArXivCategories.all
        }
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
                                        Text(category.id)
                                            .font(.headline)
                                        Text(category.name)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if selectedCategory == category.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
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
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
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
