//
//  PublicationListView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import SwiftUI
import OSLog

// MARK: - Filter Scope

/// Scope for filtering publications in the search field
public enum FilterScope: String, CaseIterable, Identifiable {
    case current = "Current"
    case allLibraries = "All Libraries"
    case inbox = "Inbox"
    case everything = "Everything"

    public var id: String { rawValue }
}

// MARK: - Filter Cache

/// Cache key for memoizing filtered row data
private struct FilterCacheKey: Equatable {
    let rowDataVersion: Int
    let showUnreadOnly: Bool
    let disableUnreadFilter: Bool
    let searchQuery: String
    let sortOrder: LibrarySortOrder
    let sortAscending: Bool  // Direction toggle
    let searchInPDFs: Bool
    let pdfMatchCount: Int  // Track PDF matches by count (Set isn't Equatable for hash)
    let recommendationScoreVersion: Int  // ADR-020: Track recommendation score updates
}

/// Memoization cache for filtered row data.
/// Uses a class to avoid @State changes that would trigger re-renders.
private final class FilteredRowDataCache {
    private var cachedKey: FilterCacheKey?
    private var cachedResult: [PublicationRowData]?

    func getCached(for key: FilterCacheKey) -> [PublicationRowData]? {
        guard cachedKey == key else { return nil }
        return cachedResult
    }

    func cache(_ result: [PublicationRowData], for key: FilterCacheKey) {
        cachedKey = key
        cachedResult = result
    }

    func invalidate() {
        cachedKey = nil
        cachedResult = nil
    }
}

/// Unified publication list view used by Library, Smart Search, and Ad-hoc Search.
///
/// Per ADR-016, all papers are CDPublication entities and should have identical
/// capabilities regardless of where they're viewed. This component provides:
/// - Mail-style publication rows
/// - Inline toolbar (search, filter, import, sort)
/// - Full context menu
/// - Keyboard delete support
/// - Multi-selection
/// - State persistence (selection, sort order, filters) via ListViewStateStore
///
/// ## Thread Safety
///
/// This view converts `[CDPublication]` to `[PublicationRowData]` (value types)
/// before rendering. This eliminates crashes during bulk deletion where Core Data
/// objects become invalid while SwiftUI is still rendering.
public struct PublicationListView: View {

    // MARK: - Properties

    /// All publications to display (before filtering/sorting)
    public let publications: [CDPublication]

    /// Multi-selection binding
    @Binding public var selection: Set<UUID>

    /// Single-selection binding (updated when selection changes)
    @Binding public var selectedPublication: CDPublication?

    /// Library for context menu operations (Add to Library, Add to Collection)
    public var library: CDLibrary?

    /// All available libraries for "Add to Library" menu
    public var allLibraries: [CDLibrary] = []

    /// Whether to show the import button
    public var showImportButton: Bool = true

    /// Whether to show the sort menu
    public var showSortMenu: Bool = true

    /// Custom empty state message
    public var emptyStateMessage: String = "No publications found."

    /// Custom empty state description
    public var emptyStateDescription: String = "Import a BibTeX file or search online sources to add publications."

    /// Identifier for state persistence (nil = no persistence)
    public var listID: ListViewID?

    /// When true, the unread filter is disabled and all papers are shown.
    /// Used for Inbox view where papers should remain visible after being marked as read.
    public var disableUnreadFilter: Bool = false

    /// Whether this list is showing Inbox items (enables Inbox-specific swipe actions)
    public var isInInbox: Bool = false

    /// The target library for "keep" swipe action (configured via Settings > Inbox).
    /// When nil, the first non-inbox library is used as fallback.
    public var saveLibrary: CDLibrary?

    /// Binding to the filter scope (controls which publications are searched)
    @Binding public var filterScope: FilterScope

    /// Mapping of publication ID to library name for grouped search display
    /// When non-empty, enables grouped display of search results by library
    public var libraryNameMapping: [UUID: String] = [:]

    /// Binding to sort order - owned by parent view for synchronous triage calculations
    @Binding public var sortOrder: LibrarySortOrder

    /// Binding to sort direction - owned by parent view for synchronous triage calculations
    @Binding public var sortAscending: Bool

    /// Binding to recommendation scores - owned by parent view for synchronous triage calculations
    @Binding public var recommendationScores: [UUID: Double]

    // MARK: - Callbacks

    /// Called when delete is requested (via context menu or keyboard)
    public var onDelete: ((Set<UUID>) async -> Void)?

    /// Called when toggle read is requested
    public var onToggleRead: ((CDPublication) async -> Void)?

    /// Called when copy is requested
    public var onCopy: ((Set<UUID>) async -> Void)?

    /// Called when cut is requested
    public var onCut: ((Set<UUID>) async -> Void)?

    /// Called when paste is requested
    public var onPaste: (() async -> Void)?

    /// Called when add to library is requested (publications can belong to multiple libraries)
    public var onAddToLibrary: ((Set<UUID>, CDLibrary) async -> Void)?

    /// Called when add to collection is requested
    public var onAddToCollection: ((Set<UUID>, CDCollection) async -> Void)?

    /// Called when remove from all collections is requested ("All Publications")
    public var onRemoveFromAllCollections: ((Set<UUID>) async -> Void)?

    /// Called when import is requested (import button clicked)
    public var onImport: (() -> Void)?

    /// Called when open PDF is requested
    public var onOpenPDF: ((CDPublication) -> Void)?

    /// Called when files are dropped onto a publication row
    public var onFileDrop: ((CDPublication, [NSItemProvider]) -> Void)?

    /// Called when PDFs are dropped onto the list background (for import)
    public var onListDrop: (([NSItemProvider], DropTarget) -> Void)?

    /// Called when "Download PDFs" is requested for selected publications
    public var onDownloadPDFs: ((Set<UUID>) -> Void)?

    // MARK: - Inbox Triage Callbacks

    /// Called when keep to library is requested (Inbox: adds to library AND removes from Inbox)
    public var onSaveToLibrary: ((Set<UUID>, CDLibrary) async -> Void)?

    /// Called when dismiss is requested (Inbox: remove from Inbox)
    public var onDismiss: ((Set<UUID>) async -> Void)?

    /// Called when toggle star is requested
    public var onToggleStar: ((Set<UUID>) async -> Void)?

    /// Called when mute author is requested
    public var onMuteAuthor: ((String) -> Void)?

    /// Called when mute paper is requested (by DOI or bibcode)
    public var onMutePaper: ((CDPublication) -> Void)?

    /// Called when a category chip is tapped (e.g., to search for that category)
    public var onCategoryTap: ((String) -> Void)?

    /// Called when refresh is requested (for smart searches and feeds)
    public var onRefresh: (() async -> Void)?

    // MARK: - Enhanced Context Menu Callbacks

    /// Called when Open in Browser is requested (arXiv, ADS, DOI)
    public var onOpenInBrowser: ((CDPublication, BrowserDestination) -> Void)?

    /// Called when Download PDF is requested (for papers without PDF)
    public var onDownloadPDF: ((CDPublication) -> Void)?

    /// Called when View/Edit BibTeX is requested
    public var onViewEditBibTeX: ((CDPublication) -> Void)?

    /// Called when Share (system share sheet) is requested
    public var onShare: ((CDPublication) -> Void)?

    /// Called when Share by Email is requested (with PDF + BibTeX attachments)
    public var onShareByEmail: ((CDPublication) -> Void)?

    /// Called when Explore References is requested
    public var onExploreReferences: ((CDPublication) -> Void)?

    /// Called when Explore Citations is requested
    public var onExploreCitations: ((CDPublication) -> Void)?

    /// Called when Explore Similar Papers is requested
    public var onExploreSimilar: ((CDPublication) -> Void)?

    /// Whether a refresh is in progress (shows loading indicator)
    public var isRefreshing: Bool = false

    /// External triage flash trigger (for keyboard shortcuts from parent view)
    /// When set by parent, triggers flash animation on the specified row
    @Binding public var externalTriageFlash: (id: UUID, color: Color)?

    // MARK: - Internal State

    @State private var searchQuery: String = ""
    @State private var showUnreadOnly: Bool = false
    @State private var hasLoadedState: Bool = false

    /// ADR-020: Serendipity slot tracking
    @State private var serendipitySlotIDs: Set<UUID> = []
    @State private var isComputingRecommendations: Bool = false
    @State private var lastRecommendationUpdate: Date?

    /// Minimum interval between recommendation score updates (30 minutes)
    /// Prevents list order from changing while user is browsing
    private static let recommendationUpdateInterval: TimeInterval = 30 * 60

    /// Whether to include PDF content in search (uses Spotlight on macOS, PDFKit on iOS)
    @State private var searchInPDFs: Bool = false

    /// Publication IDs that match the PDF content search (async populated)
    @State private var pdfSearchMatches: Set<UUID> = []

    /// Task for ongoing PDF search (cancelled when query changes)
    @State private var pdfSearchTask: Task<Void, Never>?

    /// Whether PDF search is in progress
    @State private var isPDFSearching: Bool = false

    /// Whether the search field is expanded (collapsed shows only magnifying glass icon)
    @State private var isSearchExpanded: Bool = false

    /// Cached row data - rebuilt when publications change
    @State private var rowDataCache: [UUID: PublicationRowData] = [:]

    /// Cached publication lookup - O(1) instead of O(n) linear scans
    @State private var publicationsByID: [UUID: CDPublication] = [:]

    /// ID of row currently targeted by file drop
    @State private var dropTargetedRowID: UUID?

    /// Whether the list background is currently targeted for PDF drop
    @State private var isListDropTargeted: Bool = false

    /// List view settings for row customization
    /// Uses synchronous load to avoid first-render with defaults
    @State private var listViewSettings: ListViewSettings = ListViewSettingsStore.loadSettingsSync()

    /// Debounce task for saving state (prevents rapid saves on fast selection changes)
    @State private var saveStateTask: Task<Void, Never>?

    /// Memoization cache for filtered row data (class reference to avoid state changes)
    @State private var filterCache = FilteredRowDataCache()

    /// Scroll proxy for programmatic scrolling to selection (set by ScrollViewReader)
    @State private var scrollProxy: ScrollViewProxy?

    /// Pending scroll target - set when selection changes, cleared after successful scroll
    /// This enables retry-based scrolling to handle timing issues with view updates
    @State private var pendingScrollTarget: UUID?

    /// Track which library sections are expanded (all expanded by default)
    @State private var expandedSections: Set<String> = []
    @State private var expandedSectionsInitialized: Bool = false

    /// Triage flash feedback state: (publicationID, flashColor)
    /// When set, the row briefly shows a colored background to confirm the action
    @State private var triageFlashState: (id: UUID, color: Color)?

    /// Theme colors for list background tint
    @Environment(\.themeColors) private var theme

    // MARK: - Computed Properties

    /// Static collections (non-smart) from the current library, for "Add to Collection" menus
    private var staticCollections: [CDCollection] {
        guard let collections = library?.collections as? Set<CDCollection> else { return [] }
        return collections.filter { !$0.isSmartCollection && !$0.isSmartSearchResults }
            .sorted { $0.name < $1.name }
    }

    /// Filtered and sorted row data - memoized to avoid repeated computation
    private var filteredRowData: [PublicationRowData] {
        // Create cache key from all inputs
        let cacheKey = FilterCacheKey(
            rowDataVersion: rowDataCache.count,
            showUnreadOnly: showUnreadOnly,
            disableUnreadFilter: disableUnreadFilter,
            searchQuery: searchQuery,
            sortOrder: sortOrder,
            sortAscending: sortAscending,
            searchInPDFs: searchInPDFs,
            pdfMatchCount: pdfSearchMatches.count,
            recommendationScoreVersion: recommendationScores.count  // ADR-020
        )

        // Return cached result if inputs haven't changed
        if let cached = filterCache.getCached(for: cacheKey) {
            return cached
        }

        // Compute and cache
        let start = CFAbsoluteTimeGetCurrent()
        var result = Array(rowDataCache.values)

        // Filter by unread (skip for Inbox where disableUnreadFilter is true)
        if showUnreadOnly && !disableUnreadFilter {
            result = result.filter { !$0.isRead }
        }

        // Filter by search query (metadata + notes + optionally PDF content)
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            result = result.filter { rowData in
                // Always check metadata fields including notes
                let matchesMetadata = rowData.title.lowercased().contains(query) ||
                    rowData.authorString.lowercased().contains(query) ||
                    rowData.citeKey.lowercased().contains(query) ||
                    (rowData.note?.lowercased().contains(query) ?? false)

                // If PDF search is enabled, also include PDF content matches
                if searchInPDFs && pdfSearchMatches.contains(rowData.id) {
                    return true
                }

                return matchesMetadata
            }
        }

        // Sort using data already in PublicationRowData - no CDPublication lookups needed
        // Each case returns the "default direction" comparison, then we flip if sortAscending differs
        // IMPORTANT: Use stable tie-breaker for recommendation sort to match wrapper's computeVisualOrder()
        let sorted = result.sorted { lhs, rhs in
            // For recommendation sort, handle tie-breaking specially
            if sortOrder == .recommended {
                let lhsScore = recommendationScores[lhs.id] ?? 0
                let rhsScore = recommendationScores[rhs.id] ?? 0
                if lhsScore != rhsScore {
                    let result = lhsScore > rhsScore
                    return sortAscending == sortOrder.defaultAscending ? result : !result
                }
                // Tie-breaker: dateAdded descending (newest first)
                if lhs.dateAdded != rhs.dateAdded {
                    let result = lhs.dateAdded > rhs.dateAdded
                    return sortAscending == sortOrder.defaultAscending ? result : !result
                }
                // Final tie-breaker: id for absolute stability
                return lhs.id.uuidString < rhs.id.uuidString
            }

            let defaultComparison: Bool = switch sortOrder {
            case .dateAdded:
                lhs.dateAdded > rhs.dateAdded  // Default descending (newest first)
            case .dateModified:
                lhs.dateModified > rhs.dateModified  // Default descending (newest first)
            case .title:
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending  // Default ascending (A-Z)
            case .year:
                (lhs.year ?? 0) > (rhs.year ?? 0)  // Default descending (newest first)
            case .citeKey:
                lhs.citeKey.localizedCaseInsensitiveCompare(rhs.citeKey) == .orderedAscending  // Default ascending (A-Z)
            case .citationCount:
                lhs.citationCount > rhs.citationCount  // Default descending (highest first)
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
            return sortAscending == sortOrder.defaultAscending ? defaultComparison : !defaultComparison
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Logger.performance.infoCapture("⏱ filteredRowData: \(String(format: "%.1f", elapsed))ms (\(sorted.count) items)", category: "performance")

        filterCache.cache(sorted, for: cacheKey)
        return sorted
    }

    /// Group for displaying search results organized by library
    private struct LibraryGroup: Identifiable {
        let name: String
        let rows: [PublicationRowData]
        var id: String { name }
    }

    /// Group filtered results by library name for sectioned display
    private var groupedFilteredRowData: [LibraryGroup] {
        // Only group when searching (filter scope is everything and has query)
        guard !searchQuery.isEmpty else { return [] }

        // Group by library name
        var groups: [String: [PublicationRowData]] = [:]
        for row in filteredRowData {
            let libraryName = row.libraryName ?? "Current"
            groups[libraryName, default: []].append(row)
        }

        // Sort groups: "Current" first, then alphabetically
        return groups.keys.sorted { lhs, rhs in
            if lhs == "Current" { return true }
            if rhs == "Current" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }.map { name in
            LibraryGroup(name: name, rows: groups[name] ?? [])
        }
    }

    /// Whether to show grouped display (when searching across all libraries)
    private var shouldShowGroupedDisplay: Bool {
        !searchQuery.isEmpty && groupedFilteredRowData.count > 1
    }

    /// Create a binding for section expansion state
    private func expandedSectionBinding(for sectionName: String) -> Binding<Bool> {
        Binding(
            get: {
                // If not initialized, all sections are expanded by default
                if !expandedSectionsInitialized {
                    return true
                }
                return expandedSections.contains(sectionName)
            },
            set: { isExpanded in
                // Initialize all sections as expanded on first interaction
                if !expandedSectionsInitialized {
                    expandedSections = Set(groupedFilteredRowData.map { $0.name })
                    expandedSectionsInitialized = true
                }
                if isExpanded {
                    expandedSections.insert(sectionName)
                } else {
                    expandedSections.remove(sectionName)
                }
            }
        )
    }

    // MARK: - Initialization

    public init(
        publications: [CDPublication],
        selection: Binding<Set<UUID>>,
        selectedPublication: Binding<CDPublication?>,
        library: CDLibrary? = nil,
        allLibraries: [CDLibrary] = [],
        showImportButton: Bool = true,
        showSortMenu: Bool = true,
        emptyStateMessage: String = "No publications found.",
        emptyStateDescription: String = "Import a BibTeX file or search online sources to add publications.",
        listID: ListViewID? = nil,
        disableUnreadFilter: Bool = false,
        isInInbox: Bool = false,
        saveLibrary: CDLibrary? = nil,
        filterScope: Binding<FilterScope>,
        libraryNameMapping: [UUID: String] = [:],
        sortOrder: Binding<LibrarySortOrder> = .constant(.dateAdded),
        sortAscending: Binding<Bool> = .constant(false),
        recommendationScores: Binding<[UUID: Double]> = .constant([:]),
        onDelete: ((Set<UUID>) async -> Void)? = nil,
        onToggleRead: ((CDPublication) async -> Void)? = nil,
        onCopy: ((Set<UUID>) async -> Void)? = nil,
        onCut: ((Set<UUID>) async -> Void)? = nil,
        onPaste: (() async -> Void)? = nil,
        onAddToLibrary: ((Set<UUID>, CDLibrary) async -> Void)? = nil,
        onAddToCollection: ((Set<UUID>, CDCollection) async -> Void)? = nil,
        onRemoveFromAllCollections: ((Set<UUID>) async -> Void)? = nil,
        onImport: (() -> Void)? = nil,
        onOpenPDF: ((CDPublication) -> Void)? = nil,
        onFileDrop: ((CDPublication, [NSItemProvider]) -> Void)? = nil,
        onListDrop: (([NSItemProvider], DropTarget) -> Void)? = nil,
        onDownloadPDFs: ((Set<UUID>) -> Void)? = nil,
        // Inbox triage callbacks
        onSaveToLibrary: ((Set<UUID>, CDLibrary) async -> Void)? = nil,
        onDismiss: ((Set<UUID>) async -> Void)? = nil,
        onToggleStar: ((Set<UUID>) async -> Void)? = nil,
        onMuteAuthor: ((String) -> Void)? = nil,
        onMutePaper: ((CDPublication) -> Void)? = nil,
        // Category tap callback
        onCategoryTap: ((String) -> Void)? = nil,
        // Refresh callback and state
        onRefresh: (() async -> Void)? = nil,
        isRefreshing: Bool = false,
        // External flash trigger
        externalTriageFlash: Binding<(id: UUID, color: Color)?> = .constant(nil),
        // Enhanced context menu callbacks
        onOpenInBrowser: ((CDPublication, BrowserDestination) -> Void)? = nil,
        onDownloadPDF: ((CDPublication) -> Void)? = nil,
        onViewEditBibTeX: ((CDPublication) -> Void)? = nil,
        onShare: ((CDPublication) -> Void)? = nil,
        onShareByEmail: ((CDPublication) -> Void)? = nil,
        onExploreReferences: ((CDPublication) -> Void)? = nil,
        onExploreCitations: ((CDPublication) -> Void)? = nil,
        onExploreSimilar: ((CDPublication) -> Void)? = nil
    ) {
        self.publications = publications
        self._selection = selection
        self._selectedPublication = selectedPublication
        self.library = library
        self.allLibraries = allLibraries
        self.showImportButton = showImportButton
        self.showSortMenu = showSortMenu
        self.emptyStateMessage = emptyStateMessage
        self.emptyStateDescription = emptyStateDescription
        self.listID = listID
        self.disableUnreadFilter = disableUnreadFilter
        self.isInInbox = isInInbox
        self.saveLibrary = saveLibrary
        self._filterScope = filterScope
        self.libraryNameMapping = libraryNameMapping
        self._sortOrder = sortOrder
        self._sortAscending = sortAscending
        self._recommendationScores = recommendationScores
        self.onDelete = onDelete
        self.onToggleRead = onToggleRead
        self.onCopy = onCopy
        self.onCut = onCut
        self.onPaste = onPaste
        self.onAddToLibrary = onAddToLibrary
        self.onAddToCollection = onAddToCollection
        self.onRemoveFromAllCollections = onRemoveFromAllCollections
        self.onImport = onImport
        self.onOpenPDF = onOpenPDF
        self.onFileDrop = onFileDrop
        self.onListDrop = onListDrop
        self.onDownloadPDFs = onDownloadPDFs
        // Inbox triage
        self.onSaveToLibrary = onSaveToLibrary
        self.onDismiss = onDismiss
        self.onToggleStar = onToggleStar
        self.onMuteAuthor = onMuteAuthor
        self.onMutePaper = onMutePaper
        // Category tap
        self.onCategoryTap = onCategoryTap
        // Refresh
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        // External flash
        self._externalTriageFlash = externalTriageFlash
        // Enhanced context menu
        self.onOpenInBrowser = onOpenInBrowser
        self.onDownloadPDF = onDownloadPDF
        self.onViewEditBibTeX = onViewEditBibTeX
        self.onShare = onShare
        self.onShareByEmail = onShareByEmail
        self.onExploreReferences = onExploreReferences
        self.onExploreCitations = onExploreCitations
        self.onExploreSimilar = onExploreSimilar
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Inline toolbar (stays at top)
            inlineToolbar

            Divider()

            // Content area - fills remaining space
            // Using ZStack ensures toolbar stays at top when empty state is shown
            ZStack {
                if filteredRowData.isEmpty {
                    emptyState
                } else {
                    publicationList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: listID) {
            await loadState()
            listViewSettings = await ListViewSettingsStore.shared.settings
        }
        .onAppear {
            rebuildRowData()
        }
        .onChange(of: publications.count) { _, _ in
            // Rebuild row data when publications change (add/delete)
            rebuildRowData()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("readStatusDidChange"))) { notification in
            // Smart update: only rebuild the changed row (O(1) instead of O(n))
            if let changedID = notification.object as? UUID {
                updateSingleRowData(for: changedID)
            } else {
                // Fallback: unknown change, rebuild all
                rebuildRowData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .listViewSettingsDidChange)) { _ in
            // Reload settings when they change
            Task {
                listViewSettings = await ListViewSettingsStore.shared.settings
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recommendationTrainingEventRecorded)) { _ in
            // ADR-020: Recompute scores when user trains the model
            if sortOrder == .recommended {
                computeRecommendationScores()
            }
        }
        .onChange(of: selection) { _, newValue in
            // Update selection synchronously - the detail view defers its own update
            // Note: During Core Data background merges, managedObjectContext can temporarily
            // be nil. We still try to find the publication, but don't clear selection if
            // it's temporarily unavailable - this prevents selection being cleared during
            // background enrichment processing.
            if let firstID = newValue.first,
               let publication = publicationsByID[firstID],
               !publication.isDeleted {
                // Only update if we can confirm the publication is valid
                // Skip the managedObjectContext check as it can be temporarily nil during merges
                selectedPublication = publication

                // Scroll to selection when it changes (e.g., from global search navigation)
                // First check if the item would be filtered out - if so, clear filters
                let isInFilteredList = filteredRowData.contains { $0.id == firstID }

                if !isInFilteredList && rowDataCache[firstID] != nil {
                    // Item exists but is filtered out - clear filters to make it visible
                    // This handles navigation from global search to a read paper when unread filter is on
                    if showUnreadOnly {
                        showUnreadOnly = false
                    }
                    if !searchQuery.isEmpty {
                        searchQuery = ""
                    }
                    // Invalidate cache since we changed filters
                    filterCache.invalidate()
                }

                // Mark that we need to scroll to this ID - the actual scroll will happen
                // via scrollToSelectionWithRetry which handles timing issues
                pendingScrollTarget = firstID
            } else if newValue.isEmpty {
                // Only clear selection when user explicitly deselects (empty selection)
                // Don't clear when publication lookup fails - it might be temporarily
                // unavailable during Core Data background merges
                selectedPublication = nil
            }
            // If selection has IDs but lookup failed, keep the old selectedPublication
            // to avoid clearing selection during background processing

            if hasLoadedState {
                debouncedSaveState()
            }
        }
        .onChange(of: sortOrder) { _, newOrder in
            if hasLoadedState {
                debouncedSaveState()
            }
            // ADR-020: Compute recommendation scores when switching to recommended sort
            // Force update since user explicitly chose this sort order
            if newOrder == .recommended {
                computeRecommendationScores(force: true)
            }
        }
        .onChange(of: showUnreadOnly) { _, _ in
            // Validate selection when filter changes to remove orphaned IDs
            validateSelectionAgainstFilter()
            if hasLoadedState {
                debouncedSaveState()
            }
        }
        .onChange(of: searchQuery) { oldQuery, newQuery in
            // Auto-switch to "everything" scope when search is active
            if !newQuery.isEmpty && filterScope != .everything {
                filterScope = .everything
            } else if newQuery.isEmpty && oldQuery.isEmpty == false {
                // Switch back to "current" when search is cleared
                filterScope = .current
            }

            // Trigger PDF search if enabled and query changed
            if searchInPDFs && !newQuery.isEmpty {
                triggerPDFSearch()
            } else if newQuery.isEmpty {
                // Clear PDF matches when query is cleared
                pdfSearchMatches.removeAll()
            }

            // Validate selection when search filter changes to remove orphaned IDs
            validateSelectionAgainstFilter()
        }
    }

    // MARK: - PDF Search

    /// Trigger an async PDF content search
    private func triggerPDFSearch() {
        // Cancel any existing search
        pdfSearchTask?.cancel()

        guard !searchQuery.isEmpty else {
            pdfSearchMatches.removeAll()
            return
        }

        isPDFSearching = true

        pdfSearchTask = Task {
            let matches = await PDFSearchService.shared.search(
                query: searchQuery,
                in: publications,
                library: library
            )

            // Check if task was cancelled
            guard !Task.isCancelled else { return }

            await MainActor.run {
                pdfSearchMatches = matches
                isPDFSearching = false
                filterCache.invalidate()  // Force recompute with new PDF matches
            }
        }
    }

    // MARK: - Recommendation Scoring (ADR-020)

    /// Compute recommendation scores for all publications.
    ///
    /// - Parameter force: If true, bypasses the 30-minute throttle. Use when user explicitly
    ///   switches to recommendation sort. If false (default), respects the throttle to prevent
    ///   list order from changing while the user is browsing.
    private func computeRecommendationScores(force: Bool = false) {
        guard sortOrder == .recommended else { return }

        // Throttle updates to prevent list order from changing while user is browsing
        // Only bypass if forced (e.g., user explicitly switched to recommendation sort)
        if !force, let lastUpdate = lastRecommendationUpdate {
            let elapsed = Date().timeIntervalSince(lastUpdate)
            if elapsed < Self.recommendationUpdateInterval {
                Logger.performance.debug(
                    "Skipping recommendation update: \(Int(Self.recommendationUpdateInterval - elapsed))s until next allowed update"
                )
                return
            }
        }

        isComputingRecommendations = true

        Task {
            let ranked = await RecommendationEngine.shared.rank(publications)

            var newScores: [UUID: Double] = [:]
            var newSerendipity: Set<UUID> = []

            for item in ranked {
                newScores[item.publicationID] = item.score.total
                if item.isSerendipitySlot {
                    newSerendipity.insert(item.publicationID)
                }
            }

            await MainActor.run {
                recommendationScores = newScores
                serendipitySlotIDs = newSerendipity
                isComputingRecommendations = false
                lastRecommendationUpdate = Date()
                filterCache.invalidate()  // Force recompute with new scores
            }
        }
    }

    // MARK: - Row Data Management

    /// Rebuild both caches from current publications.
    /// - rowDataCache: [UUID: PublicationRowData] for display
    /// - publicationsByID: [UUID: CDPublication] for O(1) mutation lookups
    private func rebuildRowData() {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.performance.info("⏱ rebuildRowData: \(elapsed, format: .fixed(precision: 1))ms (\(publications.count) items)")
        }

        var newRowCache: [UUID: PublicationRowData] = [:]
        var newPubCache: [UUID: CDPublication] = [:]

        for pub in publications {
            newPubCache[pub.id] = pub
            // Use library name from mapping if available (for grouped search display)
            let libraryName = libraryNameMapping[pub.id]
            if let data = PublicationRowData(publication: pub, libraryName: libraryName) {
                newRowCache[pub.id] = data
            }
        }

        rowDataCache = newRowCache
        publicationsByID = newPubCache

        // Invalidate filtered data cache - it will be recomputed on next access
        filterCache.invalidate()

        // After rebuilding, check if we need to scroll to selection (for global search navigation)
        // This handles the case where selection was set before the row data was available
        if let firstID = selection.first, newRowCache[firstID] != nil {
            // Check if item would be filtered out and clear filters if needed
            let wouldBeFiltered = (showUnreadOnly && !disableUnreadFilter && (newRowCache[firstID]?.isRead ?? false)) ||
                                  (!searchQuery.isEmpty && !itemMatchesSearch(newRowCache[firstID]!))

            if wouldBeFiltered {
                if showUnreadOnly {
                    showUnreadOnly = false
                }
                if !searchQuery.isEmpty {
                    searchQuery = ""
                }
            }

            // Set pending scroll target - the retry mechanism will handle the actual scroll
            pendingScrollTarget = firstID
        }
    }

    /// Check if a row data item matches the current search query
    private func itemMatchesSearch(_ rowData: PublicationRowData) -> Bool {
        guard !searchQuery.isEmpty else { return true }
        let query = searchQuery.lowercased()
        return rowData.title.lowercased().contains(query) ||
               rowData.authorString.lowercased().contains(query) ||
               rowData.citeKey.lowercased().contains(query) ||
               (rowData.note?.lowercased().contains(query) ?? false)
    }

    /// Update a single row in the cache (O(1) instead of full rebuild).
    /// Used when only one publication's read status changed.
    private func updateSingleRowData(for publicationID: UUID) {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.performance.info("⏱ updateSingleRowData: \(elapsed, format: .fixed(precision: 2))ms")
        }

        guard let publication = publicationsByID[publicationID],
              !publication.isDeleted,
              publication.managedObjectContext != nil else {
            return
        }

        // Use library name from mapping if available
        let libraryName = libraryNameMapping[publicationID]
        if let updatedData = PublicationRowData(publication: publication, libraryName: libraryName) {
            rowDataCache[publicationID] = updatedData
        }

        // Invalidate filtered data cache - read status change may affect unread filter
        filterCache.invalidate()
    }

    // MARK: - State Persistence

    private func loadState() async {
        guard let listID = listID else {
            hasLoadedState = true
            return
        }

        if let state = await ListViewStateStore.shared.get(for: listID) {
            // Restore sort order and direction
            if let order = LibrarySortOrder(rawValue: state.sortOrder) {
                sortOrder = order
                sortAscending = state.sortAscending
            }
            showUnreadOnly = state.showUnreadOnly

            // On iOS, don't restore selection - it would trigger navigation via navigationDestination
            // On macOS, restore selection for the detail column display
            #if os(macOS)
            // Restore selection if publication still exists and is valid
            if let selectedID = state.selectedPublicationID,
               let publication = publicationsByID[selectedID],  // O(1) lookup instead of O(n)
               !publication.isDeleted,
               publication.managedObjectContext != nil {
                selection = [selectedID]
                // Also update selectedPublication directly for macOS detail column
                selectedPublication = publication
            }
            #endif
            // On iOS, selection restoration is skipped to prevent automatic navigation
            // Users tap to select and navigate; persisted state is used for sort/filter only
        }

        hasLoadedState = true
    }

    private func saveState() async {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.performance.info("⏱ saveState: \(elapsed, format: .fixed(precision: 1))ms")
        }

        guard let listID = listID else { return }

        let state = ListViewState(
            selectedPublicationID: selection.first,
            sortOrder: sortOrder.rawValue,
            sortAscending: sortAscending,
            showUnreadOnly: showUnreadOnly,
            lastVisitedDate: Date()
        )

        await ListViewStateStore.shared.save(state, for: listID)
    }

    /// Debounced save - waits 300ms before saving to avoid rapid saves during fast navigation
    private func debouncedSaveState() {
        // Cancel any pending save
        saveStateTask?.cancel()

        // Schedule new save with delay
        saveStateTask = Task {
            do {
                // Wait 300ms before saving (allows rapid selection changes without I/O overhead)
                try await Task.sleep(for: .milliseconds(300))
                await saveState()
            } catch {
                // Task was cancelled - a new selection happened, skip this save
            }
        }
    }

    // MARK: - Inline Toolbar

    private var inlineToolbar: some View {
        HStack(spacing: 12) {
            // Refresh button (only shown when onRefresh callback is provided)
            if let onRefresh = onRefresh {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                    .help("Refresh")
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Import button
            if showImportButton, let onImport = onImport {
                Button {
                    onImport()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .foregroundStyle(.secondary)
                .help("Import BibTeX")
                .buttonStyle(.plain)
            }

            // Collapsible search section (moved to right side)
            if isSearchExpanded {
                // Expanded: show full search field with options
                HStack(spacing: 8) {
                    // PDF search toggle
                    Button {
                        searchInPDFs.toggle()
                        if searchInPDFs && !searchQuery.isEmpty {
                            triggerPDFSearch()
                        } else if !searchInPDFs {
                            pdfSearchMatches.removeAll()
                            filterCache.invalidate()
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.text.magnifyingglass")
                            if isPDFSearching {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                    }
                    .foregroundStyle(searchInPDFs ? .blue : .secondary)
                    .help(searchInPDFs ? "Disable PDF content search" : "Include PDF content in search")
                    .buttonStyle(.plain)

                    // Search field
                    HStack {
                        TextField("Search all libraries", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.List.searchField)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear search")
                            .accessibilityIdentifier(AccessibilityID.Search.clearButton)
                        }
                    }
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .help("Filter by title, author, cite key, or notes")

                    // Collapse button
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchExpanded = false
                            // Clear search when collapsing
                            if searchQuery.isEmpty {
                                searchInPDFs = false
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse search")
                }
            } else {
                // Collapsed: show magnifying glass icon that expands on tap
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSearchExpanded = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(searchQuery.isEmpty && !searchInPDFs ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .help("Expand search")
            }

            // Sort menu - click same option again to toggle ascending/descending
            if showSortMenu {
                Menu {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Button {
                            if sortOrder == order {
                                // Same order selected - toggle direction
                                sortAscending.toggle()
                            } else {
                                // Different order - set new order with default direction
                                sortOrder = order
                                sortAscending = order.defaultAscending
                            }
                        } label: {
                            HStack {
                                Text(order.displayName)
                                Spacer()
                                if sortOrder == order {
                                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .foregroundStyle(.secondary)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change sort order (click again to reverse)")
                .accessibilityIdentifier(AccessibilityID.List.sortButton)
            }

            // Total count display
            countDisplay
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Display of filtered/total count
    private var countDisplay: some View {
        let filteredCount = filteredRowData.count
        let totalCount = publications.count
        let isFiltered = !searchQuery.isEmpty || showUnreadOnly

        return Group {
            if isFiltered && filteredCount != totalCount {
                Text("\(filteredCount) of \(totalCount)")
            } else {
                Text("\(filteredCount) papers")
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    // MARK: - Publication List

    private var publicationList: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if shouldShowGroupedDisplay {
                    // Grouped display: show collapsible sections by library
                    ForEach(groupedFilteredRowData) { group in
                        Section(isExpanded: expandedSectionBinding(for: group.name)) {
                            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, rowData in
                                makePublicationRow(data: rowData, index: index)
                                    .tag(rowData.id)
                                    .id(rowData.id)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                // Disclosure chevron that rotates based on expanded state
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(
                                        expandedSectionBinding(for: group.name).wrappedValue
                                            ? .degrees(90)
                                            : .degrees(0)
                                    )
                                    .animation(.easeInOut(duration: 0.2), value: expandedSectionBinding(for: group.name).wrappedValue)

                                Text(group.name)
                                    .font(.headline)

                                Text("(\(group.rows.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } else {
                    // Flat display: no grouping
                    ForEach(Array(filteredRowData.enumerated()), id: \.element.id) { index, rowData in
                        makePublicationRow(data: rowData, index: index)
                            .tag(rowData.id)
                            .id(rowData.id)  // For ScrollViewReader
                    }
                }
            }
            // OPTIMIZATION: Disable selection animations for instant visual feedback
            .animation(nil, value: selection)
            .transaction { $0.animation = nil }
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenuItems(for: ids)
            } primaryAction: { ids in
                // Double-click to open PDF - O(1) lookup
                if let first = ids.first,
                   let publication = publicationsByID[first],
                   let onOpenPDF = onOpenPDF {
                    onOpenPDF(publication)
                }
            }
            .onAppear {
                scrollProxy = proxy
            }
            // Apply transparent background when theme has custom background color
            .scrollContentBackground(theme.detailBackground != nil || theme.listBackgroundTint != nil ? .hidden : .automatic)
            .background {
                if let tint = theme.listBackgroundTint {
                    tint.opacity(theme.listBackgroundTintOpacity)
                }
            }
            // PDF drop support on list background
            .onDrop(of: DragDropCoordinator.acceptedTypes, isTargeted: $isListDropTargeted) { providers in
                handleListDrop(providers: providers)
            }
            .overlay {
                if isListDropTargeted {
                    listDropTargetOverlay
                }
            }
        #if os(macOS)
        .onDeleteCommand {
            if let onDelete = onDelete {
                let idsToDelete = selection
                // Clear selection immediately before deletion to prevent accessing deleted objects
                selection.removeAll()
                selectedPublication = nil
                Task { await onDelete(idsToDelete) }
            }
        }
        // Keyboard navigation handlers from menu/notifications
        .onReceive(NotificationCenter.default.publisher(for: .navigateNextPaper)) { _ in
            navigateToNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigatePreviousPaper)) { _ in
            navigateToPrevious()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateFirstPaper)) { _ in
            navigateToFirst()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateLastPaper)) { _ in
            navigateToLast()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateNextUnread)) { _ in
            navigateToNextUnread()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigatePreviousUnread)) { _ in
            navigateToPreviousUnread()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedPaper)) { _ in
            openSelectedPaper()
        }
        // NOTE: .toggleReadStatus is handled by parent views (UnifiedPublicationListWrapper, ContentView, SearchView)
        // which use smartToggleReadStatus() for correct "if any unread → all read" behavior.
        // Do NOT add a handler here - it would conflict and cause double-toggling.
        .onReceive(NotificationCenter.default.publisher(for: .markAllAsRead)) { _ in
            markAllAsRead()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleUnreadFilter)) { _ in
            if !disableUnreadFilter {
                showUnreadOnly.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedPapers)) { _ in
            deleteSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToSelection)) { _ in
            // Scroll to current selection (used by global search navigation)
            if let id = selection.first {
                pendingScrollTarget = id
            }
        }
        // Handle pending scroll target with retry mechanism
        .onChange(of: pendingScrollTarget) { _, newTarget in
            guard let targetID = newTarget else { return }
            scrollToTargetWithRetry(targetID, attempts: 0)
        }
        #endif
        }  // End ScrollViewReader
    }

    // MARK: - Keyboard Navigation

    /// Select a row and scroll to make it visible
    private func selectAndScrollTo(_ id: UUID) {
        selection = [id]
        withAnimation(.easeInOut(duration: 0.15)) {
            scrollProxy?.scrollTo(id, anchor: .center)
        }
    }

    /// Scroll to a target ID with retry mechanism to handle timing issues
    ///
    /// This function attempts to scroll to the target, waiting for the list to stabilize.
    /// It retries multiple times with increasing delays to handle cases where:
    /// - The scroll proxy isn't ready yet
    /// - The list is still laying out after data changes
    /// - SwiftUI needs time to render the target row
    private func scrollToTargetWithRetry(_ targetID: UUID, attempts: Int) {
        let maxAttempts = 5
        let delays: [UInt64] = [50_000_000, 100_000_000, 150_000_000, 200_000_000, 300_000_000] // nanoseconds

        // Check if this is still the pending target (might have changed)
        guard pendingScrollTarget == targetID else { return }

        // Check if target is in the filtered list
        let isInList = filteredRowData.contains { $0.id == targetID }

        guard isInList else {
            // Target not in filtered list - might need filter clearing (handled elsewhere)
            // Or the target doesn't exist in current view
            Logger.performance.debug("Scroll target \(targetID) not in filtered list")
            pendingScrollTarget = nil
            return
        }

        guard let proxy = scrollProxy else {
            // Scroll proxy not ready yet - retry
            if attempts < maxAttempts {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: delays[min(attempts, delays.count - 1)])
                    scrollToTargetWithRetry(targetID, attempts: attempts + 1)
                }
            } else {
                Logger.performance.warning("Scroll proxy not available after \(maxAttempts) attempts")
                pendingScrollTarget = nil
            }
            return
        }

        // Perform the scroll
        Task { @MainActor in
            // Wait a bit for the list to stabilize
            try? await Task.sleep(nanoseconds: delays[min(attempts, delays.count - 1)])

            // Check again if this is still the target
            guard pendingScrollTarget == targetID else { return }

            // Perform scroll without animation wrapper (List has animations disabled)
            proxy.scrollTo(targetID, anchor: .center)

            // Clear the pending target after a brief moment
            // (allows the scroll to complete before accepting new targets)
            try? await Task.sleep(nanoseconds: 100_000_000)
            if pendingScrollTarget == targetID {
                pendingScrollTarget = nil
            }
        }
    }

    /// Navigate to next paper in the filtered list
    private func navigateToNext() {
        let rows = filteredRowData
        guard !rows.isEmpty else { return }

        if let currentID = selection.first,
           let currentIndex = rows.firstIndex(where: { $0.id == currentID }) {
            let nextIndex = min(currentIndex + 1, rows.count - 1)
            selectAndScrollTo(rows[nextIndex].id)
        } else {
            // No selection, select first
            selectAndScrollTo(rows[0].id)
        }
    }

    /// Navigate to previous paper in the filtered list
    private func navigateToPrevious() {
        let rows = filteredRowData
        guard !rows.isEmpty else { return }

        if let currentID = selection.first,
           let currentIndex = rows.firstIndex(where: { $0.id == currentID }) {
            let prevIndex = max(currentIndex - 1, 0)
            selectAndScrollTo(rows[prevIndex].id)
        } else {
            // No selection, select first
            selectAndScrollTo(rows[0].id)
        }
    }

    /// Navigate to first paper
    private func navigateToFirst() {
        let rows = filteredRowData
        guard !rows.isEmpty else { return }
        selectAndScrollTo(rows[0].id)
    }

    /// Navigate to last paper
    private func navigateToLast() {
        let rows = filteredRowData
        guard !rows.isEmpty else { return }
        selectAndScrollTo(rows[rows.count - 1].id)
    }

    /// Navigate to next unread paper
    private func navigateToNextUnread() {
        let rows = filteredRowData
        guard !rows.isEmpty else { return }

        let startIndex: Int
        if let currentID = selection.first,
           let currentIndex = rows.firstIndex(where: { $0.id == currentID }) {
            startIndex = currentIndex + 1
        } else {
            startIndex = 0
        }

        // Search from current position to end
        for i in startIndex..<rows.count {
            if !rows[i].isRead {
                selectAndScrollTo(rows[i].id)
                return
            }
        }

        // Wrap around: search from beginning to current position
        for i in 0..<startIndex {
            if !rows[i].isRead {
                selectAndScrollTo(rows[i].id)
                return
            }
        }
    }

    /// Navigate to previous unread paper
    private func navigateToPreviousUnread() {
        let rows = filteredRowData
        guard !rows.isEmpty else { return }

        let startIndex: Int
        if let currentID = selection.first,
           let currentIndex = rows.firstIndex(where: { $0.id == currentID }) {
            startIndex = currentIndex - 1
        } else {
            startIndex = rows.count - 1
        }

        // Search backwards from current position
        for i in stride(from: startIndex, through: 0, by: -1) {
            if !rows[i].isRead {
                selectAndScrollTo(rows[i].id)
                return
            }
        }

        // Wrap around: search backwards from end
        for i in stride(from: rows.count - 1, through: max(0, startIndex + 1), by: -1) {
            if !rows[i].isRead {
                selectAndScrollTo(rows[i].id)
                return
            }
        }
    }

    /// Open selected paper (show PDF tab)
    private func openSelectedPaper() {
        guard let firstID = selection.first,
              let publication = publicationsByID[firstID],  // O(1) lookup
              !publication.isDeleted,
              publication.managedObjectContext != nil,
              let onOpenPDF = onOpenPDF else { return }

        onOpenPDF(publication)
    }

    /// Mark all visible papers as read
    private func markAllAsRead() {
        guard let onToggleRead = onToggleRead else { return }

        for rowData in filteredRowData {
            if !rowData.isRead,
               let publication = publicationsByID[rowData.id],  // O(1) lookup
               !publication.isDeleted,
               publication.managedObjectContext != nil {
                Task {
                    await onToggleRead(publication)
                }
            }
        }
    }

    /// Delete selected papers
    private func deleteSelected() {
        guard let onDelete = onDelete, !selection.isEmpty else { return }

        let idsToDelete = selection
        // Clear selection immediately before deletion
        selection.removeAll()
        selectedPublication = nil
        Task { await onDelete(idsToDelete) }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for ids: Set<UUID>) -> some View {
        // Open PDF
        if let onOpenPDF = onOpenPDF {
            Button("Open PDF") {
                if let first = ids.first,
                   let publication = publicationsByID[first] {  // O(1) lookup
                    onOpenPDF(publication)
                }
            }

            Divider()
        }

        // Copy/Cut
        if let onCopy = onCopy {
            Button("Copy") {
                Task { await onCopy(ids) }
            }
        }

        if let onCut = onCut {
            Button("Cut") {
                Task { await onCut(ids) }
            }
        }

        // Copy Cite Key
        Button("Copy Cite Key") {
            if let first = ids.first,
               let rowData = rowDataCache[first] {
                copyToClipboard(rowData.citeKey)
            }
        }

        // Download PDFs (only shown when multiple papers selected)
        if let onDownloadPDFs = onDownloadPDFs, ids.count > 1 {
            Divider()
            Button {
                onDownloadPDFs(ids)
            } label: {
                Label("Download PDFs", systemImage: "arrow.down.doc")
            }
        }

        Divider()

        // Add to Library submenu (publications can belong to multiple libraries)
        // Each library is a submenu showing "All Publications" plus any collections
        if let onAddToLibrary = onAddToLibrary, !allLibraries.isEmpty {
            let otherLibraries = allLibraries.filter { $0.id != library?.id }
            if !otherLibraries.isEmpty {
                Menu("Add to Library") {
                    ForEach(otherLibraries, id: \.id) { targetLibrary in
                        let targetCollections = (targetLibrary.collections as? Set<CDCollection>)?
                            .filter { !$0.isSmartCollection && !$0.isSmartSearchResults }
                            .sorted { $0.name < $1.name } ?? []

                        Menu(targetLibrary.displayName) {
                            Button("All Publications") {
                                Task {
                                    await onAddToLibrary(ids, targetLibrary)
                                }
                            }
                            if !targetCollections.isEmpty {
                                Divider()
                                ForEach(targetCollections, id: \.id) { collection in
                                    Button(collection.name) {
                                        Task {
                                            await onAddToLibrary(ids, targetLibrary)
                                            if let onAddToCollection = onAddToCollection {
                                                await onAddToCollection(ids, collection)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Add to Collection submenu (with "All Publications" option to remove from all collections)
        if onAddToCollection != nil || onRemoveFromAllCollections != nil {
            // Show menu if we have collections OR have the remove callback
            if !staticCollections.isEmpty || onRemoveFromAllCollections != nil {
                Menu("Add to Collection") {
                    // "All Publications" removes from all collections
                    if let onRemoveFromAllCollections = onRemoveFromAllCollections {
                        Button("All Publications") {
                            Task {
                                await onRemoveFromAllCollections(ids)
                            }
                        }

                        if !staticCollections.isEmpty {
                            Divider()
                        }
                    }

                    // Static collections
                    if let onAddToCollection = onAddToCollection {
                        ForEach(staticCollections, id: \.id) { collection in
                            Button(collection.name) {
                                Task {
                                    await onAddToCollection(ids, collection)
                                }
                            }
                        }
                    }
                }
            }
        }

        // MARK: Keep/Triage Actions

        // Keep to Library (adds to target library AND removes from current library)
        // Available for all views, not just Inbox
        if let onSaveToLibrary = onSaveToLibrary, !allLibraries.isEmpty {
            // Filter out current library and Inbox from keep targets
            let keepLibraries = allLibraries.filter { $0.id != library?.id && !$0.isInbox }
            if !keepLibraries.isEmpty {
                Menu("Keep to Library") {
                    ForEach(keepLibraries, id: \.id) { targetLibrary in
                        Button(targetLibrary.displayName) {
                            Task {
                                await onSaveToLibrary(ids, targetLibrary)
                            }
                        }
                    }
                }
            }
        }

        // Dismiss from Inbox
        if let onDismiss = onDismiss {
            Button("Dismiss from Inbox") {
                Task { await onDismiss(ids) }
            }
        }

        // Mute options
        if onMuteAuthor != nil || onMutePaper != nil {
            Divider()

            if let onMuteAuthor = onMuteAuthor {
                // Get first author of first selected publication - O(1) lookup
                if let first = ids.first,
                   let publication = publicationsByID[first],
                   let firstAuthor = publication.sortedAuthors.first {
                    let authorName = firstAuthor.displayName
                    Button("Mute Author: \(authorName)") {
                        onMuteAuthor(authorName)
                    }
                }
            }

            if let onMutePaper = onMutePaper {
                if let first = ids.first,
                   let publication = publicationsByID[first] {  // O(1) lookup
                    Button("Mute This Paper") {
                        onMutePaper(publication)
                    }
                }
            }
        }

        Divider()

        // Delete
        if let onDelete = onDelete {
            Button("Delete", role: .destructive) {
                // Clear selection immediately before deletion
                selection.removeAll()
                selectedPublication = nil
                Task {
                    await onDelete(ids)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyStateMessage, systemImage: "books.vertical")
        } description: {
            Text(emptyStateDescription)
        } actions: {
            if showImportButton, let onImport = onImport {
                Button("Import BibTeX...") {
                    onImport()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Row Builder

    /// Build a publication row with all callbacks wired up.
    /// This is extracted to a helper method to avoid "expression too complex" compiler errors.
    @ViewBuilder
    private func makePublicationRow(data rowData: PublicationRowData, index: Int) -> some View {
        #if os(iOS)
        // On iOS, List selection doesn't work without edit mode.
        // Use simultaneousGesture to allow both tap (selection) and swipe actions to coexist.
        rowContent(data: rowData, index: index)
            .contentShape(Rectangle())  // Make entire row tappable
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        selection = [rowData.id]
                    }
            )
        #else
        rowContent(data: rowData, index: index)
        #endif
    }

    @ViewBuilder
    private func rowContent(data rowData: PublicationRowData, index: Int) -> some View {
        let deleteHandler: (() -> Void)? = onDelete != nil ? {
            Task { await onDelete?([rowData.id]) }
        } : nil

        let saveHandler: (() -> Void)? = {
            guard onSaveToLibrary != nil else { return nil }
            // Use the configured keep library if provided, otherwise fall back to first non-inbox library
            let targetLibrary: CDLibrary? = saveLibrary ?? allLibraries.first { !$0.isInbox }
            guard let library = targetLibrary else { return nil }
            return {
                // Show green flash for keep action
                withAnimation(.easeIn(duration: 0.1)) {
                    triageFlashState = (rowData.id, .green)
                }
                // Delay triage action to let flash be visible
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.1)) {
                            triageFlashState = nil
                        }
                    }
                    await onSaveToLibrary?([rowData.id], library)
                }
            }
        }()

        let dismissHandler: (() -> Void)? = onDismiss != nil ? {
            // Show orange flash for dismiss action
            withAnimation(.easeIn(duration: 0.1)) {
                triageFlashState = (rowData.id, .orange)
            }
            // Delay triage action to let flash be visible
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.1)) {
                        triageFlashState = nil
                    }
                }
                await onDismiss?([rowData.id])
            }
        } : nil

        let toggleReadHandler: (() -> Void)? = onToggleRead != nil ? {
            if let pub = publicationsByID[rowData.id] {
                Task { await onToggleRead?(pub) }
            }
        } : nil

        let openPDFHandler: (() -> Void)? = (onOpenPDF != nil && rowData.hasPDFAvailable) ? {
            if let pub = publicationsByID[rowData.id] {
                onOpenPDF?(pub)
            }
        } : nil

        let copyBibTeXHandler: (() -> Void)? = onCopy != nil ? {
            Task { await onCopy?([rowData.id]) }
        } : nil

        let addToCollectionHandler: ((CDCollection) -> Void)? = onAddToCollection != nil ? { collection in
            Task { await onAddToCollection?([rowData.id], collection) }
        } : nil

        let muteAuthorHandler: (() -> Void)? = onMuteAuthor != nil ? {
            let firstName = rowData.authorString.split(separator: ",").first.map(String.init) ?? rowData.authorString
            onMuteAuthor?(firstName)
        } : nil

        let mutePaperHandler: (() -> Void)? = onMutePaper != nil ? {
            if let pub = publicationsByID[rowData.id] {
                onMutePaper?(pub)
            }
        } : nil

        // New context menu handlers
        let openInBrowserHandler: ((BrowserDestination) -> Void)? = onOpenInBrowser != nil ? { destination in
            if let pub = publicationsByID[rowData.id] {
                onOpenInBrowser?(pub, destination)
            }
        } : nil

        let downloadPDFHandler: (() -> Void)? = (onDownloadPDF != nil && !rowData.hasDownloadedPDF) ? {
            if let pub = publicationsByID[rowData.id] {
                onDownloadPDF?(pub)
            }
        } : nil

        let viewEditBibTeXHandler: (() -> Void)? = onViewEditBibTeX != nil ? {
            if let pub = publicationsByID[rowData.id] {
                onViewEditBibTeX?(pub)
            }
        } : nil

        let shareHandler: (() -> Void)? = onShare != nil ? {
            if let pub = publicationsByID[rowData.id] {
                onShare?(pub)
            }
        } : nil

        let shareByEmailHandler: (() -> Void)? = onShareByEmail != nil ? {
            if let pub = publicationsByID[rowData.id] {
                onShareByEmail?(pub)
            }
        } : nil

        let exploreReferencesHandler: (() -> Void)? = onExploreReferences != nil ? {
            if let pub = publicationsByID[rowData.id] {
                onExploreReferences?(pub)
            }
        } : nil

        let exploreCitationsHandler: (() -> Void)? = onExploreCitations != nil ? {
            if let pub = publicationsByID[rowData.id] {
                onExploreCitations?(pub)
            }
        } : nil

        let exploreSimilarHandler: (() -> Void)? = onExploreSimilar != nil ? {
            if let pub = publicationsByID[rowData.id] {
                onExploreSimilar?(pub)
            }
        } : nil

        let addToLibraryHandler: ((CDLibrary) -> Void)? = onAddToLibrary != nil ? { library in
            Task { await onAddToLibrary?([rowData.id], library) }
        } : nil

        // ADR-020: Show recommendation score when sorting by recommended
        let scoreToShow: Double? = sortOrder == .recommended ? recommendationScores[rowData.id] : nil

        // Show highlighted citation count when sorting by citations
        let citationCountToShow: Int? = sortOrder == .citationCount ? rowData.citationCount : nil

        // Triage flash feedback: check both internal (row action) and external (keyboard shortcut) triggers
        let flashColor: Color? = {
            if triageFlashState?.id == rowData.id {
                return triageFlashState?.color
            }
            if externalTriageFlash?.id == rowData.id {
                return externalTriageFlash?.color
            }
            return nil
        }()

        MailStylePublicationRow(
            data: rowData,
            settings: listViewSettings,
            onToggleRead: toggleReadHandler,
            onCategoryTap: onCategoryTap,
            onDelete: deleteHandler,
            onSave: saveHandler,
            onDismiss: dismissHandler,
            isInInbox: isInInbox,
            onOpenPDF: openPDFHandler,
            onCopyCiteKey: { copyToClipboard(rowData.citeKey) },
            onCopyBibTeX: copyBibTeXHandler,
            onAddToCollection: addToCollectionHandler,
            onMuteAuthor: muteAuthorHandler,
            onMutePaper: mutePaperHandler,
            collections: staticCollections,
            hasPDF: rowData.hasPDFAvailable,
            // New context menu callbacks
            onOpenInBrowser: openInBrowserHandler,
            onDownloadPDF: downloadPDFHandler,
            onViewEditBibTeX: viewEditBibTeXHandler,
            onShare: shareHandler,
            onShareByEmail: shareByEmailHandler,
            onExploreReferences: exploreReferencesHandler,
            onExploreCitations: exploreCitationsHandler,
            onExploreSimilar: exploreSimilarHandler,
            onAddToLibrary: addToLibraryHandler,
            libraries: allLibraries.filter { !$0.isInbox },  // Exclude Inbox from library list
            recommendationScore: scoreToShow,
            highlightedCitationCount: citationCountToShow,
            triageFlashColor: flashColor
        )
    }

    // MARK: - Helpers

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Validate selection against current filtered data.
    /// Removes any selected IDs that are no longer visible due to filtering.
    private func validateSelectionAgainstFilter() {
        // Don't validate if publications haven't loaded yet - this would incorrectly
        // clear selection when switching sections before the list loads
        guard !rowDataCache.isEmpty else { return }

        let validIDs = Set(filteredRowData.map { $0.id })
        let orphanedIDs = selection.subtracting(validIDs)
        if !orphanedIDs.isEmpty {
            selection = selection.intersection(validIDs)
        }
    }

    /// Handle file drop on a publication row
    private func handleFileDrop(providers: [NSItemProvider], for publicationID: UUID) -> Bool {
        guard let onFileDrop = onFileDrop,
              let publication = publicationsByID[publicationID],  // O(1) lookup
              !publication.isDeleted,
              publication.managedObjectContext != nil else {
            return false
        }

        onFileDrop(publication, providers)
        return true
    }

    /// Handle PDF drop on list background for import
    private func handleListDrop(providers: [NSItemProvider]) -> Bool {
        guard let onListDrop = onListDrop else {
            return false
        }

        // Determine the drop target based on current library
        let target: DropTarget
        if let library = library {
            target = .library(libraryID: library.id)
        } else {
            // Fall back to inbox if no library context
            target = .inbox
        }

        onListDrop(providers, target)
        return true
    }

    /// Overlay shown when dragging PDFs over the list
    private var listDropTargetOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.1)

            VStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)

                Text("Drop PDFs to Import")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Papers will be added to this library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Preview

#Preview {
    let context = PersistenceController.preview.viewContext
    let publications: [CDPublication] = context.performAndWait {
        let pub1 = CDPublication(context: context)
        pub1.id = UUID()
        pub1.citeKey = "Einstein1905"
        pub1.entryType = "article"
        pub1.title = "On the Electrodynamics of Moving Bodies"
        pub1.year = 1905
        pub1.dateAdded = Date()
        pub1.dateModified = Date()
        pub1.isRead = false
        pub1.fields = ["author": "Einstein, Albert"]

        let pub2 = CDPublication(context: context)
        pub2.id = UUID()
        pub2.citeKey = "Hawking1974"
        pub2.entryType = "article"
        pub2.title = "Black hole explosions?"
        pub2.year = 1974
        pub2.dateAdded = Date()
        pub2.dateModified = Date()
        pub2.isRead = true
        pub2.fields = ["author": "Hawking, Stephen W."]

        return [pub1, pub2]
    }

    return PublicationListView(
        publications: publications,
        selection: .constant([]),
        selectedPublication: .constant(nil),
        showImportButton: true,
        showSortMenu: true,
        filterScope: .constant(.current),
        onImport: { print("Import tapped") }
    )
}
