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
import UniformTypeIdentifiers

// MARK: - Library Drag Item

/// Transferable wrapper for dragging libraries (for reordering)
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

    /// SciX library repository (uses @Observable)
    private var scixRepository: SciXLibraryRepository { SciXLibraryRepository.shared }

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

    // Library deletion state
    @State private var libraryToDelete: CDLibrary?
    @State private var showDeleteLibraryConfirmation = false

    // Inbox feed creation sheets
    @State private var showArXivFeedForInbox = false
    @State private var showGroupFeedForInbox = false

    // Settings sheets for retention labels
    @State private var showInboxSettings = false
    @State private var showExplorationSettings = false

    // Inbox settings state
    @State private var inboxAgeLimit: AgeLimitPreset = .threeMonths

    // Library collection creation
    @State private var showNewCollectionForLibrary: CDLibrary?
    @State private var showSmartCollectionForLibrary: CDLibrary?

    // Section ordering and collapsed state (persisted, synced with macOS)
    @State private var sectionOrder: [SidebarSectionType] = SidebarSectionOrderStore.loadOrderSync()
    @State private var collapsedSections: Set<SidebarSectionType> = SidebarCollapsedStateStore.loadCollapsedSync()

    // Section reorder sheet
    @State private var showSectionReorderSheet = false

    // Library expansion state (for DisclosureGroups)
    @State private var expandedLibraries: Set<UUID> = []

    // Expanded state for library collection tree, keyed by library ID
    @State private var expandedLibraryCollections: [UUID: Set<UUID>] = [:]

    // Expanded state for inbox collection tree
    @State private var expandedInboxCollections: Set<UUID> = []

    // Collection rename state
    @State private var renamingCollection: CDCollection?

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

            // Load inbox settings for retention label
            let settings = await InboxSettingsStore.shared.settings
            inboxAgeLimit = settings.ageLimit
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncedSettingsDidChange)) { _ in
            // Refresh retention labels when settings change
            Task {
                let settings = await InboxSettingsStore.shared.settings
                inboxAgeLimit = settings.ageLimit
            }
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudKitDataDidChange)) { _ in
            // Refresh when CloudKit syncs data from other devices
            refreshID = UUID()
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
        .sheet(isPresented: $showInboxSettings) {
            NavigationStack {
                IOSInboxSettingsView()
                    .navigationTitle("Inbox Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showInboxSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showExplorationSettings) {
            NavigationStack {
                IOSExplorationSettingsView()
                    .navigationTitle("Exploration")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showExplorationSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSectionReorderSheet) {
            SectionReorderSheet(
                sectionOrder: $sectionOrder,
                isPresented: $showSectionReorderSheet
            )
        }
        .alert("Delete Library?", isPresented: $showDeleteLibraryConfirmation, presenting: libraryToDelete) { library in
            Button("Delete", role: .destructive) {
                try? libraryManager.deleteLibrary(library)
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Are you sure you want to delete \"\(library.displayName)\"? This will remove all publications and cannot be undone.")
        }
        .sheet(item: $renamingCollection) { collection in
            CollectionRenameSheet(
                collection: collection,
                onDismiss: { renamingCollection = nil },
                onSave: { refreshID = UUID() }
            )
        }
        .onChange(of: selection) { _, newValue in
            // Check if new selection is in the exploration section
            let isExplorationSelection: Bool
            switch newValue {
            case .collection(let collection):
                isExplorationSelection = collection.library?.id == libraryManager.explorationLibrary?.id
                selectedLibraryForAction = collection.effectiveLibrary
            case .smartSearch(let ss):
                isExplorationSelection = ss.library?.id == libraryManager.explorationLibrary?.id
                selectedLibraryForAction = ss.library
            case .library(let lib):
                isExplorationSelection = false
                selectedLibraryForAction = lib
            default:
                isExplorationSelection = false
            }

            // Clear exploration multi-selection when navigating outside exploration section
            // This ensures only one item appears selected at a time
            if !isExplorationSelection && !explorationMultiSelection.isEmpty {
                explorationMultiSelection.removeAll()
                isExplorationEditMode = false
            }
        }
    }

    // MARK: - Section Views

    /// Returns the appropriate section view for a given section type
    @ViewBuilder
    private func sectionView(for sectionType: SidebarSectionType) -> some View {
        switch sectionType {
        case .inbox:
            // Inbox uses selectable header - tapping "Inbox" shows all papers
            selectableCollapsibleSection(for: .inbox, tag: .inbox) {
                inboxSectionContent
            }
        case .libraries:
            collapsibleSection(for: .libraries) {
                librariesSectionContent
            }
        case .sharedWithMe:
            if !libraryManager.sharedWithMeLibraries.isEmpty {
                collapsibleSection(for: .sharedWithMe) {
                    sharedWithMeSectionContent
                }
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
        case .flagged:
            selectableCollapsibleSection(for: .flagged, tag: .flagged(nil)) {
                flaggedSectionContent
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

    /// Wraps section content in a collapsible Section with a SELECTABLE header.
    /// Used for Inbox where tapping the header text selects the section (shows all papers).
    @ViewBuilder
    private func selectableCollapsibleSection<Content: View>(
        for sectionType: SidebarSectionType,
        tag: SidebarSection,
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
                    // Chevron indicator only
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .buttonStyle(.plain)

                // Selectable section title with unread badge
                HStack(spacing: 6) {
                    Text(sectionType.displayName)
                        .foregroundStyle(.primary)

                    // Show unread badge for Inbox
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
                .onTapGesture {
                    selection = tag
                }

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
            HStack(spacing: 6) {
                // Retention label (clickable)
                Button {
                    showInboxSettings = true
                } label: {
                    Text(inboxRetentionLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)

                // Add feed/collection menu - creates feeds or collections for organizing
                Menu {
                    // New Collection option
                    Button {
                        createInboxRootCollection()
                    } label: {
                        Label("New Collection", systemImage: "folder.badge.plus")
                    }

                    Divider()

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
            }
        case .exploration:
            // Retention label (clickable)
            Button {
                showExplorationSettings = true
            } label: {
                Text(explorationRetentionLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        default:
            EmptyView()
        }
    }

    // MARK: - Retention Labels

    /// Label showing the current Inbox retention setting
    private var inboxRetentionLabel: String {
        inboxAgeLimit == .unlimited ? "∞" : inboxAgeLimit.displayName
    }

    /// Label showing the current Exploration retention setting
    private var explorationRetentionLabel: String {
        SyncedSettingsStore.shared.explorationRetention.displayName.lowercased()
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
        let libraries = libraryManager.libraries.filter { !$0.isInbox }
        ForEach(libraries) { library in
            librarySection(for: library)
        }
        .onInsert(of: [.libraryID]) { index, providers in
            handleLibraryInsert(at: index, providers: providers, libraries: libraries)
        }
    }

    /// Handle library reordering via drag-and-drop
    private func handleLibraryInsert(at targetIndex: Int, providers: [NSItemProvider], libraries: [CDLibrary]) {
        guard let provider = providers.first else { return }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.libraryID.identifier) { data, _ in
            guard let data = data,
                  let uuidString = String(data: data, encoding: .utf8),
                  let draggedID = UUID(uuidString: uuidString) else { return }

            Task { @MainActor in
                var reordered = libraries
                guard let sourceIndex = reordered.firstIndex(where: { $0.id == draggedID }) else { return }

                // Calculate destination accounting for removal
                let destinationIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
                let clampedDestination = max(0, min(destinationIndex, reordered.count - 1))

                // Perform the move
                let library = reordered.remove(at: sourceIndex)
                reordered.insert(library, at: clampedDestination)

                // Update sort order
                for (index, lib) in reordered.enumerated() {
                    lib.sortOrder = Int16(index)
                }
                try? PersistenceController.shared.viewContext.save()
                refreshID = UUID()
            }
        }
    }

    /// Shared With Me section content
    @ViewBuilder
    private var sharedWithMeSectionContent: some View {
        ForEach(libraryManager.sharedWithMeLibraries, id: \.id) { library in
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                Text(library.displayName)
                    .lineLimit(1)
                Spacer()
                if !library.canEditLibrary {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                let count = library.publications?.count ?? 0
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .tag(SidebarSection.library(library))
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

                // SciX permission sharing - requires SciX API integration (not yet implemented)
                // if library.canManagePermissions {
                //     Button { } label: { Label("Share...", systemImage: "person.2") }
                // }

                // SciX library deletion - requires SciX API integration (not yet implemented)
                // if library.permissionLevelEnum == .owner {
                //     Divider()
                //     Button(role: .destructive) { } label: { Label("Delete Library", systemImage: "trash") }
                // }
            }
        }
        .onMove(perform: moveScixLibraries)
    }

    /// Handle SciX library reordering
    private func moveScixLibraries(from source: IndexSet, to destination: Int) {
        var reordered = scixRepository.libraries
        reordered.move(fromOffsets: source, toOffset: destination)
        scixRepository.updateSortOrder(reordered)
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

        // Start with root collections (excluding smart search results), sorted by sortOrder then name
        let rootCollections = Array(collections)
            .filter { $0.parentCollection == nil && !$0.isSmartSearchResults }
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

    /// Flagged section content — shows per-color flag items
    @ViewBuilder
    private var flaggedSectionContent: some View {
        let colors: [(String, Color)] = [
            ("red", .red),
            ("amber", .orange),
            ("blue", .blue),
            ("gray", .gray)
        ]
        ForEach(colors, id: \.0) { colorName, swiftColor in
            NavigationLink(value: SidebarSection.flagged(colorName)) {
                Label {
                    Text(colorName.capitalized)
                } icon: {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(swiftColor)
                }
            }
        }
    }

    /// Inbox section content (without Section wrapper)
    /// Now tapping the "Inbox" header shows all papers, so we don't need an "Inbox" row.
    /// Content includes: top-level feeds, collections (with their nested feeds)
    @ViewBuilder
    private var inboxSectionContent: some View {
        // Top-level feeds (no parent collection)
        let topLevelFeeds = inboxFeeds.filter { $0.inboxParentCollection == nil }

        ForEach(topLevelFeeds, id: \.id) { feed in
            iosInboxFeedRow(for: feed)
        }

        // Inbox collections (hierarchical) with their nested feeds
        if let inboxLibrary = InboxManager.shared.inboxLibrary,
           let collections = inboxLibrary.collections,
           !collections.isEmpty {
            let rootCollections = collections
                .filter { $0.parentCollection == nil && !$0.isSystemCollection && !$0.isSmartSearchResults }
                .sorted { $0.name < $1.name }

            ForEach(rootCollections, id: \.id) { collection in
                iosInboxCollectionRow(collection: collection, depth: 0)
            }
        }
    }

    /// Row for an inbox feed on iOS
    @ViewBuilder
    private func iosInboxFeedRow(for feed: CDSmartSearch) -> some View {
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
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                removeFromInbox(feed)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// Row for an inbox collection on iOS (with expand/collapse)
    @ViewBuilder
    private func iosInboxCollectionRow(collection: CDCollection, depth: Int) -> some View {
        let isExpanded = expandedInboxCollections.contains(collection.id)
        let hasChildren = collection.hasChildren
        let nestedFeeds = inboxFeeds.filter { $0.inboxParentCollection?.id == collection.id }
        let hasContent = hasChildren || !nestedFeeds.isEmpty

        // Collection row
        HStack {
            if hasContent {
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

            let pubCount = collection.publications?.count ?? 0
            if pubCount > 0 {
                Text("\(pubCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .tag(SidebarSection.inboxCollection(collection))
        .contextMenu {
            Button {
                renamingCollection = collection
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                createSubcollectionInInbox(parent: collection)
            } label: {
                Label("New Subcollection", systemImage: "folder.badge.plus")
            }

            Divider()

            Button(role: .destructive) {
                deleteInboxCollection(collection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteInboxCollection(collection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        // Show nested content when expanded
        if isExpanded {
            // Nested feeds
            ForEach(nestedFeeds, id: \.id) { feed in
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
                .padding(.leading, CGFloat(depth + 1) * 16)
                .tag(SidebarSection.inboxFeed(feed))
            }

            // Nested collections (use AnyView to break recursive type inference)
            ForEach(collection.sortedChildren, id: \.id) { childCollection in
                AnyView(iosInboxCollectionRow(collection: childCollection, depth: depth + 1))
            }
        }
    }

    /// Toggle expanded state for an inbox collection
    private func toggleInboxCollectionExpanded(_ collection: CDCollection) {
        if expandedInboxCollections.contains(collection.id) {
            expandedInboxCollections.remove(collection.id)
        } else {
            expandedInboxCollections.insert(collection.id)
        }
    }

    /// Delete an inbox collection
    private func deleteInboxCollection(_ collection: CDCollection) {
        let context = PersistenceController.shared.viewContext

        // Move any feeds in this collection to top level
        if let feeds = collection.inboxFeeds {
            for feed in feeds {
                feed.inboxParentCollection = nil
            }
        }

        context.delete(collection)
        try? context.save()
        refreshID = UUID()
    }

    /// Create a new root-level collection in the Inbox
    private func createInboxRootCollection() {
        guard let inboxLibrary = InboxManager.shared.inboxLibrary else { return }

        let context = PersistenceController.shared.viewContext
        let newCollection = CDCollection(context: context)
        newCollection.id = UUID()
        newCollection.name = "New Collection"
        newCollection.library = inboxLibrary
        newCollection.dateCreated = Date()
        newCollection.sortOrder = Int16((inboxLibrary.collections?.count ?? 0))

        try? context.save()
        refreshID = UUID()

        // Show rename sheet for immediate editing
        renamingCollection = newCollection
    }

    /// Create a subcollection under an inbox collection
    private func createSubcollectionInInbox(parent: CDCollection) {
        guard let inboxLibrary = InboxManager.shared.inboxLibrary else { return }

        let context = PersistenceController.shared.viewContext
        let newCollection = CDCollection(context: context)
        newCollection.id = UUID()
        newCollection.name = "New Subcollection"
        newCollection.library = inboxLibrary
        newCollection.parentCollection = parent
        newCollection.dateCreated = Date()
        newCollection.sortOrder = Int16((parent.childCollections?.count ?? 0))

        try? context.save()

        // Expand parent to show the new subcollection
        expandedInboxCollections.insert(parent.id)
        refreshID = UUID()

        // Show rename sheet for immediate editing
        renamingCollection = newCollection
    }

    /// Remove a feed from the Inbox (disable feedsToInbox)
    private func removeFromInbox(_ feed: CDSmartSearch) {
        feed.feedsToInbox = false
        try? PersistenceController.shared.viewContext.save()
        refreshID = UUID()
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

    @ViewBuilder
    private func librarySection(for library: CDLibrary) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: library.id)) {
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

            // Collections (hierarchical)
            if let collectionSet = library.collections, !collectionSet.isEmpty {
                DisclosureGroup("Collections") {
                    let flatCollections = flattenedLibraryCollections(from: collectionSet, libraryID: library.id)
                    let visibleCollections = filterVisibleLibraryCollections(flatCollections, libraryID: library.id)

                    ForEach(visibleCollections, id: \.id) { collection in
                        libraryCollectionRow(collection, allCollections: flatCollections, library: library)
                    }
                    .onMove { source, destination in
                        moveCollections(from: source, to: destination, in: visibleCollections, library: library)
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

                // Starred count badge
                let starredCount = allPublications(for: library).filter { $0.isStarred }.count
                if starredCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text("\(starredCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Paper count badge
                let paperCount = allPublications(for: library).count
                if paperCount > 0 {
                    Text("\(paperCount)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

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
            // Accept collection drops for cross-library moves
            .dropDestination(for: String.self) { items, _ in
                guard let uuidString = items.first,
                      let collectionID = UUID(uuidString: uuidString) else { return false }
                return moveCollectionToLibrary(collectionID: collectionID, targetLibrary: library)
            }
            .contextMenu {
                // Share via iOS share sheet
                ShareLink(
                    item: ShareablePublications(
                        publications: (library.publications ?? [])
                            .filter { !$0.isDeleted }
                            .map { ShareablePublication(from: $0) },
                        libraryName: library.displayName
                    ),
                    preview: SharePreview(
                        library.displayName,
                        image: Image(systemName: "books.vertical")
                    )
                ) {
                    Label("Share Library...", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button("Delete Library", role: .destructive) {
                    libraryToDelete = library
                    showDeleteLibraryConfirmation = true
                }
            }
        }
        // Tag for list selection - clicking library header shows all publications
        .tag(SidebarSection.library(library))
        .accessibilityIdentifier(AccessibilityID.Sidebar.libraryRow(library.id))
        .draggable(LibraryDragItem(id: library.id)) {
            Label(library.displayName, systemImage: "books.vertical")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Library Collection Helpers

    /// Flatten library collections into ordered list respecting hierarchy
    private func flattenedLibraryCollections(from collections: Set<CDCollection>, libraryID: UUID) -> [CDCollection] {
        var result: [CDCollection] = []

        func addWithChildren(_ collection: CDCollection) {
            result.append(collection)
            for child in collection.sortedChildren {
                addWithChildren(child)
            }
        }

        // Start with root collections (no parent), sorted by sortOrder then name
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
            // Root collections are always visible
            guard collection.parentCollection != nil else { return true }

            // Check if all ancestors are expanded
            for ancestor in collection.ancestors {
                if !expandedSet.contains(ancestor.id) {
                    return false
                }
            }
            return true
        }
    }

    /// Check if this collection is the last child of its parent
    private func isLastChildInLibrary(_ collection: CDCollection, in allCollections: [CDCollection]) -> Bool {
        guard let parentID = collection.parentCollection?.id else {
            let rootCollections = allCollections.filter { $0.parentCollection == nil }
            return rootCollections.last?.id == collection.id
        }
        let siblings = allCollections.filter { $0.parentCollection?.id == parentID }
        return siblings.last?.id == collection.id
    }

    /// Check if an ancestor at the given depth level has siblings after it
    private func hasAncestorSiblingBelowInLibrary(_ collection: CDCollection, at level: Int, in allCollections: [CDCollection]) -> Bool {
        var current: CDCollection? = collection
        var currentLevel = Int(collection.depth)

        while currentLevel > level, let c = current {
            current = c.parentCollection
            currentLevel -= 1
        }

        guard let ancestor = current else { return false }
        return !isLastChildInLibrary(ancestor, in: allCollections)
    }

    /// Row for a library collection with tree lines and hierarchy support
    @ViewBuilder
    private func libraryCollectionRow(_ collection: CDCollection, allCollections: [CDCollection], library: CDLibrary) -> some View {
        let depth = Int(collection.depth)
        let isLast = isLastChildInLibrary(collection, in: allCollections)
        let hasChildren = collection.hasChildren
        let isExpanded = expandedLibraryCollections[library.id]?.contains(collection.id) ?? false

        HStack(spacing: 0) {
            // Tree lines for each level
            if depth > 0 {
                ForEach(0..<depth, id: \.self) { level in
                    if level == depth - 1 {
                        Text(isLast ? "└" : "├")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .frame(width: 12)
                    } else {
                        if hasAncestorSiblingBelowInLibrary(collection, at: level, in: allCollections) {
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

            // Disclosure triangle (if has children)
            if hasChildren {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        var expanded = expandedLibraryCollections[library.id] ?? []
                        if isExpanded {
                            expanded.remove(collection.id)
                        } else {
                            expanded.insert(collection.id)
                        }
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

            // Folder icon
            Image(systemName: collection.isSmartCollection ? "folder.badge.gearshape" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.trailing, 4)

            // Collection name
            Text(collection.name)
                .lineLimit(1)

            Spacer()

            // Count badge
            if collection.matchingPublicationCount > 0 {
                Text("\(collection.matchingPublicationCount)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .tag(SidebarSection.collection(collection))
        .contextMenu {
            Button {
                renamingCollection = collection
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            if !collection.isSmartCollection {
                Button {
                    createSubcollection(in: library, parent: collection)
                } label: {
                    Label("New Subcollection", systemImage: "folder.badge.plus")
                }
            }

            Divider()

            Button(role: .destructive) {
                deleteCollection(collection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteCollection(collection)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Create a subcollection under the given parent
    private func createSubcollection(in library: CDLibrary, parent: CDCollection) {
        guard let context = library.managedObjectContext else { return }

        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = "New Subcollection"
        collection.isSmartCollection = false
        collection.library = library
        collection.parentCollection = parent

        try? context.save()

        // Expand parent to show the new subcollection
        var expanded = expandedLibraryCollections[library.id] ?? []
        expanded.insert(parent.id)
        expandedLibraryCollections[library.id] = expanded

        refreshID = UUID()

        // Show rename sheet for immediate editing
        renamingCollection = collection
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

    /// Move a collection to a different library by ID
    private func moveCollectionToLibrary(collectionID: UUID, targetLibrary: CDLibrary) -> Bool {
        guard let context = targetLibrary.managedObjectContext else { return false }

        let request = NSFetchRequest<CDCollection>(entityName: "Collection")
        request.predicate = NSPredicate(format: "id == %@", collectionID as CVarArg)
        request.fetchLimit = 1

        guard let collection = try? context.fetch(request).first else { return false }

        // Don't move to same library
        guard collection.library?.id != targetLibrary.id else { return false }

        // Move collection and all descendants
        moveCollectionTree(collection, to: targetLibrary)

        // Clear parent (becomes root collection in target)
        collection.parentCollection = nil

        try? context.save()
        refreshID = UUID()
        return true
    }

    /// Recursively move a collection and all descendants to a target library
    private func moveCollectionTree(_ collection: CDCollection, to targetLibrary: CDLibrary) {
        // Change library
        collection.library = targetLibrary

        // Move publications to target library
        if let publications = collection.publications {
            for publication in publications {
                publication.addToLibrary(targetLibrary)
            }
        }

        // Recursively move all children
        if let children = collection.childCollections {
            for child in children {
                moveCollectionTree(child, to: targetLibrary)
            }
        }
    }

    /// Reorder collections within their sibling group
    private func moveCollections(from source: IndexSet, to destination: Int, in visibleCollections: [CDCollection], library: CDLibrary) {
        // Get the source collection
        guard let sourceIndex = source.first,
              sourceIndex < visibleCollections.count else { return }

        let sourceCollection = visibleCollections[sourceIndex]

        // Determine valid destination - only allow reordering among siblings with same parent
        let sourceParentID = sourceCollection.parentCollection?.id

        // Find all siblings (collections with same parent at same depth)
        let siblings = visibleCollections.filter { $0.parentCollection?.id == sourceParentID }
        guard siblings.count > 1 else { return }

        // Calculate the position within siblings
        let sourceIndexInSiblings = siblings.firstIndex(where: { $0.id == sourceCollection.id }) ?? 0

        // Find destination index in siblings
        var destinationInSiblings = destination

        // Calculate where in siblings this destination maps to
        if destination < visibleCollections.count {
            let destCollection = visibleCollections[min(destination, visibleCollections.count - 1)]
            if destCollection.parentCollection?.id == sourceParentID {
                destinationInSiblings = siblings.firstIndex(where: { $0.id == destCollection.id }) ?? siblings.count
            } else {
                // Destination is not a sibling, don't allow move
                return
            }
        } else {
            // Destination is past end, check if last sibling
            if let lastSibling = siblings.last,
               let lastIndex = visibleCollections.firstIndex(where: { $0.id == lastSibling.id }),
               destination > lastIndex {
                destinationInSiblings = siblings.count
            } else {
                return
            }
        }

        // Don't move to same position
        if sourceIndexInSiblings == destinationInSiblings || sourceIndexInSiblings + 1 == destinationInSiblings {
            return
        }

        // Reorder siblings
        var reorderedSiblings = siblings
        reorderedSiblings.remove(at: sourceIndexInSiblings)
        let insertIndex = destinationInSiblings > sourceIndexInSiblings ? destinationInSiblings - 1 : destinationInSiblings
        reorderedSiblings.insert(sourceCollection, at: insertIndex)

        // Update sortOrder for all siblings
        for (index, collection) in reorderedSiblings.enumerated() {
            collection.sortOrder = Int16(index)
        }

        try? library.managedObjectContext?.save()
        refreshID = UUID()
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

// MARK: - Collection Rename Sheet

/// Sheet for renaming a collection
struct CollectionRenameSheet: View {
    let collection: CDCollection
    var onDismiss: (() -> Void)?
    var onSave: (() -> Void)?

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
                    Button("Cancel") {
                        onDismiss?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onAppear {
                name = collection.name
                // Focus the text field after a brief delay to ensure the view is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isNameFieldFocused = true
                }
            }
        }
    }

    private func saveChanges() {
        collection.name = name
        // Use shared view context to ensure save happens even if collection's context is nil
        let context = collection.managedObjectContext ?? PersistenceController.shared.viewContext
        try? context.save()
        onSave?()
        onDismiss?()
        dismiss()
    }
}

// MARK: - Section Reorder Sheet

/// Sheet for reordering sidebar sections
struct SectionReorderSheet: View {
    @Binding var sectionOrder: [SidebarSectionType]
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(sectionOrder) { sectionType in
                    HStack {
                        Image(systemName: sectionType.iconName)
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
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }

    private func moveSections(from source: IndexSet, to destination: Int) {
        sectionOrder.move(fromOffsets: source, toOffset: destination)
        Task {
            await SidebarSectionOrderStore.shared.save(sectionOrder)
        }
    }
}

// MARK: - SidebarSectionType Icon Extension

extension SidebarSectionType {
    var iconName: String {
        switch self {
        case .inbox: return "tray"
        case .libraries: return "books.vertical"
        case .sharedWithMe: return "person.2"
        case .scixLibraries: return "star"
        case .search: return "magnifyingglass"
        case .exploration: return "safari"
        case .flagged: return "flag"
        case .dismissed: return "xmark.circle"
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
