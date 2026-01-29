//
//  UnifiedPublicationListWrapper.swift
//  imbib
//
//  Created by Claude on 2026-01-05.
//

import SwiftUI
import PublicationManagerCore
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "publicationlist")

// MARK: - Publication Source

/// The data source for publications in the unified list view.
enum PublicationSource: Hashable {
    case library(CDLibrary)
    case smartSearch(CDSmartSearch)

    var id: UUID {
        switch self {
        case .library(let library): return library.id
        case .smartSearch(let smartSearch): return smartSearch.id
        }
    }

    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }

    var isSmartSearch: Bool {
        if case .smartSearch = self { return true }
        return false
    }
}

// MARK: - Filter Mode

/// Filter mode for the publication list.
enum LibraryFilterMode: String, CaseIterable {
    case all
    case unread
}

// Note: SmartSearchProviderCache is now in PublicationManagerCore

// MARK: - Unified Publication List Wrapper

/// A unified wrapper view that displays publications from either a library or a smart search.
///
/// This view uses the same @State + explicit refresh pattern for both sources,
/// ensuring consistent behavior and immediate UI updates after mutations.
///
/// Features (same for both sources):
/// - @State publications with explicit refresh
/// - All/Unread filter (via Cmd+\\ keyboard shortcut)
/// - Refresh button (library = future enrichment, smart search = re-search)
/// - Loading/error states
/// - OSLog logging
struct UnifiedPublicationListWrapper: View {

    // MARK: - Properties

    let source: PublicationSource
    @Binding var selectedPublication: CDPublication?
    /// Multi-selection IDs for bulk operations
    @Binding var selectedPublicationIDs: Set<UUID>

    /// Initial filter mode (for Unread sidebar item)
    var initialFilterMode: LibraryFilterMode = .all

    /// Called when "Download PDFs" is requested for selected publications
    var onDownloadPDFs: ((Set<UUID>) -> Void)?

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Unified State

    @State private var publications: [CDPublication] = []
    // selectedPublicationIDs is now a binding: selectedPublicationIDs
    @State private var isLoading = false
    @State private var error: Error?
    @State private var filterMode: LibraryFilterMode = .all
    @State private var filterScope: FilterScope = .current
    @State private var provider: SmartSearchProvider?
    @State private var dropHandler = FileDropHandler()

    // Drop preview sheet state (for list background drops)
    private let dragDropCoordinator = DragDropCoordinator.shared
    @State private var showingDropPreview = false
    @State private var dropPreviewTargetLibraryID: UUID?

    /// Whether a background refresh is in progress (for subtle UI indicator)
    @State private var isBackgroundRefreshing = false

    /// Mapping of publication ID to library name for grouped search display
    @State private var libraryNameMapping: [UUID: String] = [:]

    /// Triage flash state for keyboard shortcuts (K/D keys)
    @State private var keyboardTriageFlash: (id: UUID, color: Color)?

    /// Current sort order - owned by wrapper for synchronous visual order computation.
    @State private var currentSortOrder: LibrarySortOrder = .dateAdded
    @State private var currentSortAscending: Bool = false

    /// ADR-020: Recommendation scores for sorted display.
    /// Owned by wrapper to ensure synchronous access during triage.
    @State private var recommendationScores: [UUID: Double] = [:]
    @State private var serendipitySlotIDs: Set<UUID> = []
    @State private var isComputingRecommendations: Bool = false

    // State for duplicate file alert
    @State private var showDuplicateAlert = false
    @State private var duplicateFilename = ""

    /// Snapshot of publication IDs visible when unread filter was applied.
    /// Enables Apple Mail behavior: items stay visible after being marked as read
    /// until the user navigates away or explicitly refreshes.
    @State private var unreadFilterSnapshot: Set<UUID>?

    // MARK: - Computed Properties

    /// Check if the source (library or smart search) is still valid (not deleted)
    private var isSourceValid: Bool {
        switch source {
        case .library(let library):
            return library.managedObjectContext != nil && !library.isDeleted
        case .smartSearch(let smartSearch):
            return smartSearch.managedObjectContext != nil && !smartSearch.isDeleted
        }
    }

    private var navigationTitle: String {
        switch source {
        case .library(let library):
            guard library.managedObjectContext != nil else { return "" }
            return filterMode == .unread ? "Unread" : library.displayName
        case .smartSearch(let smartSearch):
            guard smartSearch.managedObjectContext != nil else { return "" }
            return smartSearch.name
        }
    }

    private var currentLibrary: CDLibrary? {
        guard isSourceValid else { return nil }
        switch source {
        case .library(let library):
            return library
        case .smartSearch(let smartSearch):
            return smartSearch.resultCollection?.library ?? smartSearch.library
        }
    }

    private var listID: ListViewID {
        switch source {
        case .library(let library):
            return .library(library.id)
        case .smartSearch(let smartSearch):
            return .smartSearch(smartSearch.id)
        }
    }

    private var emptyMessage: String {
        switch source {
        case .library:
            return "No Publications"
        case .smartSearch(let smartSearch):
            return "No Results for \"\(smartSearch.query)\""
        }
    }

    private var emptyDescription: String {
        switch source {
        case .library:
            return "Add publications to your library or search online sources."
        case .smartSearch:
            return "Click refresh to search again."
        }
    }

    // MARK: - Body

    /// Check if we're viewing the Inbox library or an Inbox feed
    private var isInboxView: Bool {
        guard isSourceValid else { return false }
        switch source {
        case .library(let library):
            return library.isInbox
        case .smartSearch(let smartSearch):
            // Inbox feeds also support triage shortcuts
            return smartSearch.feedsToInbox
        }
    }

    var body: some View {
        // Guard against deleted source - return empty view to prevent crash
        if !isSourceValid {
            Color.clear
        } else {
            bodyContent
        }
    }

    /// Main body content separated to help compiler type-checking
    @ViewBuilder
    private var bodyContent: some View {
        contentView
            .navigationTitle(navigationTitle)
            .toolbar { toolbarContent }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress { press in handleVimNavigation(press) }
            .onKeyPress(.init("d")) { handleDismissKey() }
            .task(id: source.id) {
                filterMode = initialFilterMode
                filterScope = .current  // Reset scope on navigation
                unreadFilterSnapshot = nil  // Reset snapshot on navigation

                // If starting with unread filter, capture snapshot after loading data
                if initialFilterMode == .unread {
                    refreshPublicationsList()
                    unreadFilterSnapshot = captureUnreadSnapshot()
                } else {
                    refreshPublicationsList()
                }

                if case .smartSearch(let smartSearch) = source {
                    await queueBackgroundRefreshIfNeeded(smartSearch)
                }
            }
            .onChange(of: filterMode) { _, newMode in
                // Capture snapshot when switching TO unread filter (Apple Mail behavior)
                if newMode == .unread {
                    unreadFilterSnapshot = captureUnreadSnapshot()
                } else {
                    unreadFilterSnapshot = nil
                }
                refreshPublicationsList()
            }
            .onChange(of: filterScope) { _, _ in
                refreshPublicationsList()
            }
            .modifier(NotificationModifiers(
                onToggleReadStatus: toggleReadStatusForSelected,
                onCopyPublications: { Task { await copySelectedPublications() } },
                onCutPublications: { Task { await cutSelectedPublications() } },
                onPastePublications: {
                    Task {
                        try? await libraryViewModel.pasteFromClipboard()
                        refreshPublicationsList()
                    }
                },
                onSelectAll: selectAllPublications
            ))
            .modifier(SmartSearchRefreshModifier(
                source: source,
                onRefreshComplete: { smartSearchName in
                    logger.info("Background refresh completed for '\(smartSearchName)', refreshing UI")
                    isBackgroundRefreshing = false
                    refreshPublicationsList()
                }
            ))
            .modifier(InboxTriageModifier(
                isInboxView: isInboxView,
                hasSelection: !selectedPublicationIDs.isEmpty,
                onSave: saveSelectedToDefaultLibrary,
                onSaveAndStar: saveAndStarSelected,
                onToggleStar: toggleStarForSelected,
                onDismiss: dismissSelectedFromInbox
            ))
            .alert("Duplicate File", isPresented: $showDuplicateAlert) {
                Button("Skip") {
                    dropHandler.resolveDuplicate(proceed: false)
                }
                Button("Attach Anyway") {
                    dropHandler.resolveDuplicate(proceed: true)
                }
            } message: {
                Text("This file is identical to '\(duplicateFilename)' which is already attached. Do you want to attach it anyway?")
            }
            .onChange(of: dropHandler.pendingDuplicate) { _, newValue in
                if let pending = newValue {
                    duplicateFilename = pending.existingFilename
                    showDuplicateAlert = true
                }
            }
            .onChange(of: dragDropCoordinator.pendingPreview) { _, newValue in
                // Dismiss the sheet when pendingPreview becomes nil (import completed or cancelled)
                if newValue == nil && showingDropPreview {
                    showingDropPreview = false
                }
            }
            .sheet(isPresented: $showingDropPreview) {
                dropPreviewSheetContent
            }
    }

    // MARK: - Drop Preview Sheet

    /// Drop preview sheet content for list background drops
    @ViewBuilder
    private var dropPreviewSheetContent: some View {
        @Bindable var coordinator = dragDropCoordinator
        if let libraryID = dropPreviewTargetLibraryID {
            DropPreviewSheet(
                preview: $coordinator.pendingPreview,
                libraryID: libraryID,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                dropPreviewTargetLibraryID = nil
                refreshPublicationsList()
            }
        } else if let library = currentLibrary {
            // Fallback: use current library
            DropPreviewSheet(
                preview: $coordinator.pendingPreview,
                libraryID: library.id,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                refreshPublicationsList()
            }
        } else if let firstLibrary = libraryManager.libraries.first(where: { !$0.isInbox && !$0.isSystemLibrary }) {
            // Fallback: use first user library
            DropPreviewSheet(
                preview: $coordinator.pendingPreview,
                libraryID: firstLibrary.id,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                refreshPublicationsList()
            }
        } else {
            // No libraries available
            VStack {
                Text("No Library Available")
                    .font(.headline)
                Text("Create a library first to import PDFs.")
                    .foregroundStyle(.secondary)
                Button("Close") {
                    showingDropPreview = false
                    dragDropCoordinator.pendingPreview = nil
                }
                .padding(.top)
            }
            .padding()
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        if isLoading && publications.isEmpty {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            errorView(error)
        } else {
            listView
        }
    }

    private func errorView(_ error: Error) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("Retry") {
                Task { await refreshFromNetwork() }
            }
        }
    }

    private var listView: some View {
        PublicationListView(
            publications: publications,
            selection: $selectedPublicationIDs,
            selectedPublication: $selectedPublication,
            library: currentLibrary,
            allLibraries: libraryManager.libraries,
            showImportButton: false,
            showSortMenu: true,
            emptyStateMessage: emptyMessage,
            emptyStateDescription: emptyDescription,
            listID: listID,
            disableUnreadFilter: isInboxView,
            isInInbox: isInboxView,
            saveLibrary: isInboxView ? libraryManager.getOrCreateSaveLibrary() : nil,
            filterScope: $filterScope,
            libraryNameMapping: libraryNameMapping,
            sortOrder: $currentSortOrder,
            sortAscending: $currentSortAscending,
            recommendationScores: $recommendationScores,
            onDelete: { ids in
                // Remove from local state FIRST to prevent SwiftUI from rendering deleted objects
                publications.removeAll { ids.contains($0.id) }
                // Clear selection for deleted items
                selectedPublicationIDs.subtract(ids)
                // Then delete from Core Data
                await libraryViewModel.delete(ids: ids)
                refreshPublicationsList()
            },
            onToggleRead: { publication in
                await libraryViewModel.toggleReadStatus(publication)
                refreshPublicationsList()
            },
            onCopy: { ids in
                await libraryViewModel.copyToClipboard(ids)
            },
            onCut: { ids in
                await libraryViewModel.cutToClipboard(ids)
                refreshPublicationsList()
            },
            onPaste: {
                try? await libraryViewModel.pasteFromClipboard()
                refreshPublicationsList()
            },
            onAddToLibrary: { ids, targetLibrary in
                await libraryViewModel.addToLibrary(ids, library: targetLibrary)
                refreshPublicationsList()
            },
            onAddToCollection: { ids, collection in
                await libraryViewModel.addToCollection(ids, collection: collection)
            },
            onRemoveFromAllCollections: { ids in
                await libraryViewModel.removeFromAllCollections(ids)
            },
            onImport: nil,
            onOpenPDF: { publication in
                openPDF(for: publication)
            },
            onFileDrop: { publication, providers in
                Task {
                    await dropHandler.handleDrop(
                        providers: providers,
                        for: publication,
                        in: currentLibrary
                    )
                    // Refresh to show new attachments (paperclip indicator)
                    refreshPublicationsList()
                }
            },
            onListDrop: { providers, target in
                // Handle PDF drop on list background for import
                logger.info("onListDrop triggered with target: \(String(describing: target))")
                Task {
                    let result = await DragDropCoordinator.shared.performDrop(
                        DragDropInfo(providers: providers),
                        target: target
                    )
                    logger.info("performDrop returned: \(String(describing: result))")
                    if case .needsConfirmation = result {
                        await MainActor.run {
                            // Extract library ID from target for the preview sheet
                            switch target {
                            case .library(let libraryID):
                                logger.info("Setting dropPreviewTargetLibraryID from .library: \(libraryID)")
                                dropPreviewTargetLibraryID = libraryID
                            case .collection(_, let libraryID):
                                logger.info("Setting dropPreviewTargetLibraryID from .collection: \(libraryID)")
                                dropPreviewTargetLibraryID = libraryID
                            case .inbox, .publication, .newLibraryZone:
                                logger.info("Fallback - currentLibrary?.id: \(String(describing: currentLibrary?.id))")
                                // Use current library as fallback
                                dropPreviewTargetLibraryID = currentLibrary?.id
                            }
                            logger.info("Setting showingDropPreview = true")
                            showingDropPreview = true
                        }
                    }
                    refreshPublicationsList()
                }
            },
            onDownloadPDFs: onDownloadPDFs,
            // Keep callback - only available in Inbox (implied once in library)
            onSaveToLibrary: isInboxView ? { ids, targetLibrary in
                await saveToLibrary(ids: ids, targetLibrary: targetLibrary)
            } : nil,
            // Dismiss callback - available for all views (moves papers to dismissed library)
            onDismiss: { ids in
                await dismissFromInbox(ids: ids)
            },
            onToggleStar: { ids in
                await toggleStarForIDs(ids)
            },
            onMuteAuthor: isInboxView ? { authorName in
                muteAuthor(authorName)
            } : nil,
            onMutePaper: isInboxView ? { publication in
                mutePaper(publication)
            } : nil,
            // Refresh callback (shown as small button in list header)
            onRefresh: {
                await refreshFromNetwork()
            },
            isRefreshing: isLoading || isBackgroundRefreshing,
            // External flash trigger for keyboard shortcuts
            externalTriageFlash: $keyboardTriageFlash
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Toolbar is now mostly empty - refresh moved to inline toolbar in list view
        // EmptyView is needed for the ToolbarContentBuilder
        ToolbarItem(placement: .automatic) {
            EmptyView()
        }
    }

    // MARK: - Data Refresh

    /// Refresh publications from data source (synchronous read)
    private func refreshPublicationsList() {
        // Handle cross-scope fetching
        switch filterScope {
        case .current:
            refreshCurrentScopePublications()
        case .allLibraries, .inbox, .everything:
            publications = fetchPublications(for: filterScope)
            logger.info("Refreshed \(filterScope.rawValue): \(self.publications.count) items")
        }
    }

    /// Refresh publications for the current source (library or smart search)
    ///
    /// Simplified: All papers in a library are in `library.publications`.
    /// No merge logic needed - smart search results are added to the library relationship.
    private func refreshCurrentScopePublications() {
        // Clear library name mapping for current scope (no grouped display)
        libraryNameMapping = [:]

        guard isSourceValid else {
            publications = []
            return
        }
        switch source {
        case .library(let library):
            // Simple: just use the library's publications relationship
            // Note: Only filter by isDeleted, not managedObjectContext - during Core Data
            // background merges, managedObjectContext can temporarily be nil even for valid
            // objects, which causes list churn and selection loss
            var result = (library.publications ?? [])
                .filter { !$0.isDeleted }

            // Apply filter mode with Apple Mail behavior:
            // Items stay visible after being read if they were visible when filter was applied.
            // Skip for Inbox - papers should stay visible after being read regardless.
            if filterMode == .unread && !library.isInbox {
                if let snapshot = unreadFilterSnapshot {
                    // Keep items in snapshot visible (Apple Mail behavior)
                    result = result.filter { !$0.isRead || snapshot.contains($0.id) }
                } else {
                    // No snapshot - strict filter (fresh application)
                    result = result.filter { !$0.isRead }
                }
            }

            publications = result.sorted { $0.dateAdded > $1.dateAdded }
            logger.info("Refreshed library: \(self.publications.count) items")

        case .smartSearch(let smartSearch):
            // Show result collection (organizational view within the library)
            guard let collection = smartSearch.resultCollection else {
                publications = []
                return
            }
            var result = (collection.publications ?? [])
                .filter { !$0.isDeleted }

            // Apply filter mode with Apple Mail behavior.
            // Skip for Inbox feeds - papers should stay visible after being read regardless.
            if filterMode == .unread && !smartSearch.feedsToInbox {
                if let snapshot = unreadFilterSnapshot {
                    // Keep items in snapshot visible (Apple Mail behavior)
                    result = result.filter { !$0.isRead || snapshot.contains($0.id) }
                } else {
                    // No snapshot - strict filter (fresh application)
                    result = result.filter { !$0.isRead }
                }
            }

            publications = result.sorted { $0.dateAdded > $1.dateAdded }
            logger.info("Refreshed smart search: \(self.publications.count) items")
        }
    }

    /// Fetch publications for a given scope and build library name mapping.
    ///
    /// Unified method replaces fetchAllLibrariesPublications, fetchInboxPublications, fetchEverythingPublications.
    /// - Parameter scope: Which libraries to include
    /// - Returns: Array of publications sorted by dateAdded (newest first)
    private func fetchPublications(for scope: FilterScope) -> [CDPublication] {
        // Determine which libraries to include based on scope
        let libraries: [CDLibrary] = switch scope {
        case .current:
            // For current scope, get from source (handled separately in refreshCurrentScopePublications)
            if case .library(let lib) = source { [lib] } else { [] }
        case .allLibraries:
            libraryManager.libraries.filter { !$0.isInbox }
        case .inbox:
            libraryManager.libraries.filter { $0.isInbox }
        case .everything:
            libraryManager.libraries
        }

        // Collect all publications from the selected libraries with library name tracking
        var allPublications = Set<CDPublication>()
        var newMapping: [UUID: String] = [:]

        for library in libraries {
            let pubs = (library.publications ?? [])
                .filter { !$0.isDeleted }
            allPublications.formUnion(pubs)

            // Track which library each publication came from (first library wins for duplicates)
            for pub in pubs {
                if newMapping[pub.id] == nil {
                    newMapping[pub.id] = library.displayName
                }
            }
        }

        // For "All Libraries" and "Everything", also include SciX library publications
        if scope == .allLibraries || scope == .everything {
            let (scixPublications, scixMapping) = fetchSciXLibraryPublicationsWithMapping()
            allPublications.formUnion(scixPublications)
            // Merge SciX mapping (don't overwrite existing entries)
            for (id, name) in scixMapping where newMapping[id] == nil {
                newMapping[id] = name
            }
        }

        // Update the library name mapping state
        libraryNameMapping = newMapping

        return Array(allPublications).sorted { $0.dateAdded > $1.dateAdded }
    }

    /// Fetch all publications from SciX (NASA ADS) online libraries with name mapping.
    private func fetchSciXLibraryPublicationsWithMapping() -> ([CDPublication], [UUID: String]) {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDSciXLibrary>(entityName: "SciXLibrary")

        do {
            let scixLibraries = try context.fetch(request)
            var publications = Set<CDPublication>()
            var mapping: [UUID: String] = [:]

            for library in scixLibraries {
                let pubs = (library.publications ?? [])
                    .filter { !$0.isDeleted }
                publications.formUnion(pubs)

                // Track which SciX library each publication came from
                let libraryName = "SciX: \(library.name)"
                for pub in pubs {
                    if mapping[pub.id] == nil {
                        mapping[pub.id] = libraryName
                    }
                }
            }

            return (Array(publications), mapping)
        } catch {
            logger.error("Failed to fetch SciX libraries: \(error.localizedDescription)")
            return ([], [:])
        }
    }

    /// Fetch all publications from SciX (NASA ADS) online libraries (legacy, without mapping).
    private func fetchSciXLibraryPublications() -> [CDPublication] {
        let (publications, _) = fetchSciXLibraryPublicationsWithMapping()
        return publications
    }

    /// Refresh from network (async operation with loading state)
    private func refreshFromNetwork() async {
        guard isSourceValid else {
            isLoading = false
            return
        }

        // Reset snapshot on explicit refresh (Apple Mail behavior)
        unreadFilterSnapshot = nil

        isLoading = true
        error = nil

        switch source {
        case .library(let library):
            // TODO: Future enrichment protocol
            // For now, just refresh the list
            logger.info("Library refresh requested for: \(library.displayName)")
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                refreshPublicationsList()
            }

        case .smartSearch(let smartSearch):
            logger.info("Smart search refresh requested for: \(smartSearch.name)")

            // Route group feeds to GroupFeedRefreshService for staggered per-author searches
            if smartSearch.isGroupFeed {
                logger.info("Routing group feed '\(smartSearch.name)' to GroupFeedRefreshService")
                do {
                    _ = try await GroupFeedRefreshService.shared.refreshGroupFeed(smartSearch)
                    await MainActor.run {
                        refreshPublicationsList()
                    }
                    logger.info("Group feed refresh completed for '\(smartSearch.name)'")
                } catch {
                    logger.error("Group feed refresh failed: \(error.localizedDescription)")
                    self.error = error
                }
            } else {
                // Regular smart search - use provider
                let cachedProvider = await SmartSearchProviderCache.shared.getOrCreate(
                    for: smartSearch,
                    sourceManager: searchViewModel.sourceManager,
                    repository: libraryViewModel.repository
                )
                provider = cachedProvider

                do {
                    try await cachedProvider.refresh()
                    await MainActor.run {
                        SmartSearchRepository.shared.markExecuted(smartSearch)
                        refreshPublicationsList()
                    }
                    logger.info("Smart search refresh completed")
                } catch {
                    logger.error("Smart search refresh failed: \(error.localizedDescription)")
                    self.error = error
                }
            }
        }

        isLoading = false
    }

    /// Queue a background refresh for the smart search if needed (stale or empty).
    ///
    /// This does NOT block the UI - cached results are shown immediately while
    /// the refresh happens in the background via SmartSearchRefreshService.
    private func queueBackgroundRefreshIfNeeded(_ smartSearch: CDSmartSearch) async {
        // Guard against deleted smart search
        guard smartSearch.managedObjectContext != nil, !smartSearch.isDeleted else { return }

        // Get provider to check staleness
        let cachedProvider = await SmartSearchProviderCache.shared.getOrCreate(
            for: smartSearch,
            sourceManager: searchViewModel.sourceManager,
            repository: libraryViewModel.repository
        )
        provider = cachedProvider

        // Check if refresh is needed (stale or empty)
        let isStale = await cachedProvider.isStale
        let isEmpty = publications.isEmpty

        if isStale || isEmpty {
            logger.info("Smart search '\(smartSearch.name)' needs refresh (stale: \(isStale), empty: \(isEmpty))")

            // Check if already being refreshed
            let alreadyRefreshing = await SmartSearchRefreshService.shared.isRefreshing(smartSearch.id)
            let alreadyQueued = await SmartSearchRefreshService.shared.isQueued(smartSearch.id)

            if alreadyRefreshing || alreadyQueued {
                logger.debug("Smart search '\(smartSearch.name)' already refreshing/queued")
                isBackgroundRefreshing = alreadyRefreshing
            } else {
                // Queue with high priority since it's the currently visible smart search
                isBackgroundRefreshing = true
                await SmartSearchRefreshService.shared.queueRefresh(smartSearch, priority: .high)
                logger.info("Queued high-priority background refresh for '\(smartSearch.name)'")
            }
        } else {
            logger.debug("Smart search '\(smartSearch.name)' is fresh, no refresh needed")
        }
    }

    // MARK: - Notification Handlers

    private func selectAllPublications() {
        selectedPublicationIDs = Set(publications.map { $0.id })
    }

    private func toggleReadStatusForSelected() {
        guard !selectedPublicationIDs.isEmpty else { return }

        Task {
            // Apple Mail behavior: if ANY are unread, mark ALL as read
            // If ALL are read, mark ALL as unread
            await libraryViewModel.smartToggleReadStatus(selectedPublicationIDs)
            refreshPublicationsList()
        }
    }

    private func copySelectedPublications() async {
        guard !selectedPublicationIDs.isEmpty else { return }
        await libraryViewModel.copyToClipboard(selectedPublicationIDs)
    }

    private func cutSelectedPublications() async {
        guard !selectedPublicationIDs.isEmpty else { return }
        await libraryViewModel.cutToClipboard(selectedPublicationIDs)
        refreshPublicationsList()
    }

    // MARK: - Text Field Focus Detection

    /// Check if a text field is currently focused (to avoid intercepting text input)
    private func isTextFieldFocused() -> Bool {
        #if os(macOS)
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else {
            return false
        }
        // NSTextView is used by TextEditor, TextField, and other text controls
        return firstResponder is NSTextView
        #else
        return false  // iOS uses different focus management
        #endif
    }

    // MARK: - Inbox Triage Handlers

    /// Handle 'S' key - save selected to default library
    private func handleSaveKey() -> KeyPress.Result {
        guard !isTextFieldFocused(), isInboxView, !selectedPublicationIDs.isEmpty else { return .ignored }
        saveSelectedToDefaultLibrary()
        return .handled
    }

    /// Handle 'D' key - dismiss selected publications (works in all libraries)
    private func handleDismissKey() -> KeyPress.Result {
        guard !isTextFieldFocused(), !selectedPublicationIDs.isEmpty else { return .ignored }
        dismissSelectedFromInbox()
        return .handled
    }

    /// Handle vim-style navigation keys (h/j/k/l) and inbox triage keys (s/S/t)
    private func handleVimNavigation(_ press: KeyPress) -> KeyPress.Result {
        guard !isTextFieldFocused() else { return .ignored }

        let store = KeyboardShortcutsStore.shared

        // Check for vim navigation shortcuts
        if store.matches(press, action: "navigateDown") {
            NotificationCenter.default.post(name: .navigateNextPaper, object: nil)
            return .handled
        }

        if store.matches(press, action: "navigateUp") {
            // K key: now ONLY does vim navigation up (no longer dual-purpose)
            NotificationCenter.default.post(name: .navigatePreviousPaper, object: nil)
            return .handled
        }

        if store.matches(press, action: "navigateBack") {
            NotificationCenter.default.post(name: .navigateBack, object: nil)
            return .handled
        }

        if store.matches(press, action: "navigateForward") {
            NotificationCenter.default.post(name: .openSelectedPaper, object: nil)
            return .handled
        }

        // S key: Save to Save library (inbox only)
        if store.matches(press, action: "inboxSave") {
            if isInboxView && !selectedPublicationIDs.isEmpty {
                saveSelectedToDefaultLibrary()
                return .handled
            }
        }

        // Shift+S: Save and Star (inbox only)
        if store.matches(press, action: "inboxSaveAndStar") {
            if isInboxView && !selectedPublicationIDs.isEmpty {
                saveAndStarSelected()
                return .handled
            }
        }

        // T key: Toggle star (works anywhere)
        if store.matches(press, action: "inboxToggleStar") {
            if !selectedPublicationIDs.isEmpty {
                toggleStarForSelected()
                return .handled
            }
        }

        return .ignored
    }

    /// Save selected publications to the Save library (created on first use if needed)
    private func saveSelectedToDefaultLibrary() {
        // Use the Save library (created automatically on first use)
        let saveLibrary = libraryManager.getOrCreateSaveLibrary()

        let ids = selectedPublicationIDs
        guard let firstID = ids.first else { return }

        // Show green flash for save action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .green)
        }

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }
            }
            await saveToLibrary(ids: ids, targetLibrary: saveLibrary)
        }
    }

    /// Save and star selected publications to the Save library
    private func saveAndStarSelected() {
        // Use the Save library (created automatically on first use)
        let saveLibrary = libraryManager.getOrCreateSaveLibrary()

        let ids = selectedPublicationIDs
        guard let firstID = ids.first else { return }

        // Show gold flash for save+star action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .yellow)
        }

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }

                // Star the selected publications
                for id in ids {
                    if let pub = publications.first(where: { $0.id == id }) {
                        pub.isStarred = true
                    }
                }
                PersistenceController.shared.save()
            }
            await saveToLibrary(ids: ids, targetLibrary: saveLibrary)
        }
    }

    /// Toggle star for selected publications
    private func toggleStarForSelected() {
        let ids = selectedPublicationIDs
        guard !ids.isEmpty else { return }

        // Determine the action: if ANY are unstarred, star ALL; otherwise unstar ALL
        let anyUnstarred = publications.filter { ids.contains($0.id) }.contains { !$0.isStarred }
        let newStarred = anyUnstarred

        for id in ids {
            if let pub = publications.first(where: { $0.id == id }) {
                pub.isStarred = newStarred
            }
        }
        PersistenceController.shared.save()
        refreshPublicationsList()
    }

    /// Toggle star for a single publication
    private func toggleStar(for publication: CDPublication) async {
        publication.isStarred = !publication.isStarred
        PersistenceController.shared.save()
        refreshPublicationsList()
    }

    /// Toggle star for publications by IDs (used by PublicationListView callback)
    private func toggleStarForIDs(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }

        // Determine the action: if ANY are unstarred, star ALL; otherwise unstar ALL
        let anyUnstarred = publications.filter { ids.contains($0.id) }.contains { !$0.isStarred }
        let newStarred = anyUnstarred

        for id in ids {
            if let pub = publications.first(where: { $0.id == id }) {
                pub.isStarred = newStarred
            }
        }
        PersistenceController.shared.save()
        refreshPublicationsList()
    }

    /// Compute the visual order of publications synchronously.
    ///
    /// This is the single source of truth for list order during triage operations.
    /// Called synchronously before triage to ensure selection advancement uses the correct order.
    ///
    /// - Returns: Publications sorted according to current sort order and filters
    private func computeVisualOrder() -> [CDPublication] {
        // Filter valid publications
        var result = publications.filter { pub in
            !pub.isDeleted
        }

        // Apply current sort order with stable tie-breaker (dateAdded then id)
        let sorted = result.sorted { lhs, rhs in
            // For recommendation sort, handle tie-breaking specially
            if currentSortOrder == .recommended {
                let lhsScore = recommendationScores[lhs.id] ?? 0
                let rhsScore = recommendationScores[rhs.id] ?? 0
                if lhsScore != rhsScore {
                    let result = lhsScore > rhsScore
                    return currentSortAscending == currentSortOrder.defaultAscending ? result : !result
                }
                // Tie-breaker: dateAdded descending (newest first)
                if lhs.dateAdded != rhs.dateAdded {
                    let result = lhs.dateAdded > rhs.dateAdded
                    return currentSortAscending == currentSortOrder.defaultAscending ? result : !result
                }
                // Final tie-breaker: id for absolute stability
                return lhs.id.uuidString < rhs.id.uuidString
            }

            let defaultComparison: Bool = switch currentSortOrder {
            case .dateAdded:
                lhs.dateAdded > rhs.dateAdded  // Default descending (newest first)
            case .dateModified:
                lhs.dateModified > rhs.dateModified  // Default descending (newest first)
            case .title:
                (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending  // Default ascending (A-Z)
            case .year:
                (lhs.year ?? 0) > (rhs.year ?? 0)  // Default descending (newest first)
            case .citeKey:
                lhs.citeKey.localizedCaseInsensitiveCompare(rhs.citeKey) == .orderedAscending  // Default ascending (A-Z)
            case .citationCount:
                (lhs.citationCount ?? 0) > (rhs.citationCount ?? 0)  // Default descending (highest first)
            case .starred:
                // Starred first, then by dateAdded as tie-breaker
                if lhs.isStarred != rhs.isStarred {
                    lhs.isStarred  // Starred papers first (true > false)
                } else {
                    lhs.dateAdded > rhs.dateAdded  // Tie-breaker: newest first
                }
            case .recommended:
                true  // Handled above, this won't be reached
            }
            // Flip result if sortAscending differs from the field's default direction
            return currentSortAscending == currentSortOrder.defaultAscending ? defaultComparison : !defaultComparison
        }

        return sorted
    }

    /// Dismiss selected publications from inbox (moves to Dismissed library, not delete)
    /// Advances selection to next paper for rapid triage.
    private func dismissSelectedFromInbox() {
        let dismissedLibrary = libraryManager.getOrCreateDismissedLibrary()
        guard let firstID = selectedPublicationIDs.first else { return }

        // Show orange flash for dismiss action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .orange)
        }

        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()
        let currentIDs = selectedPublicationIDs
        let currentSelection = selectedPublication

        Task {
            // Brief delay to show flash
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }

                // Use computed visual order for proper selection advancement
                let result = InboxTriageService.shared.dismissFromInbox(
                    ids: currentIDs,
                    from: visualOrder,
                    currentSelection: currentSelection,
                    dismissedLibrary: dismissedLibrary,
                    source: triageSource
                )

                // Advance to next selection for rapid triage
                if let nextID = result.nextSelectionID {
                    selectedPublicationIDs = [nextID]
                    selectedPublication = result.nextPublication
                } else {
                    // No more papers - clear selection
                    selectedPublicationIDs.removeAll()
                    selectedPublication = nil
                }

                refreshPublicationsList()
            }
        }
    }

    // MARK: - Save Implementation

    /// Save publications to a target library (adds to target AND removes from current).
    /// Advances selection to next paper for rapid triage.
    private func saveToLibrary(ids: Set<UUID>, targetLibrary: CDLibrary) async {
        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        // Use computed visual order for proper selection advancement
        let result = InboxTriageService.shared.saveToLibrary(
            ids: ids,
            from: visualOrder,
            currentSelection: selectedPublication,
            targetLibrary: targetLibrary,
            source: triageSource
        )

        // Advance to next selection for rapid triage
        if let nextID = result.nextSelectionID {
            selectedPublicationIDs = [nextID]
            selectedPublication = result.nextPublication
        } else {
            // No more papers - clear selection
            selectedPublicationIDs.removeAll()
            selectedPublication = nil
        }

        refreshPublicationsList()
    }

    /// Convert current source to TriageSource for InboxTriageService.
    private var triageSource: TriageSource {
        switch source {
        case .library(let lib):
            return lib.isInbox ? .inboxLibrary : .regularLibrary(lib)
        case .smartSearch(let ss) where ss.feedsToInbox:
            return .inboxFeed(ss)
        case .smartSearch(let ss):
            if let lib = ss.library {
                return .regularLibrary(lib)
            }
            return .inboxLibrary
        }
    }

    // MARK: - Inbox Triage Callback Implementations

    /// Dismiss publications from inbox (for context menu) - moves to Dismissed library, not delete
    private func dismissFromInbox(ids: Set<UUID>) async {
        let dismissedLibrary = libraryManager.getOrCreateDismissedLibrary()

        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        let result = InboxTriageService.shared.dismissFromInbox(
            ids: ids,
            from: visualOrder,
            currentSelection: selectedPublication,
            dismissedLibrary: dismissedLibrary,
            source: triageSource
        )

        // Advance to next selection for rapid triage
        if let nextID = result.nextSelectionID {
            selectedPublicationIDs = [nextID]
            selectedPublication = result.nextPublication
        } else {
            selectedPublicationIDs.removeAll()
            selectedPublication = nil
        }

        refreshPublicationsList()
    }

    /// Mute an author
    private func muteAuthor(_ authorName: String) {
        let inboxManager = InboxManager.shared
        inboxManager.mute(type: .author, value: authorName)
        logger.info("Muted author: \(authorName)")
    }

    /// Mute a paper (by DOI or bibcode)
    private func mutePaper(_ publication: CDPublication) {
        let inboxManager = InboxManager.shared

        // Prefer DOI, then bibcode (from original source ID for ADS papers)
        if let doi = publication.doi, !doi.isEmpty {
            inboxManager.mute(type: .doi, value: doi)
            logger.info("Muted paper by DOI: \(doi)")
        } else if let bibcode = publication.originalSourceID {
            // For ADS papers, originalSourceID contains the bibcode
            inboxManager.mute(type: .bibcode, value: bibcode)
            logger.info("Muted paper by bibcode: \(bibcode)")
        } else {
            logger.warning("Cannot mute paper - no DOI or bibcode available")
        }
    }

    // MARK: - Helpers

    private func openPDF(for publication: CDPublication) {
        // Check user preference for opening PDFs
        let openExternally = UserDefaults.standard.bool(forKey: "openPDFInExternalViewer")

        if openExternally {
            // Open in external viewer (Preview, Adobe, etc.)
            if let linkedFiles = publication.linkedFiles,
               let pdfFile = linkedFiles.first(where: { $0.isPDF }),
               let libraryURL = currentLibrary?.folderURL {
                let pdfURL = libraryURL.appendingPathComponent(pdfFile.relativePath)
                #if os(macOS)
                NSWorkspace.shared.open(pdfURL)
                #endif
            }
        } else {
            // Show in built-in PDF tab
            // First ensure the publication is selected, then switch to PDF tab
            libraryViewModel.selectedPublications = [publication.id]
            NotificationCenter.default.post(name: .showPDFTab, object: nil)
        }
    }

    /// Capture current unread publication IDs for Apple Mail-style snapshot.
    /// Items in the snapshot stay visible even after being marked as read.
    private func captureUnreadSnapshot() -> Set<UUID> {
        guard isSourceValid else { return [] }
        switch source {
        case .library(let library):
            let unread = (library.publications ?? [])
                .filter { !$0.isDeleted && !$0.isRead }
            return Set(unread.map { $0.id })
        case .smartSearch(let smartSearch):
            guard let collection = smartSearch.resultCollection else { return [] }
            let unread = (collection.publications ?? [])
                .filter { !$0.isDeleted && !$0.isRead }
            return Set(unread.map { $0.id })
        }
    }
}

// MARK: - View Modifiers (extracted to help compiler type-checking)

/// Handles notification subscriptions for clipboard and selection operations
private struct NotificationModifiers: ViewModifier {
    let onToggleReadStatus: () -> Void
    let onCopyPublications: () -> Void
    let onCutPublications: () -> Void
    let onPastePublications: () -> Void
    let onSelectAll: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadStatus)) { _ in
                onToggleReadStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyPublications)) { _ in
                onCopyPublications()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cutPublications)) { _ in
                onCutPublications()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pastePublications)) { _ in
                onPastePublications()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAllPublications)) { _ in
                onSelectAll()
            }
    }
}

/// Handles smart search refresh completion notifications
private struct SmartSearchRefreshModifier: ViewModifier {
    let source: PublicationSource
    let onRefreshComplete: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .smartSearchRefreshCompleted)) { notification in
                if case .smartSearch(let smartSearch) = source,
                   let completedID = notification.object as? UUID,
                   completedID == smartSearch.id {
                    onRefreshComplete(smartSearch.name)
                }
            }
    }
}

/// Handles inbox triage notification subscriptions
private struct InboxTriageModifier: ViewModifier {
    let isInboxView: Bool
    let hasSelection: Bool
    let onSave: () -> Void
    let onSaveAndStar: () -> Void
    let onToggleStar: () -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .inboxSave)) { _ in
                if isInboxView && hasSelection {
                    onSave()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inboxSaveAndStar)) { _ in
                if isInboxView && hasSelection {
                    onSaveAndStar()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inboxToggleStar)) { _ in
                if hasSelection {
                    onToggleStar()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inboxDismiss)) { _ in
                if isInboxView && hasSelection {
                    onDismiss()
                }
            }
    }
}

// MARK: - Preview

#Preview {
    let libraryManager = LibraryManager(persistenceController: .preview)
    if let library = libraryManager.libraries.first {
        NavigationStack {
            UnifiedPublicationListWrapper(
                source: .library(library),
                selectedPublication: .constant(nil),
                selectedPublicationIDs: .constant([])
            )
        }
        .environment(LibraryViewModel())
        .environment(SearchViewModel(
            sourceManager: SourceManager(),
            deduplicationService: DeduplicationService(),
            repository: PublicationRepository()
        ))
        .environment(libraryManager)
    } else {
        Text("No library available in preview")
    }
}
