//
//  PublicationListView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import SwiftUI
import OSLog
import ImpressFTUI

// MARK: - Filter Scope

/// Scope for filtering publications in the search field
nonisolated public enum FilterScope: String, CaseIterable, Identifiable {
    case current = "Current"
    case allLibraries = "All Libraries"
    case inbox = "Inbox"
    case everything = "Everything"

    public var id: String { rawValue }
}

// MARK: - Filter Cache

/// Cache key for memoizing filtered row data
nonisolated private struct FilterCacheKey: Equatable {
    let rowDataVersion: Int
    let showUnreadOnly: Bool
    let disableUnreadFilter: Bool
    let sortOrder: LibrarySortOrder
    let sortAscending: Bool  // Direction toggle
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

    /// Update a single row in the cached sorted array without full invalidation.
    /// O(n) scan but avoids O(n log n) re-sort. No-op if cache is empty.
    func updateRow(_ id: UUID, with data: PublicationRowData) {
        guard let result = cachedResult,
              let index = result.firstIndex(where: { $0.id == id }) else { return }
        cachedResult?[index] = data
    }

    func invalidate() {
        cachedKey = nil
        cachedResult = nil
    }
}

/// Holds the current selection for drag operations.
/// Uses a class so rows can read the current value at drag time without closure capture issues.
@MainActor
public final class DragSelectionHolder {
    public var selectedIDs: Set<UUID> = []

    public init() {}
}

/// Unified publication list view used by Library, Smart Search, and Ad-hoc Search.
///
/// Per ADR-016, all papers are publication entities and should have identical
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
/// This view uses `[PublicationRowData]` (value types) for rendering
/// before rendering. This eliminates crashes during bulk deletion where Core Data
/// objects become invalid while SwiftUI is still rendering.
public struct PublicationListView: View {

    // MARK: - Properties

    /// All publications to display (before filtering/sorting).
    /// Data arrives pre-shaped from RustStoreAdapter — no Core Data conversion needed.
    public let publications: [PublicationRowData]

    /// Multi-selection binding
    @Binding public var selection: Set<UUID>

    /// Single-selection binding (updated when selection changes to first selected ID)
    @Binding public var selectedPublicationID: UUID?

    /// Library ID for context menu operations (Add to Library, Add to Collection)
    public var libraryID: UUID?

    /// All available libraries for "Add to Library" menu (id, name pairs)
    public var allLibraries: [(id: UUID, name: String)] = []

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

    /// The target library ID for "keep" swipe action (configured via Settings > Inbox).
    /// When nil, the first non-inbox library is used as fallback.
    public var saveLibraryID: UUID?

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
    public var onToggleRead: ((UUID) async -> Void)?

    /// Called when copy is requested
    public var onCopy: ((Set<UUID>) async -> Void)?

    /// Called when cut is requested
    public var onCut: ((Set<UUID>) async -> Void)?

    /// Called when paste is requested
    public var onPaste: (() async -> Void)?

    /// Called when add to library is requested (publications can belong to multiple libraries)
    public var onAddToLibrary: ((Set<UUID>, UUID) async -> Void)?

    /// Called when add to collection is requested
    public var onAddToCollection: ((Set<UUID>, UUID) async -> Void)?

    /// Called when remove from all collections is requested ("All Publications")
    public var onRemoveFromAllCollections: ((Set<UUID>) async -> Void)?

    /// Called when import is requested (import button clicked)
    public var onImport: (() -> Void)?

    /// Called when open PDF is requested
    public var onOpenPDF: ((UUID) -> Void)?

    /// Called when files are dropped onto a publication row
    public var onFileDrop: ((UUID, [NSItemProvider]) -> Void)?

    /// Called when PDFs are dropped onto the list background (for import)
    public var onListDrop: (([NSItemProvider], DropTarget) -> Void)?

    /// Called when "Download PDFs" is requested for selected publications
    public var onDownloadPDFs: ((Set<UUID>) -> Void)?

    /// Called when "Send to E-Ink Device" is requested
    public var onSendToEInkDevice: ((Set<UUID>) -> Void)?

    // MARK: - Inbox Triage Callbacks

    /// Called when keep to library is requested (Inbox: adds to library AND removes from Inbox)
    public var onSaveToLibrary: ((Set<UUID>, UUID) async -> Void)?

    /// Called when dismiss is requested (Inbox: remove from Inbox)
    public var onDismiss: ((Set<UUID>) async -> Void)?

    /// Called when toggle star is requested
    public var onToggleStar: ((Set<UUID>) async -> Void)?

    /// Called when a flag is set on publications
    public var onSetFlag: ((Set<UUID>, FlagColor) async -> Void)?

    /// Called when flag is cleared from publications
    public var onClearFlag: ((Set<UUID>) async -> Void)?

    /// Called when adding a tag to publications is requested
    public var onAddTag: ((Set<UUID>) -> Void)?

    /// Called when removing a tag from a publication
    public var onRemoveTag: ((UUID, UUID) -> Void)?

    /// Called when mute author is requested
    public var onMuteAuthor: ((String) -> Void)?

    /// Called when mute paper is requested (by DOI or bibcode)
    public var onMutePaper: ((UUID) -> Void)?

    /// Called when a category chip is tapped (e.g., to search for that category)
    public var onCategoryTap: ((String) -> Void)?

    /// Called when global search should be shown (magnifying glass or Cmd+F)
    public var onGlobalSearch: (() -> Void)?

    /// Called when refresh is requested (for smart searches and feeds)
    public var onRefresh: (() async -> Void)?

    // MARK: - Enhanced Context Menu Callbacks

    /// Called when Open in Browser is requested (arXiv, ADS, DOI)
    public var onOpenInBrowser: ((UUID, BrowserDestination) -> Void)?

    /// Called when Download PDF is requested (for papers without PDF)
    public var onDownloadPDF: ((UUID) -> Void)?

    /// Called when View/Edit BibTeX is requested
    public var onViewEditBibTeX: ((UUID) -> Void)?

    /// Called when Share (system share sheet) is requested
    public var onShare: ((UUID) -> Void)?

    /// Called when Share by Email is requested (with PDF + BibTeX attachments)
    public var onShareByEmail: ((UUID) -> Void)?

    /// Called when Explore References is requested
    public var onExploreReferences: ((UUID) -> Void)?

    /// Called when Explore Citations is requested
    public var onExploreCitations: ((UUID) -> Void)?

    /// Called when Explore Similar Papers is requested
    public var onExploreSimilar: ((UUID) -> Void)?

    /// Whether a refresh is in progress (shows loading indicator)
    public var isRefreshing: Bool = false

    /// External triage flash trigger (for keyboard shortcuts from parent view)
    /// When set by parent, triggers flash animation on the specified row
    @Binding public var externalTriageFlash: (id: UUID, color: Color)?

    // MARK: - Internal State

    @State private var showUnreadOnly: Bool = false
    @State private var hasLoadedState: Bool = false

    /// ADR-020: Serendipity slot tracking
    @State private var serendipitySlotIDs: Set<UUID> = []
    @State private var isComputingRecommendations: Bool = false
    @State private var lastRecommendationUpdate: Date?

    /// Minimum interval between recommendation score updates (30 minutes)
    /// Prevents list order from changing while user is browsing
    private static let recommendationUpdateInterval: TimeInterval = 30 * 60

    /// Cached row data - rebuilt when publications change
    @State private var rowDataCache: [UUID: PublicationRowData] = [:]

    /// Cached publication lookup - O(1) instead of O(n) linear scans
    /// (Only row data is cached — no managed object storage)
    // publicationsByID removed: no longer needed with pre-shaped PublicationRowData

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

    /// Holds current selection for drag operations (class to avoid closure capture issues)
    @State private var dragSelectionHolder = DragSelectionHolder()

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

    // staticCollections removed: collections handled at parent level via UUID-based callbacks
    // Collection-related context menus pass through UUID-based callbacks to parent

    /// Filtered and sorted row data - memoized to avoid repeated computation
    private var filteredRowData: [PublicationRowData] {
        // Create cache key from all inputs
        let cacheKey = FilterCacheKey(
            rowDataVersion: rowDataCache.count,
            showUnreadOnly: showUnreadOnly,
            disableUnreadFilter: disableUnreadFilter,
            sortOrder: sortOrder,
            sortAscending: sortAscending,
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

        // Sort using data already in PublicationRowData - no managed object lookups needed
        // Uses stable UUID tie-breaker so order is deterministic across calls.
        // MUST match UnifiedPublicationListWrapper.computeVisualOrder() exactly.
        let sorted = result.sorted { lhs, rhs in
            let primary = Self.primarySortComparison(lhs, rhs, sortOrder: sortOrder, sortAscending: sortAscending, recommendationScores: recommendationScores)
            if primary != .orderedSame { return primary == .orderedAscending }
            // Stable tie-breaker: UUID string comparison
            return lhs.id.uuidString < rhs.id.uuidString
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

    /// Grouped display is no longer needed — global search handles cross-library results
    private var groupedFilteredRowData: [LibraryGroup] { [] }

    /// Whether to show grouped display (always false — grouped display moved to global search)
    private var shouldShowGroupedDisplay: Bool { false }

    /// Primary sort comparison — returns .orderedSame when items are equal on the sort key.
    /// Static so it can be called from sorted() closures without capturing self.
    /// MUST match UnifiedPublicationListWrapper.primarySortComparison() logic exactly.
    private static func primarySortComparison(
        _ lhs: PublicationRowData, _ rhs: PublicationRowData,
        sortOrder: LibrarySortOrder, sortAscending: Bool,
        recommendationScores: [UUID: Double]
    ) -> ComparisonResult {
        let ascending = sortAscending == sortOrder.defaultAscending

        switch sortOrder {
        case .recommended:
            let lhsScore = recommendationScores[lhs.id] ?? 0
            let rhsScore = recommendationScores[rhs.id] ?? 0
            if lhsScore != rhsScore {
                let result: ComparisonResult = lhsScore > rhsScore ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            if lhs.dateAdded != rhs.dateAdded {
                let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            return .orderedSame
        case .dateAdded:
            if lhs.dateAdded == rhs.dateAdded { return .orderedSame }
            let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .dateModified:
            if lhs.dateModified == rhs.dateModified { return .orderedSame }
            let result: ComparisonResult = lhs.dateModified > rhs.dateModified ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .title:
            let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if cmp == .orderedSame { return .orderedSame }
            let result: ComparisonResult = cmp == .orderedAscending ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .year:
            let ly = lhs.year ?? 0, ry = rhs.year ?? 0
            if ly == ry { return .orderedSame }
            let result: ComparisonResult = ly > ry ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .citeKey:
            let cmp = lhs.citeKey.localizedCaseInsensitiveCompare(rhs.citeKey)
            if cmp == .orderedSame { return .orderedSame }
            let result: ComparisonResult = cmp == .orderedAscending ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .citationCount:
            if lhs.citationCount == rhs.citationCount { return .orderedSame }
            let result: ComparisonResult = lhs.citationCount > rhs.citationCount ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .starred:
            if lhs.isStarred != rhs.isStarred {
                let result: ComparisonResult = lhs.isStarred ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            if lhs.dateAdded == rhs.dateAdded { return .orderedSame }
            let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        }
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
        publications: [PublicationRowData],
        selection: Binding<Set<UUID>>,
        selectedPublicationID: Binding<UUID?>,
        libraryID: UUID? = nil,
        allLibraries: [(id: UUID, name: String)] = [],
        showImportButton: Bool = true,
        showSortMenu: Bool = true,
        emptyStateMessage: String = "No publications found.",
        emptyStateDescription: String = "Import a BibTeX file or search online sources to add publications.",
        listID: ListViewID? = nil,
        disableUnreadFilter: Bool = false,
        isInInbox: Bool = false,
        saveLibraryID: UUID? = nil,
        filterScope: Binding<FilterScope>,
        libraryNameMapping: [UUID: String] = [:],
        sortOrder: Binding<LibrarySortOrder> = .constant(.dateAdded),
        sortAscending: Binding<Bool> = .constant(false),
        recommendationScores: Binding<[UUID: Double]> = .constant([:]),
        onDelete: ((Set<UUID>) async -> Void)? = nil,
        onToggleRead: ((UUID) async -> Void)? = nil,
        onCopy: ((Set<UUID>) async -> Void)? = nil,
        onCut: ((Set<UUID>) async -> Void)? = nil,
        onPaste: (() async -> Void)? = nil,
        onAddToLibrary: ((Set<UUID>, UUID) async -> Void)? = nil,
        onAddToCollection: ((Set<UUID>, UUID) async -> Void)? = nil,
        onRemoveFromAllCollections: ((Set<UUID>) async -> Void)? = nil,
        onImport: (() -> Void)? = nil,
        onOpenPDF: ((UUID) -> Void)? = nil,
        onFileDrop: ((UUID, [NSItemProvider]) -> Void)? = nil,
        onListDrop: (([NSItemProvider], DropTarget) -> Void)? = nil,
        onDownloadPDFs: ((Set<UUID>) -> Void)? = nil,
        // Inbox triage callbacks
        onSaveToLibrary: ((Set<UUID>, UUID) async -> Void)? = nil,
        onDismiss: ((Set<UUID>) async -> Void)? = nil,
        onToggleStar: ((Set<UUID>) async -> Void)? = nil,
        onSetFlag: ((Set<UUID>, FlagColor) async -> Void)? = nil,
        onClearFlag: ((Set<UUID>) async -> Void)? = nil,
        onAddTag: ((Set<UUID>) -> Void)? = nil,
        onRemoveTag: ((UUID, UUID) -> Void)? = nil,
        onMuteAuthor: ((String) -> Void)? = nil,
        onMutePaper: ((UUID) -> Void)? = nil,
        // Category tap callback
        onCategoryTap: ((String) -> Void)? = nil,
        // Global search callback
        onGlobalSearch: (() -> Void)? = nil,
        // Refresh callback and state
        onRefresh: (() async -> Void)? = nil,
        isRefreshing: Bool = false,
        // External flash trigger
        externalTriageFlash: Binding<(id: UUID, color: Color)?> = .constant(nil),
        // Enhanced context menu callbacks
        onOpenInBrowser: ((UUID, BrowserDestination) -> Void)? = nil,
        onDownloadPDF: ((UUID) -> Void)? = nil,
        onViewEditBibTeX: ((UUID) -> Void)? = nil,
        onShare: ((UUID) -> Void)? = nil,
        onShareByEmail: ((UUID) -> Void)? = nil,
        onExploreReferences: ((UUID) -> Void)? = nil,
        onExploreCitations: ((UUID) -> Void)? = nil,
        onExploreSimilar: ((UUID) -> Void)? = nil
    ) {
        self.publications = publications
        self._selection = selection
        self._selectedPublicationID = selectedPublicationID
        self.libraryID = libraryID
        self.allLibraries = allLibraries
        self.showImportButton = showImportButton
        self.showSortMenu = showSortMenu
        self.emptyStateMessage = emptyStateMessage
        self.emptyStateDescription = emptyStateDescription
        self.listID = listID
        self.disableUnreadFilter = disableUnreadFilter
        self.isInInbox = isInInbox
        self.saveLibraryID = saveLibraryID
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
        self.onSetFlag = onSetFlag
        self.onClearFlag = onClearFlag
        self.onAddTag = onAddTag
        self.onRemoveTag = onRemoveTag
        self.onMuteAuthor = onMuteAuthor
        self.onMutePaper = onMutePaper
        // Category tap
        self.onCategoryTap = onCategoryTap
        // Global search
        self.onGlobalSearch = onGlobalSearch
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

    // MARK: - Change Detection

    /// Content-aware fingerprint for the publications array.
    /// Hashes full PublicationRowData (which conforms to Hashable), detecting both
    /// structural changes (add/remove/reorder) AND in-place mutations (read/flag/tag).
    private var publicationsFingerprint: Int {
        var hasher = Hasher()
        for pub in publications { hasher.combine(pub) }
        return hasher.finalize()
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // Inline toolbar (stays at top on iOS)
            inlineToolbar
            Divider()
            #endif

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
        #if os(macOS)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Refresh button
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
                        }
                        .help("Refresh")
                    }
                }

                // Import button
                if showImportButton, let onImport = onImport {
                    Button {
                        onImport()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Import BibTeX")
                }

                // Global search button (opens Cmd+F modal)
                Button {
                    onGlobalSearch?()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search (\u{2318}F)")

                // Sort menu
                if showSortMenu {
                    Menu {
                        ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                            Button {
                                if sortOrder == order {
                                    sortAscending.toggle()
                                } else {
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
                    .help("Change sort order")
                }

                // Count display
                countDisplay
            }
        }
        #endif
        .task(id: listID) {
            await loadState()
            listViewSettings = await ListViewSettingsStore.shared.settings
        }
        .onAppear {
            rebuildRowData()
        }
        .onChange(of: publicationsFingerprint) { _, _ in
            // Rebuild row data when publications change (add/delete/source switch)
            rebuildRowData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readStatusDidChange)) { notification in
            // Smart update: only rebuild changed rows (O(k) instead of O(n))
            if let ids = notification.userInfo?["publicationIDs"] as? [UUID] {
                for id in ids { updateSingleRowData(for: id) }
            } else if let changedID = notification.object as? UUID {
                updateSingleRowData(for: changedID)
            } else {
                rebuildRowData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .flagDidChange)) { notification in
            // Rebuild changed rows to pick up new flag state (O(k))
            if let ids = notification.userInfo?["publicationIDs"] as? [UUID] {
                for id in ids { updateSingleRowData(for: id) }
            } else if let changedID = notification.object as? UUID {
                updateSingleRowData(for: changedID)
            } else {
                rebuildRowData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .starDidChange)) { notification in
            // Rebuild changed rows to pick up new star state (O(k))
            if let ids = notification.userInfo?["publicationIDs"] as? [UUID] {
                for id in ids { updateSingleRowData(for: id) }
            } else {
                rebuildRowData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tagDidChange)) { notification in
            // Rebuild changed rows to pick up new tag state (O(k))
            if let ids = notification.userInfo?["publicationIDs"] as? [UUID] {
                for id in ids { updateSingleRowData(for: id) }
            } else {
                rebuildRowData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fieldDidChange)) { notification in
            // Rebuild changed rows to pick up new field values (O(k))
            if let ids = notification.userInfo?["publicationIDs"] as? [UUID] {
                for id in ids { updateSingleRowData(for: id) }
            } else {
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
            // Update drag selection holder for multi-selection drag
            dragSelectionHolder.selectedIDs = newValue

            // Update selection synchronously - the detail view defers its own update
            if let firstID = newValue.first,
               rowDataCache[firstID] != nil {
                // Update the UUID-based selection binding
                selectedPublicationID = firstID

                // Scroll to selection when it changes (e.g., from global search navigation)
                // First check if the item would be filtered out - if so, clear filters
                let isInFilteredList = filteredRowData.contains { $0.id == firstID }

                if !isInFilteredList && rowDataCache[firstID] != nil {
                    // Item exists but is filtered out - clear filters to make it visible
                    // This handles navigation from global search to a read paper when unread filter is on
                    if showUnreadOnly {
                        showUnreadOnly = false
                    }
                    // Invalidate cache since we changed filters
                    filterCache.invalidate()
                }

                // Mark that we need to scroll to this ID - the actual scroll will happen
                // via scrollToSelectionWithRetry which handles timing issues
                pendingScrollTarget = firstID
            } else if newValue.isEmpty {
                // Only clear selection when user explicitly deselects (empty selection)
                selectedPublicationID = nil
            }

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

        // Recommendation scoring should be computed by the parent view.
        // With pre-shaped data, recommendation scores should be computed by the parent
        // and passed in via the recommendationScores binding.
        isComputingRecommendations = false
    }

    // MARK: - Row Data Management

    /// Rebuild row data cache from current publications.
    /// Data arrives pre-shaped as [PublicationRowData] — no Core Data conversion needed.
    /// - rowDataCache: [UUID: PublicationRowData] for display and O(1) lookup
    private func rebuildRowData() {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.performance.info("⏱ rebuildRowData: \(elapsed, format: .fixed(precision: 1))ms (\(publications.count) items)")
        }

        var newRowCache: [UUID: PublicationRowData] = [:]

        for data in publications {
            // Use library name from mapping if available (for grouped search display),
            // otherwise keep the libraryName already set on the row data
            if let mappedName = libraryNameMapping[data.id], data.libraryName != mappedName {
                // Create a copy with updated library name
                // PublicationRowData is a value type so we'd need a new init or just store the original
                // For now, store as-is — the mapping is applied at the parent level
                newRowCache[data.id] = data
            } else {
                newRowCache[data.id] = data
            }
        }

        rowDataCache = newRowCache

        // Log tag summary for debugging
        let taggedCount = newRowCache.values.filter { !$0.tagDisplays.isEmpty }.count
        let flaggedCount = newRowCache.values.filter { $0.flag != nil }.count
        if taggedCount > 0 || flaggedCount > 0 {
            Logger.library.infoCapture(
                "rebuildRowData: \(newRowCache.count) rows, \(taggedCount) tagged, \(flaggedCount) flagged",
                category: "tags"
            )
        }

        // Invalidate filtered data cache - it will be recomputed on next access
        filterCache.invalidate()

        // After rebuilding, check if we need to scroll to selection (for global search navigation)
        // This handles the case where selection was set before the row data was available
        if let firstID = selection.first, newRowCache[firstID] != nil {
            // Check if item would be filtered out and clear filters if needed
            let wouldBeFiltered = showUnreadOnly && !disableUnreadFilter && (newRowCache[firstID]?.isRead ?? false)

            if wouldBeFiltered {
                showUnreadOnly = false
            }

            // Set pending scroll target - the retry mechanism will handle the actual scroll
            pendingScrollTarget = firstID
        }
    }

    /// Update a single row in the cache (O(1) instead of full rebuild).
    /// Used when only one publication's read/flag status changed.
    /// Fetches fresh data from the Rust store to pick up the mutation.
    private func updateSingleRowData(for publicationID: UUID) {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            Logger.performance.info("⏱ updateSingleRowData: \(elapsed, format: .fixed(precision: 2))ms")
        }

        // Fetch fresh data from the store (not the stale publications input array)
        guard let updatedData = RustStoreAdapter.shared.getPublication(id: publicationID) else {
            return
        }

        // Skip if data is already current (e.g., full rebuild just ran)
        if rowDataCache[publicationID] == updatedData { return }

        rowDataCache[publicationID] = updatedData

        // Try in-place update of the cached sorted array (avoids full re-sort).
        // Only need a full invalidation if the change affects filter membership
        // (e.g., read status changed while unread filter is active).
        let needsFullInvalidation = showUnreadOnly && !disableUnreadFilter
        if needsFullInvalidation {
            filterCache.invalidate()
        } else {
            filterCache.updateRow(publicationID, with: updatedData)
        }
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
            // Restore selection if publication still exists in row data cache
            if let selectedID = state.selectedPublicationID,
               rowDataCache[selectedID] != nil {
                selection = [selectedID]
                // Also update selectedPublicationID directly for macOS detail column
                selectedPublicationID = selectedID
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

            // Global search button (opens Cmd+F modal)
            Button {
                onGlobalSearch?()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Search")

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
        let isFiltered = showUnreadOnly

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
                // Double-click to open PDF
                if let first = ids.first,
                   let onOpenPDF = onOpenPDF {
                    onOpenPDF(first)
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
        #if os(iOS)
            // Pull-to-refresh on iOS - must be on the List directly for visual feedback
            .refreshable {
                if let onRefresh = onRefresh {
                    await onRefresh()
                }
            }
        #endif
        #if os(macOS)
        .onDeleteCommand {
            if let onDelete = onDelete {
                let idsToDelete = selection
                // Clear selection immediately before deletion to prevent accessing deleted objects
                selection.removeAll()
                selectedPublicationID = nil
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
              rowDataCache[firstID] != nil,
              let onOpenPDF = onOpenPDF else { return }

        onOpenPDF(firstID)
    }

    /// Mark all visible papers as read
    private func markAllAsRead() {
        guard let onToggleRead = onToggleRead else { return }

        for rowData in filteredRowData {
            if !rowData.isRead {
                Task {
                    await onToggleRead(rowData.id)
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
        selectedPublicationID = nil
        Task { await onDelete(idsToDelete) }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for ids: Set<UUID>) -> some View {
        // Open PDF
        if let onOpenPDF = onOpenPDF {
            Button("Open PDF") {
                if let first = ids.first {
                    onOpenPDF(first)
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

        // Send to E-Ink Device
        if let onSendToEInkDevice = onSendToEInkDevice {
            Button {
                onSendToEInkDevice(ids)
            } label: {
                Label("Send to E-Ink Device", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
            }
        }

        Divider()

        // Add to Library submenu (publications can belong to multiple libraries)
        if let onAddToLibrary = onAddToLibrary, !allLibraries.isEmpty {
            let otherLibraries = allLibraries.filter { $0.id != libraryID }
            if !otherLibraries.isEmpty {
                Menu("Add to Library") {
                    ForEach(otherLibraries, id: \.id) { targetLibrary in
                        Button(targetLibrary.name) {
                            Task {
                                await onAddToLibrary(ids, targetLibrary.id)
                            }
                        }
                    }
                }
            }
        }

        // Remove from all collections
        if let onRemoveFromAllCollections = onRemoveFromAllCollections {
            Button("Remove from All Collections") {
                Task {
                    await onRemoveFromAllCollections(ids)
                }
            }
        }

        // MARK: Move/Triage Actions

        // Move to Library (adds to target library AND removes from current library)
        // Available for all views, not just Inbox
        if let onSaveToLibrary = onSaveToLibrary, !allLibraries.isEmpty {
            // Filter out current library only (same logic as Add to Library)
            let moveLibraries = allLibraries.filter { $0.id != libraryID }
            if !moveLibraries.isEmpty {
                Menu("Move to Library") {
                    ForEach(moveLibraries, id: \.id) { targetLibrary in
                        Button(targetLibrary.name) {
                            Task {
                                await onSaveToLibrary(ids, targetLibrary.id)
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
                // Get first author from row data
                if let first = ids.first,
                   let rowData = rowDataCache[first] {
                    let firstName = rowData.authorString.split(separator: ",").first.map(String.init) ?? rowData.authorString
                    Button("Mute Author: \(firstName)") {
                        onMuteAuthor(firstName)
                    }
                }
            }

            if let onMutePaper = onMutePaper {
                if let first = ids.first {
                    Button("Mute This Paper") {
                        onMutePaper(first)
                    }
                }
            }
        }

        // Suggest to... functionality requires managed object access
        // and is now handled by the parent view via callbacks

        Divider()

        // Delete
        if let onDelete = onDelete {
            Button("Delete", role: .destructive) {
                // Clear selection immediately before deletion
                selection.removeAll()
                selectedPublicationID = nil
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
            .background(
                // macOS SwiftUI List draws the system accent color (blue) for selection
                // at the NSTableRowView level. There's no API to customize it.
                // This opaque background draws ABOVE it, replacing blue with a neutral
                // gray. Negative padding extends coverage to the full row bounds.
                ZStack {
                    theme.contentBackground
                    if selection.contains(rowData.id) {
                        theme.selectedRowBackground
                    }
                }
                .padding(.horizontal, -20)
                .padding(.vertical, -10)
            )
            .listRowBackground(Color.clear)
        #endif
    }

    @ViewBuilder
    private func rowContent(data rowData: PublicationRowData, index: Int) -> some View {
        let deleteHandler: (() -> Void)? = onDelete != nil ? {
            Task { await onDelete?([rowData.id]) }
        } : nil

        let saveHandler: (() -> Void)? = {
            guard onSaveToLibrary != nil else { return nil }
            // Use the configured keep library if provided, otherwise fall back to first library
            let targetLibraryID: UUID? = saveLibraryID ?? allLibraries.first?.id
            guard let libID = targetLibraryID else { return nil }
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
                    await onSaveToLibrary?([rowData.id], libID)
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
            Task { await onToggleRead?(rowData.id) }
        } : nil

        let openPDFHandler: (() -> Void)? = (onOpenPDF != nil && rowData.hasPDFAvailable) ? {
            onOpenPDF?(rowData.id)
        } : nil

        let copyBibTeXHandler: (() -> Void)? = onCopy != nil ? {
            Task { await onCopy?([rowData.id]) }
        } : nil

        // addToCollection now uses UUID — MailStylePublicationRow still expects CollectionModel
        // Pass nil since we no longer have CollectionModel objects at this level
        let addToCollectionHandler: ((CollectionModel) -> Void)? = nil

        let muteAuthorHandler: (() -> Void)? = onMuteAuthor != nil ? {
            let firstName = rowData.authorString.split(separator: ",").first.map(String.init) ?? rowData.authorString
            onMuteAuthor?(firstName)
        } : nil

        let mutePaperHandler: (() -> Void)? = onMutePaper != nil ? {
            onMutePaper?(rowData.id)
        } : nil

        // Flag handlers
        let setFlagHandler: ((FlagColor) -> Void)? = onSetFlag != nil ? { color in
            Task { await onSetFlag?([rowData.id], color) }
        } : nil

        let clearFlagHandler: (() -> Void)? = onClearFlag != nil ? {
            Task { await onClearFlag?([rowData.id]) }
        } : nil

        // Tag handlers
        let addTagHandler: (() -> Void)? = onAddTag != nil ? {
            onAddTag?([rowData.id])
        } : nil

        let removeTagHandler: ((UUID) -> Void)? = onRemoveTag != nil ? { tagID in
            onRemoveTag?(rowData.id, tagID)
        } : nil

        // Enhanced context menu handlers — all use UUID now
        let openInBrowserHandler: ((BrowserDestination) -> Void)? = onOpenInBrowser != nil ? { destination in
            onOpenInBrowser?(rowData.id, destination)
        } : nil

        let downloadPDFHandler: (() -> Void)? = (onDownloadPDF != nil && !rowData.hasDownloadedPDF) ? {
            onDownloadPDF?(rowData.id)
        } : nil

        let viewEditBibTeXHandler: (() -> Void)? = onViewEditBibTeX != nil ? {
            onViewEditBibTeX?(rowData.id)
        } : nil

        let shareHandler: (() -> Void)? = onShare != nil ? {
            onShare?(rowData.id)
        } : nil

        let shareByEmailHandler: (() -> Void)? = onShareByEmail != nil ? {
            onShareByEmail?(rowData.id)
        } : nil

        let exploreReferencesHandler: (() -> Void)? = onExploreReferences != nil ? {
            onExploreReferences?(rowData.id)
        } : nil

        let exploreCitationsHandler: (() -> Void)? = onExploreCitations != nil ? {
            onExploreCitations?(rowData.id)
        } : nil

        let exploreSimilarHandler: (() -> Void)? = onExploreSimilar != nil ? {
            onExploreSimilar?(rowData.id)
        } : nil

        // addToLibrary now uses UUID — MailStylePublicationRow still expects LibraryModel
        // Pass nil since we no longer have LibraryModel objects at this level
        let addToLibraryHandler: ((LibraryModel) -> Void)? = nil

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
            onSetFlag: setFlagHandler,
            onClearFlag: clearFlagHandler,
            onAddTag: addTagHandler,
            onRemoveTag: removeTagHandler,
            isInInbox: isInInbox,
            onOpenPDF: openPDFHandler,
            onCopyCiteKey: { copyToClipboard(rowData.citeKey) },
            onCopyBibTeX: copyBibTeXHandler,
            onAddToCollection: addToCollectionHandler,
            onMuteAuthor: muteAuthorHandler,
            onMutePaper: mutePaperHandler,
            collections: [],  // Collection menus handled at parent level via UUID callbacks
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
            libraries: [],  // Library menus handled at parent level via UUID callbacks
            recommendationScore: scoreToShow,
            highlightedCitationCount: citationCountToShow,
            triageFlashColor: flashColor,
            dragSelectionHolder: dragSelectionHolder
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
              rowDataCache[publicationID] != nil else {
            return false
        }

        onFileDrop(publicationID, providers)
        return true
    }

    /// Handle PDF drop on list background for import
    private func handleListDrop(providers: [NSItemProvider]) -> Bool {
        guard let onListDrop = onListDrop else {
            return false
        }

        // Determine the drop target based on current library
        let target: DropTarget
        if let libID = libraryID {
            target = .library(libraryID: libID)
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
    let publications: [PublicationRowData] = [] // Empty preview

    return PublicationListView(
        publications: publications,
        selection: .constant([]),
        selectedPublicationID: .constant(nil),
        showImportButton: true,
        showSortMenu: true,
        filterScope: .constant(.current),
        onImport: { print("Import tapped") }
    )
}

nonisolated public extension ComparisonResult {
    var flipped: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
