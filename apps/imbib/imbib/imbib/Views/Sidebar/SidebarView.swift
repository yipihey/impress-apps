//
//  SidebarView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import CoreData
import PublicationManagerCore
import UniformTypeIdentifiers
import OSLog

private let sidebarLogger = Logger(subsystem: "com.imbib.app", category: "sidebar-dragdrop")

/// Log drag-drop info to both system console AND app's Console window
private func dragDropLog(_ message: String) {
    sidebarLogger.info("\(message)")
    Task { @MainActor in
        LogStore.shared.log(level: .info, category: "dragdrop", message: message)
    }
}

/// Log drag-drop error to both system console AND app's Console window
private func dragDropError(_ message: String) {
    sidebarLogger.error("\(message)")
    Task { @MainActor in
        LogStore.shared.log(level: .error, category: "dragdrop", message: message)
    }
}

/// Log drag-drop warning to both system console AND app's Console window
private func dragDropWarning(_ message: String) {
    sidebarLogger.warning("\(message)")
    Task { @MainActor in
        LogStore.shared.log(level: .warning, category: "dragdrop", message: message)
    }
}

struct SidebarView: View {

    // MARK: - Properties

    @Binding var selection: SidebarSection?
    @Binding var expandedLibraries: Set<UUID>

    // MARK: - Drag-Drop Coordinator

    private let dragDropCoordinator = DragDropCoordinator.shared

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.themeColors) private var theme

    // MARK: - Observed Objects

    /// Observe SmartSearchRepository to refresh when smart searches change
    private let smartSearchRepository = SmartSearchRepository.shared

    /// Observe SciXLibraryRepository for SciX libraries
    private let scixRepository = SciXLibraryRepository.shared

    // MARK: - State

    /// Consolidated sidebar state using @Observable pattern
    @State private var state = SidebarState()

    // Section ordering and collapsed state (persisted via stores, not @AppStorage)
    @State private var sectionOrder: [SidebarSectionType] = SidebarSectionOrderStore.loadOrderSync()
    @State private var collapsedSections: Set<SidebarSectionType> = SidebarCollapsedStateStore.loadCollapsedSync()

    // Search form ordering and visibility (persisted)
    @State private var searchFormOrder: [SearchFormType] = SearchFormStore.loadOrderSync()
    @State private var hiddenSearchForms: Set<SearchFormType> = SearchFormStore.loadHiddenSync()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Main list with optional theme tint
            List(selection: $selection) {
                // All sections in user-defined order, all collapsible and moveable
                ForEach(sectionOrder) { sectionType in
                    sectionView(for: sectionType)
                        .id(sectionType == .exploration ? state.explorationRefreshTrigger : nil)
                }
                .onMove(perform: moveSections)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(theme.detailBackground != nil || theme.sidebarTint != nil ? .hidden : .automatic)
            .background {
                if let tint = theme.sidebarTint {
                    tint.opacity(theme.sidebarTintOpacity)
                }
            }
            // Sidebar-wide drop target for BibTeX/RIS files (not dropped on a specific library)
            // Opens import preview with "Create new library" pre-selected
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                // Only handle BibTeX/RIS files - other drops (publications, PDFs) should go to specific targets
                if hasBibTeXOrRISDrops(providers) {
                    handleBibTeXDropForNewLibrary(providers)
                    return true
                }
                return false
            }

            // Bottom toolbar
            Divider()
            bottomToolbar
        }
        .navigationTitle("imbib")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        #endif
        // Unified sheet presentation using SidebarSheet enum
        .sheet(item: $state.activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .onChange(of: dragDropCoordinator.pendingPreview) { _, newValue in
            // Dismiss the sheet when pendingPreview becomes nil (import completed or cancelled)
            if newValue == nil, case .dropPreview = state.activeSheet {
                state.dismissSheet()
            }
        }
        .alert("Delete Library?", isPresented: $state.showDeleteConfirmation, presenting: state.libraryToDelete) { library in
            Button("Delete", role: .destructive) {
                deleteLibrary(library)
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Are you sure you want to delete \"\(library.displayName)\"? This will remove all publications and cannot be undone.")
        }
        .alert("Empty Dismissed?", isPresented: $state.showEmptyDismissedConfirmation) {
            Button("Empty", role: .destructive) {
                libraryManager.emptyDismissedLibrary()
                state.triggerRefresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = libraryManager.dismissedLibrary?.publications?.count ?? 0
            Text("Are you sure you want to permanently delete \(count) dismissed paper\(count == 1 ? "" : "s")? This cannot be undone.")
        }
        // Mbox import file picker
        .fileImporter(
            isPresented: $state.showMboxImportPicker,
            allowedContentTypes: [UTType(filenameExtension: "mbox") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        await prepareMboxImport(from: url)
                    }
                }
            case .failure(let error):
                state.mboxExportError = error.localizedDescription
                state.showMboxExportError = true
            }
        }
        // Mbox export error alert
        .alert("Export Error", isPresented: $state.showMboxExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.mboxExportError ?? "Unknown error")
        }
        .task {
            // Auto-expand the first library if none expanded
            if expandedLibraries.isEmpty, let firstLibrary = libraryManager.libraries.first {
                expandedLibraries.insert(firstLibrary.id)
            }
            // Load all smart searches (not filtered by library) for sidebar display
            smartSearchRepository.loadSmartSearches(for: nil)

            // Check for ADS API key (SciX uses ADS API) and load libraries if available
            if let _ = await CredentialManager.shared.apiKey(for: "ads") {
                state.hasSciXAPIKey = true
                // Load cached libraries from Core Data
                scixRepository.loadLibraries()
                // Optionally trigger a background refresh from server
                Task.detached {
                    try? await SciXSyncManager.shared.pullLibraries()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readStatusDidChange)) { _ in
            // Force re-render to update unread counts
            state.triggerRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryContentDidChange)) { _ in
            // Force re-render to update publication counts after add/move operations
            state.triggerRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .explorationLibraryDidChange)) { _ in
            // Refresh exploration section
            state.triggerExplorationRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSmartSearch)) { notification in
            // Navigate to a smart search in the sidebar (from share extension or other source)
            if let searchID = notification.object as? UUID,
               let smartSearch = explorationSmartSearches.first(where: { $0.id == searchID }) {
                selection = .smartSearch(smartSearch)
            }
            // Refresh exploration to show the new/updated search
            state.triggerExplorationRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { notification in
            // Navigate to the collection in the sidebar
            if let collection = notification.userInfo?["collection"] as? CDCollection {
                // Expand all ancestors so the collection is visible in the tree
                expandAncestors(of: collection)
                selection = .collection(collection)
                state.triggerExplorationRefresh()
            }
        }
        // Auto-expand ancestors and set exploration context when selection changes
        .onChange(of: selection) { _, newSelection in
            if case .collection(let collection) = newSelection {
                expandAncestors(of: collection)
                // Set exploration context for building tree hierarchy
                ExplorationService.shared.currentExplorationContext = collection
            } else {
                // Clear exploration context when not viewing an exploration collection
                ExplorationService.shared.currentExplorationContext = nil
            }
        }
        .id(state.refreshTrigger)  // Re-render when refreshTrigger changes
    }

    // MARK: - Sheet Content

    /// Unified sheet content based on SidebarSheet enum
    @ViewBuilder
    private func sheetContent(for sheet: SidebarSheet) -> some View {
        switch sheet {
        case .newLibrary:
            NewLibrarySheet()

        case .newSmartCollection(let library):
            SmartCollectionEditor(isPresented: .constant(true)) { name, predicate in
                Task {
                    await createSmartCollection(name: name, predicate: predicate, in: library)
                }
                state.dismissSheet()
            }

        case .editCollection(let collection):
            SmartCollectionEditor(isPresented: .constant(true), collection: collection) { name, predicate in
                Task {
                    await updateCollection(collection, name: name, predicate: predicate)
                }
                state.dismissSheet()
            }

        case .dropPreview(let libraryID):
            dropPreviewSheetContent(for: libraryID)

        case .mboxImport(let preview, _):
            MboxImportPreviewView(
                preview: preview,
                onImport: { selectedIDs, duplicateDecisions in
                    Task {
                        await executeMboxImport(
                            preview: preview,
                            selectedIDs: selectedIDs,
                            duplicateDecisions: duplicateDecisions
                        )
                    }
                    state.dismissSheet()
                },
                onCancel: {
                    state.mboxImportPreview = nil
                    state.dismissSheet()
                }
            )
            .frame(minWidth: 600, minHeight: 500)
        }
    }

    /// Drop preview sheet content for a specific library
    @ViewBuilder
    private func dropPreviewSheetContent(for libraryID: UUID) -> some View {
        @Bindable var coordinator = dragDropCoordinator
        DropPreviewSheet(
            preview: $coordinator.pendingPreview,
            libraryID: libraryID,
            coordinator: dragDropCoordinator
        )
        .onDisappear {
            state.dropPreviewTargetLibraryID = nil
            state.triggerRefresh()
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
            if state.hasSciXAPIKey && !scixRepository.libraries.isEmpty {
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
            if let dismissedLibrary = libraryManager.dismissedLibrary,
               let publications = dismissedLibrary.publications,
               !publications.isEmpty {
                collapsibleSection(for: .dismissed) {
                    dismissedSectionContent
                }
            }
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
            HStack(spacing: 4) {
                // Collapse/expand button
                Button {
                    toggleSectionCollapsed(sectionType)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                // Section title
                Text(sectionType.displayName)

                Spacer()

                // Additional header content based on section type
                sectionHeaderExtras(for: sectionType)
            }
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

    /// Additional header content for specific section types
    @ViewBuilder
    private func sectionHeaderExtras(for sectionType: SidebarSectionType) -> some View {
        switch sectionType {
        case .inbox:
            // Add feed menu - creates feeds that auto-refresh and populate inbox
            Menu {
                Button {
                    // Navigate to arXiv Feed form in Search section
                    selection = .searchForm(.arxivFeed)
                } label: {
                    Label("arXiv Category Feed", systemImage: "antenna.radiowaves.left.and.right")
                }

                Button {
                    // Navigate to Group Feed form in Search section
                    selection = .searchForm(.arxivGroupFeed)
                } label: {
                    Label("arXiv Group Feed", systemImage: "person.3.fill")
                }

                Divider()

                Button {
                    // Navigate to SciX Search form in Search section
                    selection = .searchForm(.adsModern)
                } label: {
                    Label("SciX Search", systemImage: "magnifyingglass")
                }

                Button {
                    // Navigate to ADS Classic form in Search section
                    selection = .searchForm(.adsClassic)
                } label: {
                    Label("ADS Classic Search", systemImage: "list.bullet.rectangle")
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .help("Create feed for Inbox")
        case .libraries:
            // Add library button
            Button {
                state.showNewLibrary()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Add Library")
        case .exploration:
            // Navigation buttons + selection count
            HStack(spacing: 4) {
                // Back/forward navigation buttons
                NavigationButtonBar(
                    navigationHistory: NavigationHistoryStore.shared,
                    onBack: { NotificationCenter.default.post(name: .navigateBack, object: nil) },
                    onForward: { NotificationCenter.default.post(name: .navigateForward, object: nil) }
                )

                // Show selection count when multi-selected
                if state.explorationMultiSelection.count > 1 {
                    Text("\(state.explorationMultiSelection.count) selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .dismissed:
            // Empty dismissed button
            Button {
                emptyDismissed()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Empty Dismissed")
        default:
            EmptyView()
        }
    }

    /// Libraries section content (without Section wrapper)
    @ViewBuilder
    private var librariesSectionContent: some View {
        // Filter out special libraries: Inbox, Dismissed, Keep (which has its own place or is shown in regular flow)
        ForEach(libraryManager.libraries.filter { !$0.isInbox && !$0.isDismissedLibrary }, id: \.id) { library in
            libraryDisclosureGroup(for: library)
        }
        .onMove { indices, destination in
            libraryManager.moveLibraries(from: indices, to: destination)
        }
    }

    /// SciX Libraries section content (without Section wrapper)
    @ViewBuilder
    private var scixLibrariesSectionContent: some View {
        ForEach(scixRepository.libraries, id: \.id) { library in
            scixLibraryRow(for: library)
        }
    }

    /// Search section content (without Section wrapper)
    @ViewBuilder
    private var searchSectionContent: some View {
        // Visible search forms in user-defined order
        ForEach(visibleSearchForms) { formType in
            Label(formType.displayName, systemImage: formType.icon)
                .tag(SidebarSection.searchForm(formType))
                .contentShape(Rectangle())
                .onTapGesture {
                    // Reset to show form in list pane (not results)
                    // This fires even when re-clicking the already-selected form
                    NotificationCenter.default.post(name: .resetSearchFormView, object: nil)
                    // Manually set selection since onTapGesture consumes the tap
                    selection = .searchForm(formType)
                }
                .contextMenu {
                    Button("Hide") {
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
        searchFormOrder.filter { formType in
            // Skip if form is hidden by user
            if hiddenSearchForms.contains(formType) { return false }
            // Skip forms that require ADS credentials when not available
            if formType.requiresADSCredentials && !state.hasSciXAPIKey { return false }
            return true
        }
    }

    /// Move search forms via drag-and-drop
    private func moveSearchForms(from source: IndexSet, to destination: Int) {
        // Get the visible forms
        var visible = visibleSearchForms

        // Perform the move on visible forms
        visible.move(fromOffsets: source, toOffset: destination)

        // Rebuild the full order preserving hidden forms in their relative positions
        var newOrder: [SearchFormType] = []
        var visibleIndex = 0

        for formType in searchFormOrder {
            if hiddenSearchForms.contains(formType) {
                // Keep hidden forms in their current relative position
                newOrder.append(formType)
            } else {
                // Insert visible forms in their new order
                if visibleIndex < visible.count {
                    newOrder.append(visible[visibleIndex])
                    visibleIndex += 1
                }
            }
        }

        // Add any remaining visible forms
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

    /// Smart searches in the exploration library (searches executed from Search section)
    private var explorationSmartSearches: [CDSmartSearch] {
        guard let library = libraryManager.explorationLibrary,
              let searches = library.smartSearches else { return [] }
        return Array(searches).sorted { ($0.dateCreated) > ($1.dateCreated) }
    }

    /// Exploration section content (without Section wrapper)
    @ViewBuilder
    private var explorationSectionContent: some View {
        // Search results from Search section (smart searches in exploration library)
        ForEach(explorationSmartSearches) { smartSearch in
            explorationSearchRow(smartSearch)
        }

        // Exploration collections (Refs, Cites, Similar, Co-Reads) - hierarchical tree display
        if let library = libraryManager.explorationLibrary,
           let collections = library.collections,
           !collections.isEmpty {
            // Add separator if both searches and collections exist
            if !explorationSmartSearches.isEmpty {
                Divider()
                    .padding(.vertical, 4)
            }

            // Flatten and filter based on expanded state
            let allCollections = flattenedExplorationCollections(from: collections)
            let visibleCollections = filterVisibleCollections(allCollections)

            ForEach(visibleCollections, id: \.id) { collection in
                ExplorationTreeRow(
                    collection: collection,
                    allCollections: allCollections,
                    selection: $selection,
                    expandedCollections: $state.expandedExplorationCollections,
                    multiSelection: $state.explorationMultiSelection,
                    lastSelectedID: $state.lastSelectedExplorationID,
                    onDelete: deleteExplorationCollection,
                    onDeleteMultiple: deleteSelectedExplorationCollections
                )
            }
        }
    }

    /// Dismissed section content (without Section wrapper)
    @ViewBuilder
    private var dismissedSectionContent: some View {
        if let dismissedLibrary = libraryManager.dismissedLibrary {
            let count = dismissedLibrary.publications?.count ?? 0

            HStack {
                Label("All Dismissed", systemImage: "trash")
                Spacer()
                if count > 0 {
                    CountBadge(count: count)
                }
            }
            .tag(SidebarSection.library(dismissedLibrary))
            .contextMenu {
                Button("Empty Dismissed", role: .destructive) {
                    state.showEmptyDismissedConfirmation = true
                }
            }
        }
    }

    /// Empty dismissed library
    private func emptyDismissed() {
        state.showEmptyDismissedConfirmation = true
    }

    /// Row for a search smart search in the exploration section
    @ViewBuilder
    private func explorationSearchRow(_ smartSearch: CDSmartSearch) -> some View {
        // Guard against deleted Core Data objects
        if smartSearch.managedObjectContext == nil {
            EmptyView()
        } else {
            explorationSearchRowContent(smartSearch)
        }
    }

    @ViewBuilder
    private func explorationSearchRowContent(_ smartSearch: CDSmartSearch) -> some View {
        let isSelected = selection == .smartSearch(smartSearch)
        let isMultiSelected = state.searchMultiSelection.contains(smartSearch.id)
        let count = smartSearch.resultCollection?.publications?.count ?? 0

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.purple)
                .frame(width: 16)

            Text(smartSearch.name)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
        .tag(SidebarSection.smartSearch(smartSearch))
        .listRowBackground(
            isMultiSelected || isSelected
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
        // Option+Click to toggle multi-selection
        .gesture(
            TapGesture()
                .modifiers(.option)
                .onEnded { _ in
                    if state.searchMultiSelection.contains(smartSearch.id) {
                        state.searchMultiSelection.remove(smartSearch.id)
                    } else {
                        state.searchMultiSelection.insert(smartSearch.id)
                    }
                    state.lastSelectedSearchID = smartSearch.id
                }
        )
        // Shift+Click for range selection
        .gesture(
            TapGesture()
                .modifiers(.shift)
                .onEnded { _ in
                    handleShiftClickSearch(smartSearch: smartSearch, allSearches: explorationSmartSearches)
                }
        )
        // Normal click clears multi-selection and navigates
        .onTapGesture {
            state.searchMultiSelection.removeAll()
            state.searchMultiSelection.insert(smartSearch.id)
            state.lastSelectedSearchID = smartSearch.id
            selection = .smartSearch(smartSearch)
        }
        .contextMenu {
            // Show batch delete if multiple searches selected
            if state.searchMultiSelection.count > 1 {
                Button("Delete \(state.searchMultiSelection.count) Searches", role: .destructive) {
                    deleteSelectedSmartSearches()
                }
            } else {
                if let (url, label) = webURL(for: smartSearch) {
                    Button(label) {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Edit Search...") {
                    // Navigate to Search section with this smart search's query
                    NotificationCenter.default.post(name: .editSmartSearch, object: smartSearch.id)
                }

                Divider()

                Button("Delete", role: .destructive) {
                    SmartSearchRepository.shared.delete(smartSearch)
                    if selection == .smartSearch(smartSearch) {
                        selection = nil
                    }
                    state.searchMultiSelection.remove(smartSearch.id)
                    state.triggerExplorationRefresh()
                }
            }
        }
    }

    /// Handle Shift+click for range selection on smart searches
    private func handleShiftClickSearch(smartSearch: CDSmartSearch, allSearches: [CDSmartSearch]) {
        guard let lastID = state.lastSelectedSearchID,
              let lastIndex = allSearches.firstIndex(where: { $0.id == lastID }),
              let currentIndex = allSearches.firstIndex(where: { $0.id == smartSearch.id }) else {
            // No previous selection, just add this one
            state.searchMultiSelection.insert(smartSearch.id)
            state.lastSelectedSearchID = smartSearch.id
            return
        }

        // Select range between last and current
        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        for i in range {
            state.searchMultiSelection.insert(allSearches[i].id)
        }
    }

    /// Delete all selected smart searches
    private func deleteSelectedSmartSearches() {
        // Collect items to delete BEFORE clearing selection (avoid mutating during iteration)
        let searchesToDelete = explorationSmartSearches.filter { state.searchMultiSelection.contains($0.id) }

        // Clear main selection if any selected search is being deleted
        if case .smartSearch(let selected) = selection,
           state.searchMultiSelection.contains(selected.id) {
            selection = nil
        }

        // Clear multi-selection BEFORE deleting to prevent view crashes
        state.clearSearchSelection()

        // Now delete the collected items
        for smartSearch in searchesToDelete {
            SmartSearchRepository.shared.delete(smartSearch)
        }

        state.triggerExplorationRefresh()
    }

    /// Delete all selected exploration collections
    private func deleteSelectedExplorationCollections() {
        // Collect items to delete BEFORE clearing selection (avoid mutating during iteration)
        var collectionsToDelete: [CDCollection] = []
        if let library = libraryManager.explorationLibrary,
           let collections = library.collections {
            collectionsToDelete = collections.filter { state.explorationMultiSelection.contains($0.id) }
        }

        // Clear main selection if any selected collection is being deleted
        if case .collection(let selected) = selection,
           state.explorationMultiSelection.contains(selected.id) {
            selection = nil
        }

        // Clear multi-selection BEFORE deleting to prevent view crashes
        state.clearExplorationSelection()

        // Now delete the collected items
        for collection in collectionsToDelete {
            libraryManager.deleteExplorationCollection(collection)
        }

        state.triggerExplorationRefresh()
    }

    /// Determine the SF Symbol icon for an exploration collection based on its name prefix.
    ///
    /// - "Refs:" → arrow.down.doc (papers this paper cites)
    /// - "Cites:" → arrow.up.doc (papers citing this paper)
    /// - "Similar:" → doc.on.doc (related papers by content)
    /// - "Co-Reads:" → person.2.fill (papers frequently read together)
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
            // Root level - check if it's the last root
            let rootCollections = allCollections.filter { $0.parentCollection == nil }
            return rootCollections.last?.id == collection.id
        }

        // Find siblings (children of the same parent)
        let siblings = allCollections.filter { $0.parentCollection?.id == parentID }
        return siblings.last?.id == collection.id
    }

    /// Check if an ancestor at the given depth level has siblings after it.
    /// Used to determine whether to draw a vertical tree line at that level.
    private func hasAncestorSiblingBelow(_ collection: CDCollection, at level: Int, in allCollections: [CDCollection]) -> Bool {
        // Walk up the tree to the ancestor at the specified level
        var current: CDCollection? = collection
        var currentLevel = Int(collection.depth)

        while currentLevel > level, let c = current {
            current = c.parentCollection
            currentLevel -= 1
        }

        // Check if this ancestor has siblings below it
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

    /// Filter flattened collections to show only visible ones based on expanded state.
    /// A collection is visible if all its ancestors are expanded.
    private func filterVisibleCollections(_ collections: [CDCollection]) -> [CDCollection] {
        collections.filter { collection in
            // Root collections are always visible
            guard collection.parentCollection != nil else { return true }

            // Check if all ancestors are expanded
            for ancestor in collection.ancestors {
                if !state.expandedExplorationCollections.contains(ancestor.id) {
                    return false
                }
            }
            return true
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

        // Start with root collections (no parent)
        for collection in Array(collections)
            .filter({ $0.parentCollection == nil })
            .sorted(by: { $0.name < $1.name }) {
            addWithChildren(collection)
        }

        return result
    }

    /// Filter to only visible collections (ancestors expanded)
    private func filterVisibleLibraryCollections(_ collections: [CDCollection], libraryID: UUID) -> [CDCollection] {
        let expandedSet = state.expandedLibraryCollections[libraryID] ?? []
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

    /// Create a binding for library collection expansion state
    private func expandedLibraryCollectionsBinding(for libraryID: UUID) -> Binding<Set<UUID>> {
        Binding(
            get: { state.expandedLibraryCollections[libraryID] ?? [] },
            set: { state.expandedLibraryCollections[libraryID] = $0 }
        )
    }

    /// Row for an exploration collection (with tree lines and type-specific icons)
    /// Uses Finder-style selection: Option+click to toggle, Shift+click for range
    @ViewBuilder
    private func explorationCollectionRow(_ collection: CDCollection, allCollections: [CDCollection]) -> some View {
        let isMultiSelected = state.explorationMultiSelection.contains(collection.id)
        let depth = Int(collection.depth)
        let isLast = isLastChild(collection, in: allCollections)

        HStack(spacing: 0) {
            // Tree lines for each level
            if depth > 0 {
                ForEach(0..<depth, id: \.self) { level in
                    if level == depth - 1 {
                        // Final level: draw └ or ├
                        Text(isLast ? "└" : "├")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .frame(width: 12)
                    } else {
                        // Parent levels: draw │ if siblings below, else space
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
                CountBadge(count: collection.matchingPublicationCount)
            }
        }
        .contentShape(Rectangle())
        // Visual feedback for multi-selection
        .listRowBackground(
            isMultiSelected
                ? Color.accentColor.opacity(0.2)
                : nil
        )
        .gesture(
            TapGesture()
                .modifiers(.option)
                .onEnded { _ in
                    // Option+click: Toggle selection
                    if state.explorationMultiSelection.contains(collection.id) {
                        state.explorationMultiSelection.remove(collection.id)
                    } else {
                        state.explorationMultiSelection.insert(collection.id)
                    }
                    state.lastSelectedExplorationID = collection.id
                }
        )
        .simultaneousGesture(
            TapGesture()
                .modifiers(.shift)
                .onEnded { _ in
                    // Shift+click: Range selection
                    handleShiftClick(collection: collection, allCollections: allCollections)
                }
        )
        .onTapGesture {
            // Normal click: Clear multi-selection and navigate
            state.explorationMultiSelection.removeAll()
            state.explorationMultiSelection.insert(collection.id)
            state.lastSelectedExplorationID = collection.id
            selection = .collection(collection)
        }
        .tag(SidebarSection.collection(collection))
        .contextMenu {
            if state.explorationMultiSelection.count > 1 && state.explorationMultiSelection.contains(collection.id) {
                // Multi-selection context menu
                Button("Delete \(state.explorationMultiSelection.count) Items", role: .destructive) {
                    deleteSelectedExplorationCollections()
                }
            } else {
                // Single item context menu
                Button("Delete", role: .destructive) {
                    deleteExplorationCollection(collection)
                }
            }
        }
    }

    /// Handle Shift+click for range selection in exploration section
    private func handleShiftClick(collection: CDCollection, allCollections: [CDCollection]) {
        guard let lastID = state.lastSelectedExplorationID,
              let lastIndex = allCollections.firstIndex(where: { $0.id == lastID }),
              let currentIndex = allCollections.firstIndex(where: { $0.id == collection.id }) else {
            // No previous selection, just select this one
            state.explorationMultiSelection.insert(collection.id)
            state.lastSelectedExplorationID = collection.id
            return
        }

        // Select range from last to current
        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        for i in range {
            state.explorationMultiSelection.insert(allCollections[i].id)
        }
    }

    /// Delete an exploration collection
    private func deleteExplorationCollection(_ collection: CDCollection) {
        // Clear selection if this collection is selected
        if case .collection(let selected) = selection, selected.id == collection.id {
            selection = nil
        }

        libraryManager.deleteExplorationCollection(collection)
        state.triggerExplorationRefresh()
    }

    /// Expand all ancestors of a collection to make it visible in the tree
    private func expandAncestors(of collection: CDCollection) {
        for ancestor in collection.ancestors {
            state.expandedExplorationCollections.insert(ancestor.id)
        }
    }

    // MARK: - Section Reordering

    /// Handle drag-and-drop reordering of sections
    private func moveSections(from source: IndexSet, to destination: Int) {
        withAnimation {
            sectionOrder.move(fromOffsets: source, toOffset: destination)
        }
        Task {
            await SidebarSectionOrderStore.shared.save(sectionOrder)
        }
    }

    // MARK: - Library Disclosure Group

    /// Check if library has any visible children (smart searches or collections).
    @ViewBuilder
    private func libraryDisclosureGroup(for library: CDLibrary) -> some View {
        DisclosureGroup(
            isExpanded: expansionBinding(for: library.id)
        ) {
            // All Publications row - always shown so library selection works
            // even when library has no collections or smart searches
            SidebarDropTarget(
                isTargeted: state.dropTargetedLibrary == library.id,
                showPlusBadge: true
            ) {
                Label("All Publications", systemImage: "books.vertical")
            }
            .tag(SidebarSection.library(library))
            .onDrop(of: DragDropCoordinator.acceptedTypes + [.publicationID], isTargeted: makeLibraryTargetBinding(library.id)) { providers in
                dragDropLog("📦 DROP on library '\(library.displayName)' (id: \(library.id.uuidString))")
                dragDropLog("  - Provider count: \(providers.count)")
                for (i, provider) in providers.enumerated() {
                    let types = provider.registeredTypeIdentifiers
                    dragDropLog("  - Provider[\(i)] types: \(types.joined(separator: ", "))")
                    dragDropLog("  - Provider[\(i)] hasPublicationID: \(provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier))")
                    dragDropLog("  - Provider[\(i)] hasPDF: \(provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier))")
                    dragDropLog("  - Provider[\(i)] hasFileURL: \(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))")
                }

                if hasFileDrops(providers) {
                    dragDropLog("  → Routing to file drop handler")
                    handleFileDrop(providers, libraryID: library.id)
                } else {
                    dragDropLog("  → Routing to publication drop handler")
                    handleDrop(providers: providers) { uuids in
                        dragDropLog("  → handleDrop completed with \(uuids.count) UUIDs: \(uuids.map { $0.uuidString })")
                        Task { await addPublicationsToLibrary(uuids, library: library) }
                    }
                }
                return true
            }

            // Smart Searches for this library (use repository for change observation)
            let librarySmartSearches = smartSearchRepository.smartSearches.filter { $0.library?.id == library.id }
            if !librarySmartSearches.isEmpty {
                ForEach(librarySmartSearches.sorted(by: { $0.name < $1.name }), id: \.id) { smartSearch in
                    SmartSearchRow(smartSearch: smartSearch, count: resultCount(for: smartSearch))
                        .tag(SidebarSection.smartSearch(smartSearch))
                        .contextMenu {
                            Button("Edit") {
                                // Navigate to Search section with this smart search's query
                                NotificationCenter.default.post(name: .editSmartSearch, object: smartSearch.id)
                            }
                            Button("Delete", role: .destructive) {
                                deleteSmartSearch(smartSearch)
                            }
                        }
                }
            }

            // Collections for this library (hierarchical)
            if let collections = library.collections as? Set<CDCollection>, !collections.isEmpty {
                let flatCollections = flattenedLibraryCollections(from: collections, libraryID: library.id)
                let visibleCollections = filterVisibleLibraryCollections(flatCollections, libraryID: library.id)

                ForEach(visibleCollections, id: \.id) { collection in
                    CollectionTreeRow(
                        collection: collection,
                        allCollections: flatCollections,
                        selection: $selection,
                        expandedCollections: expandedLibraryCollectionsBinding(for: library.id),
                        onRename: { state.renamingCollection = $0 },
                        onEdit: collection.isSmartCollection ? { state.showEditCollection($0) } : nil,
                        onDelete: deleteCollection,
                        onCreateSubcollection: { createStaticCollection(in: library, parent: $0) },
                        onDropPublications: { uuids, col in await addPublications(uuids, to: col) },
                        onMoveCollection: { draggedCollection, newParent in
                            moveCollection(draggedCollection, to: newParent, in: library)
                        },
                        isEditing: state.renamingCollection?.id == collection.id,
                        onRenameComplete: { newName in renameCollection(collection, to: newName) }
                    )
                }

                // Drop zone at library level to move collections back to root
                if flatCollections.contains(where: { $0.parentCollection != nil }) {
                    Text("Drop here to move to root")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onDrop(of: [.collectionID], isTargeted: nil) { providers in
                            handleCollectionDropToRoot(providers: providers, library: library)
                        }
                }
            }
        } label: {
            // Library header with + menu
            HStack(spacing: 4) {
                // Library header - also a drop target
                // Clicking the header selects "All Publications" and expands the library
                libraryHeaderDropTarget(for: library)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Select this library's "All Publications"
                        selection = .library(library)
                        // Expand if not already expanded
                        if !expandedLibraries.contains(library.id) {
                            expandedLibraries.insert(library.id)
                        }
                    }
                    .contextMenu {
                        #if os(macOS)
                        // Native sharing via AirDrop, Messages, etc.
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
                        #endif
                        Button("Delete Library", role: .destructive) {
                            state.libraryToDelete = library
                            state.showDeleteConfirmation = true
                        }
                    }

                // + menu for adding collections
                Menu {
                    Button {
                        state.showNewSmartCollection(for: library)
                    } label: {
                        Label("New Smart Collection", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        createStaticCollection(in: library)
                    } label: {
                        Label("New Collection", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Export BibTeX

    /// Export a library to BibTeX format using a save panel.
    private func exportLibraryToBibTeX(_ library: CDLibrary) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(library.displayName).bib"
        panel.allowedContentTypes = [.init(filenameExtension: "bib")!]
        panel.canCreateDirectories = true
        panel.title = "Export Library"
        panel.message = "Choose a location to save the BibTeX file"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try libraryManager.exportToBibTeX(library, to: url)
            } catch {
                // Could show an error alert here
                print("Export failed: \(error)")
            }
        }
        #endif
    }

    // MARK: - Export/Import Mbox

    /// Export a library to mbox format using a save panel.
    private func exportLibraryToMbox(_ library: CDLibrary) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(library.displayName).mbox"
        panel.allowedContentTypes = [UTType(filenameExtension: "mbox") ?? .data]
        panel.canCreateDirectories = true
        panel.title = "Export Library as mbox"
        panel.message = "Export library with all publications, PDFs, and metadata to mbox format"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let exporter = MboxExporter(
                        context: PersistenceController.shared.viewContext,
                        options: .default
                    )
                    try await exporter.export(library: library, to: url)
                } catch {
                    await MainActor.run {
                        state.mboxExportError = error.localizedDescription
                        state.showMboxExportError = true
                    }
                }
            }
        }
        #endif
    }

    /// Prepare mbox import by parsing the file and showing preview.
    private func prepareMboxImport(from url: URL) async {
        do {
            // Start accessing security-scoped resource if needed
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let importer = MboxImporter(
                context: PersistenceController.shared.viewContext,
                options: .default
            )
            let preview = try await importer.prepareImport(from: url)

            await MainActor.run {
                // Show mbox import preview sheet
                if let targetLibrary = state.mboxImportTargetLibrary {
                    state.showMboxImportPreview(preview: preview, library: targetLibrary)
                } else {
                    // Fallback: store preview for later use
                    state.mboxImportPreview = preview
                }
            }
        } catch {
            await MainActor.run {
                state.mboxExportError = "Failed to parse mbox: \(error.localizedDescription)"
                state.showMboxExportError = true
            }
        }
    }

    /// Execute the mbox import after user confirmation.
    private func executeMboxImport(
        preview: MboxImportPreview,
        selectedIDs: Set<UUID>,
        duplicateDecisions: [UUID: DuplicateAction]
    ) async {
        do {
            let importer = MboxImporter(
                context: PersistenceController.shared.viewContext,
                options: .default
            )
            let result = try await importer.executeImport(
                preview,
                to: state.mboxImportTargetLibrary,
                selectedPublications: selectedIDs,
                duplicateDecisions: duplicateDecisions
            )

            await MainActor.run {
                state.mboxImportPreview = nil
                state.mboxImportTargetLibrary = nil

                // Log result
                print("Mbox import: \(result.importedCount) imported, \(result.mergedCount) merged, \(result.skippedCount) skipped")

                if !result.errors.isEmpty {
                    state.mboxExportError = "Import completed with \(result.errors.count) error(s)"
                    state.showMboxExportError = true
                }
            }
        } catch {
            await MainActor.run {
                state.mboxExportError = "Import failed: \(error.localizedDescription)"
                state.showMboxExportError = true
            }
        }
    }

    // MARK: - SciX Libraries Section Header

    /// Section header for SciX Libraries with help tooltip
    private var scixLibrariesSectionHeader: some View {
        HStack {
            Text("SciX Libraries")

            Spacer()

            // Help button that opens SciX libraries documentation
            Button {
                if let url = URL(string: "https://ui.adsabs.harvard.edu/help/libraries/") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                }
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Learn about SciX Libraries - click to open help page")
        }
        .help("""
            SciX Libraries are cloud-based collections synced with NASA ADS/SciX.

            • Access your libraries from any device
            • Share and collaborate with other researchers
            • Set operations: union, intersection, difference
            • Citation helper finds related papers

            Click the ? to learn more.
            """)
    }

    // MARK: - SciX Library Row

    @ViewBuilder
    private func scixLibraryRow(for library: CDSciXLibrary) -> some View {
        HStack {
            // Cloud icon (different from local libraries)
            Image(systemName: "cloud")
                .foregroundStyle(.blue)
                .help("Cloud-synced library from NASA ADS/SciX")

            Text(library.displayName)

            Spacer()

            // Permission level indicator
            Image(systemName: library.permissionLevelEnum.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(permissionTooltip(library.permissionLevelEnum))

            // Pending changes indicator
            if library.hasPendingChanges {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Changes pending sync to SciX")
            }

            // Paper count
            if library.documentCount > 0 {
                CountBadge(count: Int(library.documentCount))
            }
        }
        .tag(SidebarSection.scixLibrary(library))
        .contextMenu {
            Button {
                // Open library on SciX/ADS web interface
                if let url = URL(string: "https://ui.adsabs.harvard.edu/user/libraries/\(library.remoteID)") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
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

            if library.canManagePermissions {
                Button {
                    // TODO: Show permissions sheet
                } label: {
                    Label("Share...", systemImage: "person.2")
                }
            }

            if library.permissionLevelEnum == .owner {
                Divider()
                Button(role: .destructive) {
                    // TODO: Show delete confirmation
                } label: {
                    Label("Delete Library", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Library Header Drop Target

    @ViewBuilder
    private func libraryHeaderDropTarget(for library: CDLibrary) -> some View {
        let count = publicationCount(for: library)
        let starredCount = library.isSaveLibrary ? starredPublicationCount(for: library) : 0
        SidebarDropTarget(
            isTargeted: state.dropTargetedLibraryHeader == library.id,
            showPlusBadge: true
        ) {
            HStack {
                Label(library.displayName, systemImage: "building.columns")
                Spacer()
                // Show starred count badge for Save library
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
                if count > 0 {
                    CountBadge(count: count)
                }
            }
        }
        .onDrop(of: DragDropCoordinator.acceptedTypes + [.publicationID], isTargeted: makeLibraryHeaderTargetBinding(library.id)) { providers in
            dragDropLog("📦 DROP on library HEADER '\(library.displayName)' (id: \(library.id.uuidString))")
            dragDropLog("  - Provider count: \(providers.count)")
            for (i, provider) in providers.enumerated() {
                let types = provider.registeredTypeIdentifiers
                dragDropLog("  - Provider[\(i)] types: \(types.joined(separator: ", "))")
            }

            // Auto-expand collapsed library when dropping on header
            if !expandedLibraries.contains(library.id) {
                dragDropLog("  - Auto-expanding library")
                expandedLibraries.insert(library.id)
            }

            // Check for BibTeX/RIS files first - these open import preview
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(Self.bibtexUTI) }) ||
               providers.contains(where: { $0.hasItemConformingToTypeIdentifier(Self.risUTI) }) {
                handleBibTeXDrop(providers, library: library)
            } else if hasFileDrops(providers) {
                dragDropLog("  → Routing to file drop handler")
                handleFileDrop(providers, libraryID: library.id)
            } else {
                dragDropLog("  → Routing to publication drop handler")
                handleDrop(providers: providers) { uuids in
                    dragDropLog("  → handleDrop completed with \(uuids.count) UUIDs")
                    Task { await addPublicationsToLibrary(uuids, library: library) }
                }
            }
            return true
        }
    }

    // MARK: - Collection Drop Target

    @ViewBuilder
    private func collectionDropTarget(for collection: CDCollection) -> some View {
        let count = publicationCount(for: collection)
        let isEditing = state.renamingCollection?.id == collection.id
        if collection.isSmartCollection {
            // Smart collections don't accept drops
            CollectionRow(
                collection: collection,
                count: count,
                isEditing: isEditing,
                onRename: { newName in renameCollection(collection, to: newName) }
            )
        } else {
            // Static collections accept drops (publications and files)
            SidebarDropTarget(
                isTargeted: state.dropTargetedCollection == collection.id,
                showPlusBadge: true
            ) {
                CollectionRow(
                    collection: collection,
                    count: count,
                    isEditing: isEditing,
                    onRename: { newName in renameCollection(collection, to: newName) }
                )
            }
            .onDrop(of: DragDropCoordinator.acceptedTypes + [.publicationID], isTargeted: makeCollectionTargetBinding(collection.id)) { providers in
                dragDropLog("📦 DROP on collection '\(collection.name)' (id: \(collection.id.uuidString))")
                dragDropLog("  - Provider count: \(providers.count)")
                for (i, provider) in providers.enumerated() {
                    let types = provider.registeredTypeIdentifiers
                    dragDropLog("  - Provider[\(i)] types: \(types.joined(separator: ", "))")
                }

                let libraryID = collection.effectiveLibrary?.id ?? collection.library?.id ?? UUID()
                dragDropLog("  - Effective library ID: \(libraryID.uuidString)")

                if hasFileDrops(providers) {
                    dragDropLog("  → Routing to file drop handler")
                    handleFileDropOnCollection(providers, collectionID: collection.id, libraryID: libraryID)
                } else {
                    dragDropLog("  → Routing to publication drop handler")
                    handleDrop(providers: providers) { uuids in
                        dragDropLog("  → handleDrop completed with \(uuids.count) UUIDs")
                        Task { await addPublications(uuids, to: collection) }
                    }
                }
                return true
            }
        }
    }

    // MARK: - Drop Target Bindings

    private func makeLibraryTargetBinding(_ libraryID: UUID) -> Binding<Bool> {
        Binding(
            get: { state.dropTargetedLibrary == libraryID },
            set: { isTargeted in
                state.dropTargetedLibrary = isTargeted ? libraryID : nil
            }
        )
    }

    private func makeLibraryHeaderTargetBinding(_ libraryID: UUID) -> Binding<Bool> {
        Binding(
            get: { state.dropTargetedLibraryHeader == libraryID },
            set: { isTargeted in
                state.dropTargetedLibraryHeader = isTargeted ? libraryID : nil
                // Auto-expand after hovering for a moment
                if isTargeted && !expandedLibraries.contains(libraryID) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if state.dropTargetedLibraryHeader == libraryID {
                            expandedLibraries.insert(libraryID)
                        }
                    }
                }
            }
        )
    }

    private func makeCollectionTargetBinding(_ collectionID: UUID) -> Binding<Bool> {
        Binding(
            get: { state.dropTargetedCollection == collectionID },
            set: { isTargeted in
                state.dropTargetedCollection = isTargeted ? collectionID : nil
            }
        )
    }

    // MARK: - Drop Handler

    private func handleDrop(providers: [NSItemProvider], action: @escaping ([UUID]) -> Void) {
        dragDropLog("🔄 handleDrop started with \(providers.count) providers")
        var collectedUUIDs: [UUID] = []
        let group = DispatchGroup()
        var loadAttempts = 0

        for (index, provider) in providers.enumerated() {
            // Try to load as our custom publication ID type
            let hasPublicationID = provider.hasItemConformingToTypeIdentifier(UTType.publicationID.identifier)
            dragDropLog("  Provider[\(index)] hasPublicationID: \(hasPublicationID)")

            if hasPublicationID {
                loadAttempts += 1
                group.enter()
                dragDropLog("  Provider[\(index)] loading data representation...")
                provider.loadDataRepresentation(forTypeIdentifier: UTType.publicationID.identifier) { data, error in
                    defer { group.leave() }
                    if let error = error {
                        dragDropError("  ❌ Provider[\(index)] load error: \(error.localizedDescription)")
                        return
                    }
                    if let data = data {
                        dragDropLog("  Provider[\(index)] received \(data.count) bytes")
                        // Log raw data for debugging
                        if let dataString = String(data: data, encoding: .utf8) {
                            dragDropLog("  Provider[\(index)] raw data: \(dataString)")
                        }
                        // UUID is encoded as JSON via CodableRepresentation
                        if let uuid = try? JSONDecoder().decode(UUID.self, from: data) {
                            dragDropLog("  ✅ Provider[\(index)] decoded UUID: \(uuid.uuidString)")
                            collectedUUIDs.append(uuid)
                        } else {
                            dragDropError("  ❌ Provider[\(index)] failed to decode UUID from data")
                        }
                    } else {
                        dragDropError("  ❌ Provider[\(index)] received nil data")
                    }
                }
            }
        }

        dragDropLog("  Initiated \(loadAttempts) load attempts, waiting for completion...")

        group.notify(queue: .main) {
            dragDropLog("  DispatchGroup completed - collected \(collectedUUIDs.count) UUIDs")
            if !collectedUUIDs.isEmpty {
                dragDropLog("  Calling action with UUIDs: \(collectedUUIDs.map { $0.uuidString })")
                action(collectedUUIDs)
            } else {
                dragDropWarning("  ⚠️ No UUIDs collected, action will NOT be called")
            }
        }
    }

    /// BibTeX UTType identifier
    private static let bibtexUTI = "org.tug.tex.bibtex"
    /// RIS UTType identifier
    private static let risUTI = "com.clarivate.ris"

    /// Check if providers contain file drops (PDF, .bib, .ris)
    private func hasFileDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ||
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) ||
            provider.hasItemConformingToTypeIdentifier(Self.risUTI)
        }
    }

    /// Check if providers contain BibTeX or RIS file drops
    private func hasBibTeXOrRISDrops(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) ||
            provider.hasItemConformingToTypeIdentifier(Self.risUTI) ||
            // Also check for generic file URLs with .bib or .ris extension
            provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier)
        }
    }

    /// Handle BibTeX/RIS file drops - opens import preview with target library pre-selected
    private func handleBibTeXDrop(_ providers: [NSItemProvider], library: CDLibrary) {
        dragDropLog("  → Routing to BibTeX import handler")

        // Try to load the file URL from the provider
        for provider in providers {
            // First try BibTeX type
            if provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) {
                provider.loadItem(forTypeIdentifier: Self.bibtexUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url, "library": library]
                            )
                        }
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url, "library": library]
                            )
                        }
                    }
                }
                return
            }

            // Try RIS type
            if provider.hasItemConformingToTypeIdentifier(Self.risUTI) {
                provider.loadItem(forTypeIdentifier: Self.risUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .importBibTeXToLibrary,
                                object: nil,
                                userInfo: ["fileURL": url, "library": library]
                            )
                        }
                    }
                }
                return
            }

            // Try generic file URL
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
                                userInfo: ["fileURL": url, "library": library]
                            )
                        }
                    }
                }
                return
            }
        }
    }

    /// Handle BibTeX/RIS file drops on sidebar background (not on a specific library)
    /// Opens import preview with "Create new library" pre-selected and filename as suggestion
    private func handleBibTeXDropForNewLibrary(_ providers: [NSItemProvider]) {
        dragDropLog("  → Routing to BibTeX import handler (new library)")

        for provider in providers {
            // Try BibTeX type
            if provider.hasItemConformingToTypeIdentifier(Self.bibtexUTI) {
                provider.loadItem(forTypeIdentifier: Self.bibtexUTI, options: nil) { item, error in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            // Post with no library - ContentView will default to "create new library"
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

            // Try RIS type
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

            // Try generic file URL
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

    /// Handle file drops on a library target
    private func handleFileDrop(_ providers: [NSItemProvider], libraryID: UUID) {
        let info = DragDropInfo(providers: providers)
        let target = DropTarget.library(libraryID: libraryID)
        Task {
            let result = await dragDropCoordinator.performDrop(info, target: target)
            if case .needsConfirmation = result {
                await MainActor.run {
                    state.showDropPreview(for: libraryID)
                }
            }
        }
    }

    /// Handle file drops on a collection target
    private func handleFileDropOnCollection(_ providers: [NSItemProvider], collectionID: UUID, libraryID: UUID) {
        let info = DragDropInfo(providers: providers)
        let target = DropTarget.collection(collectionID: collectionID, libraryID: libraryID)
        Task {
            let result = await dragDropCoordinator.performDrop(info, target: target)
            if case .needsConfirmation = result {
                await MainActor.run {
                    state.showDropPreview(for: libraryID)
                }
            }
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 16) {
            Button {
                state.showNewLibrary()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add Library")
            .accessibilityIdentifier(AccessibilityID.Sidebar.newLibraryButton)

            Button {
                if let library = selectedLibrary {
                    state.libraryToDelete = library
                    state.showDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selectedLibrary == nil)
            .help("Remove Library")
            .accessibilityIdentifier(AccessibilityID.Toolbar.removeButton)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .buttonStyle(.borderless)
    }

    // MARK: - Inbox Section

    /// Inbox section content (without Section wrapper)
    @ViewBuilder
    private var inboxSectionContent: some View {
        // Inbox header with unread badge
        HStack {
            Label("All Publications", systemImage: "tray.full")
            Spacer()
            if inboxUnreadCount > 0 {
                Text("\(inboxUnreadCount)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .tag(SidebarSection.inbox)
        .accessibilityIdentifier(AccessibilityID.Sidebar.inbox)

        // Inbox feeds (smart searches with feedsToInbox)
        ForEach(inboxFeeds, id: \.id) { feed in
            HStack {
                Label(feed.name, systemImage: "antenna.radiowaves.left.and.right")
                    .help(tooltipForFeed(feed))
                Spacer()
                // Show unread count for this feed
                let unreadCount = unreadCountForFeed(feed)
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .tag(SidebarSection.inboxFeed(feed))
            .contextMenu {
                Button("Refresh Now") {
                    Task {
                        await refreshInboxFeed(feed)
                    }
                }
                if let (url, label) = webURL(for: feed) {
                    Button(label) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Edit") {
                    // Check feed type and route to appropriate editor
                    if feed.isGroupFeed {
                        // Navigate to Group arXiv Feed form
                        selection = .searchForm(.arxivGroupFeed)
                        // Delay notification to ensure view is mounted
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NotificationCenter.default.post(name: .editGroupArXivFeed, object: feed)
                        }
                    } else if isArXivCategoryFeed(feed) {
                        // Navigate to arXiv Feed form
                        selection = .searchForm(.arxivFeed)
                        // Delay notification to ensure view is mounted
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NotificationCenter.default.post(name: .editArXivFeed, object: feed)
                        }
                    } else {
                        // Navigate to Search section with this feed's query
                        NotificationCenter.default.post(name: .editSmartSearch, object: feed.id)
                    }
                }
                Divider()
                Button("Remove from Inbox", role: .destructive) {
                    removeFromInbox(feed)
                }
            }
        }
    }

    /// Get all smart searches that feed to the Inbox
    private var inboxFeeds: [CDSmartSearch] {
        // Fetch all smart searches with feedsToInbox enabled
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.predicate = NSPredicate(format: "feedsToInbox == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        do {
            return try PersistenceController.shared.viewContext.fetch(request)
        } catch {
            return []
        }
    }

    /// Get unread count for the Inbox
    private var inboxUnreadCount: Int {
        InboxManager.shared.unreadCount
    }

    /// Get unread count for a specific inbox feed
    private func unreadCountForFeed(_ feed: CDSmartSearch) -> Int {
        guard let collection = feed.resultCollection,
              let publications = collection.publications else {
            return 0
        }
        return publications.filter { !$0.isRead && !$0.isDeleted }.count
    }

    /// Generate tooltip text for a feed
    private func tooltipForFeed(_ feed: CDSmartSearch) -> String {
        if feed.isGroupFeed {
            // Group feed: show authors and categories
            let authors = feed.groupFeedAuthors()
            let categories = feed.groupFeedCategories()

            var lines: [String] = []

            if !authors.isEmpty {
                lines.append("Authors:")
                for author in authors {
                    lines.append("  • \(author)")
                }
            }

            if !categories.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Categories:")
                for category in categories.sorted() {
                    lines.append("  • \(category)")
                }
            }

            return lines.isEmpty ? "Group feed" : lines.joined(separator: "\n")
        } else if isArXivCategoryFeed(feed) {
            // arXiv category feed: show categories from query
            let categories = parseArXivCategories(from: feed.query)
            if categories.isEmpty {
                return "arXiv category feed"
            }
            var lines = ["Categories:"]
            for category in categories.sorted() {
                lines.append("  • \(category)")
            }
            return lines.joined(separator: "\n")
        } else {
            // Regular smart search: show query
            return "Query: \(feed.query)"
        }
    }

    /// Parse arXiv categories from a category feed query
    private func parseArXivCategories(from query: String) -> [String] {
        // Category feeds typically have queries like: cat:astro-ph.GA OR cat:astro-ph.CO
        var categories: [String] = []
        let pattern = #"cat:([a-zA-Z\-]+\.[A-Z]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(query.startIndex..., in: query)
            let matches = regex.matches(in: query, options: [], range: range)
            for match in matches {
                if let catRange = Range(match.range(at: 1), in: query) {
                    categories.append(String(query[catRange]))
                }
            }
        }
        return categories
    }

    /// Refresh a specific inbox feed
    private func refreshInboxFeed(_ feed: CDSmartSearch) async {
        guard let scheduler = await InboxCoordinator.shared.scheduler else { return }
        do {
            _ = try await scheduler.refreshFeed(feed)
            await MainActor.run {
                state.triggerRefresh()
            }
        } catch {
            // Handle error silently for now
        }
    }

    /// Remove a feed from Inbox (disable feedsToInbox)
    private func removeFromInbox(_ feed: CDSmartSearch) {
        feed.feedsToInbox = false
        feed.autoRefreshEnabled = false
        try? feed.managedObjectContext?.save()
        state.triggerRefresh()
    }

    /// Check if a feed is an arXiv category feed (query contains only cat: patterns)
    private func isArXivCategoryFeed(_ feed: CDSmartSearch) -> Bool {
        let query = feed.query
        // arXiv feeds use only "arxiv" source and have cat: patterns in their query
        guard feed.sources == ["arxiv"] else { return false }
        guard query.contains("cat:") else { return false }

        // Check that the query is primarily category-based (no search terms like ti:, au:, abs:)
        let hasSearchTerms = query.contains("ti:") || query.contains("au:") ||
                             query.contains("abs:") || query.contains("co:") ||
                             query.contains("jr:") || query.contains("rn:") ||
                             query.contains("id:") || query.contains("doi:")
        return !hasSearchTerms
    }

    /// Construct an arXiv web URL for a feed.
    ///
    /// For category feeds (e.g., "cat:astro-ph.GA"), opens the category listing page.
    /// For other arXiv searches, opens the search results page.
    private func arXivWebURL(for feed: CDSmartSearch) -> URL? {
        guard feed.sources == ["arxiv"] else { return nil }

        let query = feed.query

        // Extract category from "cat:xxx" pattern for category feeds
        if isArXivCategoryFeed(feed) {
            // Extract first category from query like "(cat:astro-ph.GA OR cat:astro-ph.CO)"
            let pattern = #"cat:([^\s()]+)"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                let category = String(query[range])
                return URL(string: "https://arxiv.org/list/\(category)/recent")
            }
        }

        // For general arXiv searches, use the search page
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://arxiv.org/search/?query=\(encodedQuery)&searchtype=all")
        }

        return nil
    }

    /// Construct an ADS web URL for a feed or search.
    ///
    /// Opens the search results page on the ADS web interface.
    private func adsWebURL(for feed: CDSmartSearch) -> URL? {
        guard feed.sources == ["ads"] else { return nil }

        let query = feed.query
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://ui.adsabs.harvard.edu/search/q=\(encodedQuery)")
        }

        return nil
    }

    /// Construct a SciX web URL for a feed or search.
    ///
    /// Opens the search results page on the SciX web interface.
    private func sciXWebURL(for feed: CDSmartSearch) -> URL? {
        guard feed.sources == ["scix"] else { return nil }

        let query = feed.query
        if let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://www.scixplorer.org/search/q=\(encodedQuery)")
        }

        return nil
    }

    /// Get the appropriate web URL for any supported feed.
    ///
    /// Returns the web URL for arXiv, ADS, or SciX feeds based on their source.
    private func webURL(for feed: CDSmartSearch) -> (url: URL, label: String)? {
        if let url = arXivWebURL(for: feed) {
            return (url, "Open on arXiv")
        }
        if let url = adsWebURL(for: feed) {
            return (url, "Open on ADS")
        }
        if let url = sciXWebURL(for: feed) {
            return (url, "Open on SciX")
        }
        return nil
    }

    // MARK: - Helpers

    /// Convert permission level to tooltip string
    private func permissionTooltip(_ level: CDSciXLibrary.PermissionLevel) -> String {
        switch level {
        case .owner: return "Owner"
        case .admin: return "Admin"
        case .write: return "Can edit"
        case .read: return "Read only"
        }
    }

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

    /// Get the currently selected library from the selection
    private var selectedLibrary: CDLibrary? {
        switch selection {
        case .inbox:
            return InboxManager.shared.inboxLibrary
        case .inboxFeed(let feed):
            return feed.library ?? InboxManager.shared.inboxLibrary
        case .library(let library):
            return library
        case .smartSearch(let smartSearch):
            return smartSearch.library
        case .collection(let collection):
            return collection.library
        default:
            return nil
        }
    }

    private func publicationCount(for library: CDLibrary) -> Int {
        allPublications(for: library).count
    }

    /// Get count of starred publications in a library.
    private func starredPublicationCount(for library: CDLibrary) -> Int {
        allPublications(for: library).filter { $0.isStarred }.count
    }

    /// Get all publications for a library.
    ///
    /// Simplified: All papers are in `library.publications` (smart search results included).
    private func allPublications(for library: CDLibrary) -> Set<CDPublication> {
        (library.publications ?? []).filter { !$0.isDeleted }
    }

    private func publicationCount(for collection: CDCollection) -> Int {
        // Use matchingPublicationCount which handles both static and smart collections
        collection.matchingPublicationCount
    }

    private func resultCount(for smartSearch: CDSmartSearch) -> Int {
        smartSearch.resultCollection?.publications?.count ?? 0
    }

    // MARK: - Smart Search Management

    private func deleteSmartSearch(_ smartSearch: CDSmartSearch) {
        // Clear selection BEFORE deletion to prevent accessing deleted object
        if case .smartSearch(let selected) = selection, selected.id == smartSearch.id {
            selection = nil
        }

        let searchID = smartSearch.id
        SmartSearchRepository.shared.delete(smartSearch)
        Task {
            await SmartSearchProviderCache.shared.invalidate(searchID)
        }
    }

    // MARK: - Collection Management

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
            state.triggerRefresh()
        }
    }

    private func createStaticCollection(in library: CDLibrary, parent: CDCollection? = nil) {
        let context = library.managedObjectContext ?? PersistenceController.shared.viewContext
        let collection = CDCollection(context: context)
        collection.id = UUID()
        collection.name = parent != nil ? "New Subcollection" : "New Collection"
        collection.isSmartCollection = false
        collection.library = library
        collection.parentCollection = parent
        try? context.save()

        // Expand parent when creating subcollection
        if let parent = parent {
            var expanded = state.expandedLibraryCollections[library.id] ?? []
            expanded.insert(parent.id)
            state.expandedLibraryCollections[library.id] = expanded
        }

        // Trigger sidebar refresh and enter rename mode
        state.triggerRefresh()
        state.renamingCollection = collection
    }

    private func renameCollection(_ collection: CDCollection, to newName: String) {
        guard !newName.isEmpty else {
            state.renamingCollection = nil
            return
        }
        collection.name = newName
        try? collection.managedObjectContext?.save()
        state.renamingCollection = nil
        state.triggerRefresh()
    }

    private func updateCollection(_ collection: CDCollection, name: String, predicate: String) async {
        collection.name = name
        collection.predicate = predicate
        try? collection.managedObjectContext?.save()
    }

    private func deleteCollection(_ collection: CDCollection) {
        // Clear selection BEFORE deletion to prevent accessing deleted object
        if case .collection(let selected) = selection, selected.id == collection.id {
            selection = nil
        }

        guard let context = collection.managedObjectContext else { return }
        context.delete(collection)
        try? context.save()
    }

    /// Move a collection to a new parent (or to root if newParent is nil)
    private func moveCollection(_ collection: CDCollection, to newParent: CDCollection?, in library: CDLibrary) {
        // Don't allow moving to itself
        guard collection.id != newParent?.id else { return }

        // Don't allow moving a parent into its descendant (would create cycle)
        if let newParent = newParent {
            if newParent.ancestors.contains(where: { $0.id == collection.id }) {
                return
            }
        }

        collection.parentCollection = newParent
        try? collection.managedObjectContext?.save()

        // Expand the new parent to show the moved collection
        if let newParent = newParent {
            var expanded = state.expandedLibraryCollections[library.id] ?? []
            expanded.insert(newParent.id)
            state.expandedLibraryCollections[library.id] = expanded
        }

        state.triggerRefresh()
    }

    /// Handle dropping a collection to the root level (remove parent)
    private func handleCollectionDropToRoot(providers: [NSItemProvider], library: CDLibrary) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.collectionID.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.collectionID.identifier, options: nil) { data, _ in
                    guard let data = data as? Data,
                          let idString = String(data: data, encoding: .utf8),
                          let draggedID = UUID(uuidString: idString) else { return }

                    // Find the dragged collection
                    guard let collections = library.collections as? Set<CDCollection>,
                          let draggedCollection = collections.first(where: { $0.id == draggedID }) else { return }

                    Task { @MainActor in
                        moveCollection(draggedCollection, to: nil, in: library)
                    }
                }
                return true
            }
        }
        return false
    }

    // MARK: - Library Management

    private func deleteLibrary(_ library: CDLibrary) {
        // Clear selection BEFORE deletion if ANY item from this library is selected
        if let currentSelection = selection {
            switch currentSelection {
            case .inbox, .inboxFeed:
                break  // Inbox is not affected by library deletion
            case .library(let lib):
                if lib.id == library.id { selection = nil }
            case .smartSearch(let ss):
                if ss.library?.id == library.id { selection = nil }
            case .collection(let col):
                if col.library?.id == library.id { selection = nil }
            case .search, .searchForm, .scixLibrary:
                break  // Not affected by library deletion
            }
        }

        try? libraryManager.deleteLibrary(library, deleteFiles: false)
    }

    // MARK: - Drop Handlers

    /// Add publications to a static collection (also adds to the collection's owning library)
    private func addPublications(_ uuids: [UUID], to collection: CDCollection) async {
        guard !collection.isSmartCollection else { return }
        let context = PersistenceController.shared.viewContext

        await context.perform {
            for uuid in uuids {
                let request = NSFetchRequest<CDPublication>(entityName: "Publication")
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                request.fetchLimit = 1

                if let publication = try? context.fetch(request).first {
                    // Add to collection
                    var current = collection.publications ?? []
                    current.insert(publication)
                    collection.publications = current

                    // Also add to the collection's library
                    if let collectionLibrary = collection.effectiveLibrary {
                        publication.addToLibrary(collectionLibrary)
                    }
                }
            }
            try? context.save()
        }

        // Trigger sidebar refresh to update counts
        await MainActor.run {
            state.triggerRefresh()
        }
    }

    /// Add publications to a library (publications can belong to multiple libraries)
    private func addPublicationsToLibrary(_ uuids: [UUID], library: CDLibrary) async {
        dragDropLog("📚 addPublicationsToLibrary called")
        dragDropLog("  - Target library: '\(library.displayName)' (id: \(library.id.uuidString))")
        dragDropLog("  - UUIDs to add: \(uuids.count)")

        let context = PersistenceController.shared.viewContext
        var addedCount = 0
        var notFoundCount = 0

        await context.perform {
            for uuid in uuids {
                let request = NSFetchRequest<CDPublication>(entityName: "Publication")
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                request.fetchLimit = 1

                if let publication = try? context.fetch(request).first {
                    dragDropLog("  ✅ Found publication '\(publication.citeKey)' for UUID \(uuid.uuidString)")
                    let beforeCount = publication.libraries?.count ?? 0
                    publication.addToLibrary(library)
                    let afterCount = publication.libraries?.count ?? 0
                    dragDropLog("    Libraries before: \(beforeCount), after: \(afterCount)")
                    addedCount += 1
                } else {
                    dragDropError("  ❌ No publication found for UUID \(uuid.uuidString)")
                    notFoundCount += 1
                }
            }

            do {
                try context.save()
                dragDropLog("  ✅ Context saved successfully")
            } catch {
                dragDropError("  ❌ Context save failed: \(error.localizedDescription)")
            }
        }

        dragDropLog("  Summary: added \(addedCount), not found \(notFoundCount)")

        // Trigger sidebar refresh to update counts
        await MainActor.run {
            dragDropLog("  🔄 Triggering sidebar refresh")
            state.triggerRefresh()
        }
    }
}

// MARK: - Count Badge

struct CountBadge: View {
    let count: Int
    var color: Color = .secondary

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Smart Search Row

struct SmartSearchRow: View {
    let smartSearch: CDSmartSearch
    var count: Int = 0

    var body: some View {
        HStack {
            Label(smartSearch.name, systemImage: "magnifyingglass.circle.fill")
                .help(smartSearch.query)  // Show query on hover
            Spacer()
            if count > 0 {
                CountBadge(count: count)
            }
        }
    }
}

// MARK: - Collection Row

struct CollectionRow: View {
    @ObservedObject var collection: CDCollection
    var count: Int = 0
    var isEditing: Bool = false
    var onRename: ((String) -> Void)?

    @State private var editedName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Label {
                if isEditing {
                    TextField("Collection Name", text: $editedName)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onSubmit {
                            onRename?(editedName)
                        }
                        .onExitCommand {
                            // Cancel on Escape
                            onRename?(collection.name)
                        }
                } else {
                    Text(collection.name)
                }
            } icon: {
                Image(systemName: collection.isSmartCollection ? "folder.badge.gearshape" : "folder")
                    .help(collection.isSmartCollection ? "Smart collection - auto-populated by filter rules" : "Collection")
            }
            Spacer()
            if count > 0 {
                CountBadge(count: count)
            }
        }
        .onChange(of: isEditing) { _, newValue in
            if newValue {
                editedName = collection.name
                // Delay focus to ensure TextField is rendered and List doesn't intercept
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isFocused = true
                }
            }
        }
    }
}

// MARK: - Sidebar Drop Target

/// A view wrapper that provides visual feedback for drag and drop targets
struct SidebarDropTarget<Content: View>: View {
    let isTargeted: Bool
    let showPlusBadge: Bool
    @ViewBuilder let content: () -> Content

    init(
        isTargeted: Bool,
        showPlusBadge: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isTargeted = isTargeted
        self.showPlusBadge = showPlusBadge
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) {
            content()

            Spacer()

            // Green plus badge when targeted
            if isTargeted && showPlusBadge {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.2) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .contentShape(Rectangle())
    }
}

// MARK: - New Library Sheet

struct NewLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryManager.self) private var libraryManager

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Library Name") {
                    TextField("Name", text: $name, prompt: Text("My Library"))
                }

                Section {
                    Text("Your library will sync across all your devices via iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Library")
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 160)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createLibrary()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }

    private func createLibrary() {
        let libraryName = name.isEmpty ? "New Library" : name
        _ = libraryManager.createLibrary(name: libraryName)
        dismiss()
    }
}

#Preview {
    SidebarView(selection: .constant(nil), expandedLibraries: .constant([]))
        .environment(LibraryManager(persistenceController: .preview))
}
