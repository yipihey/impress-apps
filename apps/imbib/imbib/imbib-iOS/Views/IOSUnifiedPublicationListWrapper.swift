//
//  IOSUnifiedPublicationListWrapper.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-19.
//  Revived on 2026-07-20: ported off the deleted Core Data types
//  (CDLibrary/CDCollection/CDSmartSearch/CDSciXLibrary/CDPublication)
//  to the value-type + RustStoreAdapter world. The `Source` enum now
//  carries only ids/value types so IOSContentView compiles unchanged
//  (it already used the id-based shape from the stub this file replaces).
//

import SwiftUI
import PublicationManagerCore
import ImpressFTUI  // FlagColor
import ImpressLogging  // Logger.infoCapture
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "ios-list")

/// Unified iOS wrapper for displaying publications from any source.
///
/// This view consolidates the duplicated logic from:
/// - IOSLibraryListView
/// - IOSSmartSearchResultsView
/// - IOSCollectionListView
/// - IOSSciXLibraryListView
///
/// It uses the shared `PublicationListView` with proper callbacks wired up,
/// and leverages `RustStoreAdapter` for data access and triage operations.
struct IOSUnifiedPublicationListWrapper: View {

    // MARK: - Source Type

    /// The data source for the publication list.
    ///
    /// All cases carry only value types (ids / strings) so the view is
    /// fully decoupled from the underlying store handle. Store lookups
    /// happen lazily in the `@MainActor` computed helpers below.
    enum Source: Hashable {
        case library(UUID, String, isInbox: Bool)
        /// Look up the library by id and display its publications.
        /// Kept for call sites that only have an id in hand.
        case libraryByID(UUID)
        case smartSearch(UUID)
        case collection(UUID)
        case scixLibrary(UUID)
        case flagged(String?)  // Flagged publications (nil = any flag, or specific color name)
        case citedInManuscripts
        /// Papers the user viewed or added by hand — never automated ingest.
        case recent

        var id: UUID {
            switch self {
            case .library(let id, _, _),
                 .libraryByID(let id),
                 .smartSearch(let id),
                 .collection(let id),
                 .scixLibrary(let id):
                return id
            case .flagged(let color):
                return IOSUnifiedPublicationListWrapper.flaggedID(for: color)
            case .citedInManuscripts:
                return UUID(uuidString: "00000000-0000-0000-AAAA-000000000004")!
            case .recent:
                return UUID(uuidString: "00000000-0000-0000-AAAA-000000000005")!
            }
        }

        @MainActor
        var isInbox: Bool {
            switch self {
            case .library(_, _, let isInbox):
                return isInbox
            case .libraryByID(let id):
                return RustStoreAdapter.shared.getLibrary(id: id)?.isInbox ?? false
            case .smartSearch(let id):
                return RustStoreAdapter.shared.getSmartSearch(id: id)?.feedsToInbox ?? false
            case .collection, .scixLibrary, .flagged, .citedInManuscripts, .recent:
                return false
            }
        }

        @MainActor
        var navigationTitle: String {
            switch self {
            case .library(_, let name, _):
                return name
            case .libraryByID(let id):
                return RustStoreAdapter.shared.getLibrary(id: id)?.name ?? "Library"
            case .smartSearch(let id):
                return RustStoreAdapter.shared.getSmartSearch(id: id)?.name ?? "Search"
            case .collection(let id):
                let name = RustStoreAdapter.shared.listLibraries()
                    .flatMap { RustStoreAdapter.shared.listCollections(libraryId: $0.id) }
                    .first(where: { $0.id == id })?.name
                return name ?? "Collection"
            case .scixLibrary(let id):
                return RustStoreAdapter.shared.getScixLibrary(id: id)?.name ?? "SciX Library"
            case .flagged(let color):
                if let color { return "\(color.capitalized) Flagged" }
                return "Flagged"
            case .citedInManuscripts:
                return "Cited in Manuscripts"
            case .recent:
                return "Recent"
            }
        }

        @MainActor
        var emptyStateMessage: String {
            switch self {
            case .library, .libraryByID:
                return isInbox ? "Inbox Empty" : "No Publications"
            case .smartSearch(let id):
                let query = RustStoreAdapter.shared.getSmartSearch(id: id)?.query ?? ""
                return query.isEmpty ? "No Results" : "No Results for \"\(query)\""
            case .collection:
                return "No Publications"
            case .scixLibrary:
                return "No Papers"
            case .flagged(let color):
                if let color { return "No \(color.capitalized) Flagged Papers" }
                return "No Flagged Papers"
            case .citedInManuscripts:
                return "No Cited Papers"
            case .recent:
                return "Nothing Recent"
            }
        }

        @MainActor
        var emptyStateDescription: String {
            switch self {
            case .library, .libraryByID:
                return isInbox
                    ? "Add feeds to start discovering papers."
                    : "Import BibTeX files or search online to add papers."
            case .smartSearch:
                return "Pull down to refresh or edit the search criteria."
            case .collection:
                return "Add publications to this collection."
            case .scixLibrary:
                return "This SciX library is empty or hasn't been synced yet."
            case .flagged:
                return "Flag papers to see them here."
            case .citedInManuscripts:
                return "Cite a paper in imprint to see it here."
            case .recent:
                return "Papers you open or add by hand show up here."
            }
        }

        var listID: ListViewID {
            switch self {
            case .library(let id, _, _), .libraryByID(let id):
                return .library(id)
            case .smartSearch(let id):
                return .smartSearch(id)
            case .collection(let id):
                return .collection(id)
            case .scixLibrary(let id):
                return .scixLibrary(id)
            case .flagged:
                return .flagged(id)
            case .citedInManuscripts, .recent:
                return .library(id)
            }
        }

        /// The owning library UUID (for PDF paths, context operations, etc.)
        @MainActor
        var owningLibraryID: UUID? {
            switch self {
            case .library(let id, _, _), .libraryByID(let id):
                return id
            case .smartSearch(let id):
                return RustStoreAdapter.shared.getSmartSearch(id: id)?.libraryID
            case .collection(let id):
                // Find the library that owns this collection.
                let store = RustStoreAdapter.shared
                for lib in store.listLibraries() {
                    if store.listCollections(libraryId: lib.id).contains(where: { $0.id == id }) {
                        return lib.id
                    }
                }
                return nil
            case .scixLibrary:
                return nil // SciX libraries are remote
            case .flagged, .citedInManuscripts, .recent:
                return nil // Cross-library virtual source
            }
        }

        /// Convert to PublicationSource for RustStoreAdapter queries
        @MainActor
        var publicationSource: PublicationSource {
            switch self {
            case .library(let id, _, let isInbox):
                return isInbox ? .inbox(id) : .library(id)
            case .libraryByID(let id):
                if let lib = RustStoreAdapter.shared.getLibrary(id: id), lib.isInbox {
                    return .inbox(id)
                }
                return .library(id)
            case .smartSearch(let id): return .smartSearch(id)
            case .collection(let id): return .collection(id)
            case .scixLibrary(let id): return .scixLibrary(id)
            case .flagged(let color): return .flagged(color)
            case .citedInManuscripts: return .citedInManuscripts
            case .recent: return .recent
            }
        }
    }

    /// Deterministic id for `.flagged` rows — matches the macOS wrapper's
    /// mapping so saved selection state survives platform transitions.
    fileprivate static func flaggedID(for color: String?) -> UUID {
        switch color {
        case "red":    return UUID(uuidString: "F1A99ED0-0001-4000-8000-000000000000")!
        case "amber":  return UUID(uuidString: "F1A99ED0-0002-4000-8000-000000000000")!
        case "blue":   return UUID(uuidString: "F1A99ED0-0003-4000-8000-000000000000")!
        case "gray":   return UUID(uuidString: "F1A99ED0-0004-4000-8000-000000000000")!
        default:       return UUID(uuidString: "F1A99ED0-0000-4000-8000-000000000000")!
        }
    }

    // MARK: - Properties

    let source: Source
    @Binding var selectedPublicationID: UUID?

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel

    // MARK: - State

    @State private var publications: [PublicationRowData] = []
    @State private var multiSelection = Set<UUID>()
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var filterScope: FilterScope = .current

    /// Current sort order - owned by wrapper for synchronous visual order computation.
    @State private var currentSortOrder: LibrarySortOrder = .dateAdded
    @State private var currentSortAscending: Bool = false

    /// ADR-020: Recommendation scores for sorted display.
    /// Owned by wrapper to ensure synchronous access during triage.
    @State private var recommendationScores: [UUID: Double] = [:]

    // Sheet state
    @State private var showBibTeXEditor = false
    @State private var publicationForBibTeXSheet: UUID?

    // Selection mode (for multi-selection like Mail app)
    @State private var isSelectionMode = false

    // Library picker for bulk add
    @State private var showLibraryPicker = false

    // MARK: - Body

    var body: some View {
        publicationListContent
            .navigationTitle(source.navigationTitle)
            .toolbar { toolbarContent }
            .environment(\.editMode, isSelectionMode ? .constant(.active) : .constant(.inactive))
            .sheet(isPresented: $showBibTeXEditor) {
                if let pubID = publicationForBibTeXSheet {
                    IOSBibTeXEditorSheet(publicationID: pubID)
                }
            }
            .sheet(isPresented: $showLibraryPicker) {
                LibraryPickerSheet(
                    isPresented: $showLibraryPicker,
                    libraries: libraryManager.libraries.filter { !$0.isInbox },
                    onSelect: { library in
                        let ids = multiSelection
                        Task {
                            await handleAddToLibrary(ids, library.id)
                            exitSelectionMode()
                        }
                    }
                )
            }
            .task(id: source.id) {
                await loadPublications()
            }
            .task {
                // Keep the VISIBLE list in sync with async ingest (feed and
                // inbox refresh, share-in, enrichment, batch import). This
                // mirrors the macOS UnifiedPublicationListWrapper's store
                // subscription — without it, the iOS list loaded once per
                // source and never reflected background mutations, so "the
                // screen one is on" never updated until re-navigating.
                for await event in ImbibImpressStore.shared.events.subscribe() {
                    switch event {
                    case .structural, .collectionMembershipChanged:
                        refreshPublicationsList()
                    case .itemsMutated(_, let ids):
                        // Only re-query when a visible row actually changed.
                        let visible = Set(publications.map(\.id))
                        if !visible.isDisjoint(with: ids) {
                            refreshPublicationsList()
                        }
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            // Disable swipe-back gesture when inbox has swipe actions
            // to prevent conflict with "keep" swipe right gesture
            .modifier(ConditionalDisableSwipeBackModifier(isEnabled: source.isInbox))
    }

    /// Exit selection mode and clear selections
    private func exitSelectionMode() {
        isSelectionMode = false
        multiSelection.removeAll()
    }

    /// Separated to help Swift type checker
    @ViewBuilder
    private var publicationListContent: some View {
        PublicationListView(
            publications: publications,
            selection: $multiSelection,
            selectedPublicationID: $selectedPublicationID,
            libraryID: source.owningLibraryID,
            allLibraries: libraryManager.libraries.map { (id: $0.id, name: $0.name) },
            showImportButton: shouldShowImportButton,
            showSortMenu: true,
            emptyStateMessage: source.emptyStateMessage,
            emptyStateDescription: source.emptyStateDescription,
            listID: source.listID,
            disableUnreadFilter: source.isInbox,
            isInInbox: source.isInbox,
            saveLibraryID: source.isInbox ? libraryManager.getOrCreateSaveLibrary().id : nil,
            filterScope: $filterScope,
            sortOrder: $currentSortOrder,
            sortAscending: $currentSortAscending,
            recommendationScores: $recommendationScores,
            actions: {
                let a = PublicationListActions()
                a.onDelete = { ids in await handleDelete(ids) }
                a.onToggleRead = { pubID in await handleToggleRead(pubID) }
                a.onCopy = { ids in await handleCopy(ids) }
                a.onCut = { ids in await handleCut(ids) }
                a.onPaste = { await handlePaste() }
                a.onAddToLibrary = { ids, libraryID in await handleAddToLibrary(ids, libraryID) }
                a.onAddToCollection = { ids, collectionID in await handleAddToCollection(ids, collectionID) }
                a.onRemoveFromAllCollections = { ids in await handleRemoveFromAllCollections(ids) }
                a.onImport = shouldShowImportButton ? { handleImport() } : nil
                a.onOpenPDF = { pubID in handleOpenPDF(pubID) }
                a.onSaveToLibrary = source.isInbox ? { ids, targetLibraryID in await handleSaveToLibrary(ids, targetLibraryID) } : nil
                a.onDismiss = { ids in await handleDismiss(ids) }
                a.onSetFlag = { ids, color in await handleSetFlag(ids, color) }
                a.onClearFlag = { ids in await handleClearFlag(ids) }
                a.onRemoveTag = { pubID, tagID in handleRemoveTag(pubID: pubID, tagID: tagID) }
                a.onCategoryTap = { cat in handleCategoryTap(cat) }
                a.onRefresh = { await refreshFromSource() }
                a.onOpenInBrowser = { pubID, dest in handleOpenInBrowser(pubID, dest) }
                a.onDownloadPDF = { pubID in handleDownloadPDF(pubID) }
                a.onViewEditBibTeX = { pubID in handleViewEditBibTeX(pubID) }
                a.onShare = { pubID in handleShare(pubID) }
                a.onExploreReferences = { pubID in handleExploreReferences(pubID) }
                a.onExploreCitations = { pubID in handleExploreCitations(pubID) }
                a.onExploreSimilar = { pubID in handleExploreSimilar(pubID) }
                return a
            }()
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Select/Done button (always visible when there are publications)
        if !publications.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelectionMode ? "Done" : "Select") {
                    withAnimation {
                        if isSelectionMode {
                            exitSelectionMode()
                        } else {
                            isSelectionMode = true
                        }
                    }
                }
            }
        }

        // Refresh button for smart searches
        if case .smartSearch = source, !isSelectionMode {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshFromSource() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }

        // Sync status for SciX libraries
        if case .scixLibrary(let libID) = source, !isSelectionMode {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if let lib = RustStoreAdapter.shared.getScixLibrary(id: libID) {
                        syncStatusIcon(for: lib)
                    }

                    Button {
                        Task { await refreshFromSource() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                }
            }
        }

        // Bottom bar actions when items are selected
        if isSelectionMode && !multiSelection.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    showLibraryPicker = true
                } label: {
                    Label("Add to Library", systemImage: "folder.badge.plus")
                }

                Spacer()

                Text("\(multiSelection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    let ids = multiSelection
                    Task {
                        await handleDelete(ids)
                        exitSelectionMode()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func syncStatusIcon(for library: SciXLibrary) -> some View {
        switch library.syncState.lowercased() {
        case "synced":
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case "error", "failed":
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        default: // pending / syncing / idle
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Computed Properties

    private var shouldShowImportButton: Bool {
        switch source {
        case .library, .libraryByID:
            return !source.isInbox
        case .smartSearch, .collection, .scixLibrary, .flagged, .citedInManuscripts, .recent:
            return false
        }
    }

    // MARK: - Visual Order Computation

    /// Compute the visual order of publications synchronously.
    ///
    /// This is the single source of truth for list order during triage operations.
    /// Called synchronously before triage to ensure selection advancement uses the correct order.
    ///
    /// - Returns: Publications sorted according to current sort order and filters
    private func computeVisualOrder() -> [PublicationRowData] {
        // Apply current sort order with stable tie-breaker (dateAdded then id)
        let sorted = publications.sorted { lhs, rhs in
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
                lhs.dateAdded > rhs.dateAdded
            case .dateModified:
                lhs.dateModified > rhs.dateModified
            case .title:
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .year:
                (lhs.year ?? 0) > (rhs.year ?? 0)
            case .citeKey:
                lhs.citeKey.localizedCaseInsensitiveCompare(rhs.citeKey) == .orderedAscending
            case .citationCount:
                lhs.citationCount > rhs.citationCount
            case .starred:
                lhs.isStarred && !rhs.isStarred  // Starred papers first
            case .recentActivity:
                // nil stamp = never touched = distant past, matching the
                // shared comparator in PublicationListView so this local
                // re-sort never fights the server-side ORDER BY.
                (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
            case .recommended:
                true  // Handled above, this won't be reached
            }
            return currentSortAscending == currentSortOrder.defaultAscending ? defaultComparison : !defaultComparison
        }

        return sorted
    }

    /// Compute the next selection ID after removing the given IDs from the visual order.
    private func computeNextSelection(removing ids: Set<UUID>, from visualOrder: [PublicationRowData]) -> UUID? {
        // Find the current position of the first selected item
        guard let firstSelectedID = ids.first,
              let currentIndex = visualOrder.firstIndex(where: { $0.id == firstSelectedID }) else {
            return nil
        }

        // Find the next item that isn't being removed
        for i in (currentIndex + 1)..<visualOrder.count {
            if !ids.contains(visualOrder[i].id) {
                return visualOrder[i].id
            }
        }

        // If no next item, try previous
        for i in (0..<currentIndex).reversed() {
            if !ids.contains(visualOrder[i].id) {
                return visualOrder[i].id
            }
        }

        return nil
    }

    // MARK: - Data Loading

    /// Load publications from RustStoreAdapter.
    private func loadPublications() async {
        let store = RustStoreAdapter.shared
        publications = store.queryPublications(for: source.publicationSource)
        logger.info("Loaded \(self.publications.count) publications for \(source.navigationTitle)")
    }

    /// Refresh publication list from RustStoreAdapter (synchronous read)
    private func refreshPublicationsList() {
        let store = RustStoreAdapter.shared
        publications = store.queryPublications(for: source.publicationSource)
    }

    // MARK: - Refresh

    private func refreshFromSource() async {
        isRefreshing = true
        defer { isRefreshing = false }

        switch source {
        case .library, .libraryByID, .collection, .flagged, .citedInManuscripts, .recent:
            refreshPublicationsList()

        case .smartSearch(let id):
            await refreshSmartSearch(id)

        case .scixLibrary(let id):
            await refreshSciXLibrary(id)
        }
    }

    private func refreshSmartSearch(_ smartSearchID: UUID) async {
        guard let smartSearch = RustStoreAdapter.shared.getSmartSearch(id: smartSearchID) else {
            refreshPublicationsList()
            return
        }

        // Route group feeds to GroupFeedRefreshService
        if smartSearch.isGroupFeed {
            do {
                _ = try await GroupFeedRefreshService.shared.refreshGroupFeedByID(smartSearchID)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Group feed error: \(error.localizedDescription)")
            }
        } else if let provider = await SmartSearchProviderCache.shared.getOrCreateByID(
            smartSearchID: smartSearchID,
            sourceManager: searchViewModel.sourceManager
        ) {
            do {
                try await provider.refresh()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Smart search error: \(error.localizedDescription)")
            }
        }

        // Reload publications from Rust store after refresh
        refreshPublicationsList()
    }

    private func refreshSciXLibrary(_ scixLibraryID: UUID) async {
        guard let library = RustStoreAdapter.shared.getScixLibrary(id: scixLibraryID) else {
            refreshPublicationsList()
            return
        }
        do {
            try await SciXSyncManager.shared.pullLibraryPapers(libraryID: library.remoteID)
            refreshPublicationsList()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Handlers

    private func handleDelete(_ ids: Set<UUID>) async {
        publications.removeAll { ids.contains($0.id) }
        multiSelection.subtract(ids)
        RustStoreAdapter.shared.deletePublications(ids: Array(ids))
        refreshPublicationsList()
    }

    private func handleToggleRead(_ pubID: UUID) async {
        let store = RustStoreAdapter.shared
        let pub = store.getPublication(id: pubID)
        store.setRead(ids: [pubID], read: !(pub?.isRead ?? false))
        refreshPublicationsList()
    }

    private func handleCopy(_ ids: Set<UUID>) async {
        await libraryViewModel.copyToClipboard(ids)
    }

    private func handleCut(_ ids: Set<UUID>) async {
        await libraryViewModel.cutToClipboard(ids)
        refreshPublicationsList()
    }

    private func handlePaste() async {
        try? await libraryViewModel.pasteFromClipboard()
        refreshPublicationsList()
    }

    private func handleAddToLibrary(_ ids: Set<UUID>, _ targetLibraryID: UUID) async {
        // Multi-library membership via Contains edges — no duplicate item created.
        RustStoreAdapter.shared.libraryAddMembers(libraryId: targetLibraryID, publicationIds: Array(ids))
        refreshPublicationsList()
    }

    private func handleAddToCollection(_ ids: Set<UUID>, _ collectionID: UUID) async {
        RustStoreAdapter.shared.addToCollection(publicationIds: Array(ids), collectionId: collectionID)
    }

    private func handleRemoveFromAllCollections(_ ids: Set<UUID>) async {
        // Un-degraded: enumerate each publication's collections via the new
        // listCollections(forPublication:) query, then remove the membership edge
        // from every one. Publications themselves are untouched.
        let store = RustStoreAdapter.shared
        var totalRemovals = 0
        for pubID in ids {
            let colls = store.listCollections(forPublication: pubID)
            logger.infoCapture("removeFromAllCollections: pub \(pubID) is in \(colls.count) collection(s)", category: "collections")
            for coll in colls {
                store.removeFromCollection(publicationIds: [pubID], collectionId: coll.id)
                totalRemovals += 1
            }
        }
        logger.infoCapture("removeFromAllCollections: removed \(totalRemovals) membership edge(s) across \(ids.count) pub(s)", category: "collections")
        refreshPublicationsList()
        logger.infoCapture("removeFromAllCollections: list refreshed", category: "collections")
    }

    private func handleImport() {
        NotificationCenter.default.post(name: .importBibTeX, object: nil)
    }

    private func handleOpenPDF(_ pubID: UUID) {
        // On iOS, show in built-in PDF tab
        libraryViewModel.selectedPublications = [pubID]
        NotificationCenter.default.post(name: .showPDFTab, object: nil)
    }

    // MARK: - Inbox Triage Handlers

    private func handleSaveToLibrary(_ ids: Set<UUID>, _ targetLibraryID: UUID) async {
        // Compute visual order synchronously for correct selection advancement
        _ = computeVisualOrder()

        // Move publications to the target library via Rust store
        RustStoreAdapter.shared.movePublications(ids: Array(ids), toLibraryId: targetLibraryID)

        // On iOS, clear selection to stay in list view (no split view detail)
        multiSelection.removeAll()
        selectedPublicationID = nil

        refreshPublicationsList()
    }

    private func handleDismiss(_ ids: Set<UUID>) async {
        let dismissedLibrary = libraryManager.getOrCreateDismissedLibrary()

        // Move to dismissed library via Rust store
        RustStoreAdapter.shared.movePublications(ids: Array(ids), toLibraryId: dismissedLibrary.id)

        // On iOS, clear selection to stay in list view (no split view detail)
        multiSelection.removeAll()
        selectedPublicationID = nil

        refreshPublicationsList()
    }

    // MARK: - Flag Handlers

    private func handleSetFlag(_ ids: Set<UUID>, _ color: FlagColor) async {
        RustStoreAdapter.shared.setFlag(ids: Array(ids), color: color.rawValue)
        refreshPublicationsList()
    }

    private func handleClearFlag(_ ids: Set<UUID>) async {
        RustStoreAdapter.shared.setFlag(ids: Array(ids), color: nil)
        refreshPublicationsList()
    }

    /// Remove a tag from a publication.
    private func handleRemoveTag(pubID: UUID, tagID: UUID) {
        // Migration debt: the Rust store keys tag membership by tag PATH, but this
        // callback hands us a tag UUID and there is no tagID→path lookup in the store
        // (TagDefinition.id is the path string, not a UUID). No-op until the row model
        // surfaces the tag path or the store gains a UUID-keyed removal.
        logger.warning("removeTag is a no-op — no tagID(\(tagID))→path mapping in Rust store for pub \(pubID)")
        refreshPublicationsList()
    }

    // MARK: - Context Menu Handlers

    private func handleCategoryTap(_ category: String) {
        NotificationCenter.default.post(
            name: .searchCategory,
            object: nil,
            userInfo: ["category": category]
        )
    }

    private func handleOpenInBrowser(_ pubID: UUID, _ destination: BrowserDestination) {
        let store = RustStoreAdapter.shared
        guard let pub = store.getPublication(id: pubID) else { return }

        var urlString: String?

        switch destination {
        case .arxiv:
            if let arxivID = pub.arxivID {
                urlString = "https://arxiv.org/abs/\(arxivID)"
            }
        case .ads:
            if let bibcode = pub.bibcode {
                urlString = "https://ui.adsabs.harvard.edu/abs/\(bibcode)"
            }
        case .doi, .publisher:
            if let doi = pub.doi {
                urlString = doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)"
            }
        }

        if let urlString = urlString, let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    private func handleDownloadPDF(_ pubID: UUID) {
        let store = RustStoreAdapter.shared
        guard let pub = store.getPublication(id: pubID) else { return }

        // Capture value-type snapshots before entering the Task.
        let arxivID = pub.arxivID
        let citeKey = pub.citeKey
        let libraryID = source.owningLibraryID

        Task {
            do {
                // Construct remote PDF URL from arXiv ID or other identifiers
                var pdfURL: URL?
                if let arxivID {
                    pdfURL = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
                }

                if let pdfURL {
                    let (data, _) = try await URLSession.shared.data(from: pdfURL)
                    // Value-type store: import keyed by UUIDs (mirrors IOSPDFTab).
                    try AttachmentManager.shared.importAttachment(
                        data: data,
                        for: pubID,
                        in: libraryID,
                        fileExtension: "pdf",
                        displayName: "\(citeKey).pdf"
                    )
                    refreshPublicationsList()
                }
            } catch {
                logger.error("Failed to download PDF: \(error.localizedDescription)")
            }
        }
    }

    private func handleViewEditBibTeX(_ pubID: UUID) {
        publicationForBibTeXSheet = pubID
        showBibTeXEditor = true
    }

    private func handleShare(_ pubID: UUID) {
        let store = RustStoreAdapter.shared
        guard let pub = store.getPublication(id: pubID) else { return }

        var items: [Any] = []

        let title = pub.title
        items.append(title)

        if let doi = pub.doi {
            let doiURL = doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)"
            if let url = URL(string: doiURL) {
                items.append(url)
            }
        } else if let arxivID = pub.arxivID {
            if let url = URL(string: "https://arxiv.org/abs/\(arxivID)") {
                items.append(url)
            }
        }

        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = rootVC.view
                popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            rootVC.present(activityVC, animated: true)
        }
    }

    private func handleExploreReferences(_ pubID: UUID) {
        NotificationCenter.default.post(name: .exploreReferences, object: pubID)
    }

    private func handleExploreCitations(_ pubID: UUID) {
        NotificationCenter.default.post(name: .exploreCitations, object: pubID)
    }

    private func handleExploreSimilar(_ pubID: UUID) {
        NotificationCenter.default.post(name: .exploreSimilar, object: pubID)
    }
}

// MARK: - Library Picker Sheet

/// Sheet for selecting a library to add publications to
struct LibraryPickerSheet: View {
    @Binding var isPresented: Bool
    let libraries: [LibraryModel]
    let onSelect: (LibraryModel) -> Void

    var body: some View {
        NavigationStack {
            List(libraries) { library in
                Button {
                    onSelect(library)
                    isPresented = false
                } label: {
                    Label(library.name, systemImage: "folder")
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Add to Library")
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
        Text("Preview requires LibraryManager")
    }
}
