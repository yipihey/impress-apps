//
//  IOSUnifiedPublicationListWrapper.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI
import PublicationManagerCore
import CoreData
import OSLog
import ImpressFTUI

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
    enum Source: Hashable {
        case library(CDLibrary)
        case smartSearch(CDSmartSearch)
        case collection(CDCollection)
        case scixLibrary(CDSciXLibrary)
        case flagged(String?)  // Flagged publications (nil = any flag, or specific color name)

        var id: UUID {
            switch self {
            case .library(let lib): return lib.id
            case .smartSearch(let ss): return ss.id
            case .collection(let col): return col.id
            case .scixLibrary(let lib): return lib.id
            case .flagged(let color):
                switch color {
                case "red":   return UUID(uuidString: "F1A99ED0-0001-4000-8000-000000000000")!
                case "amber": return UUID(uuidString: "F1A99ED0-0002-4000-8000-000000000000")!
                case "blue":  return UUID(uuidString: "F1A99ED0-0003-4000-8000-000000000000")!
                case "gray":  return UUID(uuidString: "F1A99ED0-0004-4000-8000-000000000000")!
                default:      return UUID(uuidString: "F1A99ED0-0000-4000-8000-000000000000")!
                }
            }
        }

        var isInbox: Bool {
            switch self {
            case .library(let lib): return lib.isInbox
            case .smartSearch(let ss): return ss.feedsToInbox
            case .collection, .scixLibrary, .flagged: return false
            }
        }

        var navigationTitle: String {
            switch self {
            case .library(let lib): return lib.displayName
            case .smartSearch(let ss): return ss.name
            case .collection(let col): return col.name
            case .scixLibrary(let lib): return lib.displayName
            case .flagged(let color):
                if let color { return "\(color.capitalized) Flagged" }
                return "Flagged"
            }
        }

        var emptyStateMessage: String {
            switch self {
            case .library(let lib) where lib.isInbox:
                return "Inbox Empty"
            case .library:
                return "No Publications"
            case .smartSearch(let ss):
                return "No Results for \"\(ss.query)\""
            case .collection:
                return "No Publications"
            case .scixLibrary:
                return "No Papers"
            case .flagged(let color):
                if let color { return "No \(color.capitalized) Flagged Papers" }
                return "No Flagged Papers"
            }
        }

        var emptyStateDescription: String {
            switch self {
            case .library(let lib) where lib.isInbox:
                return "Add feeds to start discovering papers."
            case .library:
                return "Import BibTeX files or search online to add papers."
            case .smartSearch:
                return "Pull down to refresh or edit the search criteria."
            case .collection:
                return "Add publications to this collection."
            case .scixLibrary:
                return "This SciX library is empty or hasn't been synced yet."
            case .flagged:
                return "Flag papers to see them here."
            }
        }

        var listID: ListViewID {
            switch self {
            case .library(let lib): return .library(lib.id)
            case .smartSearch(let ss): return .smartSearch(ss.id)
            case .collection(let col): return .collection(col.id)
            case .scixLibrary(let lib): return .scixLibrary(lib.id)
            case .flagged: return .flagged(id)
            }
        }

        /// The owning library UUID (for PDF paths, context operations, etc.)
        var owningLibraryID: UUID? {
            switch self {
            case .library(let lib): return lib.id
            case .smartSearch(let ss): return ss.library?.id
            case .collection(let col): return col.effectiveLibrary?.id
            case .scixLibrary: return nil // SciX libraries are remote
            case .flagged: return nil // Cross-library virtual source
            }
        }

        /// Convert to PublicationSource for RustStoreAdapter queries
        var publicationSource: PublicationSource {
            switch self {
            case .library(let lib):
                return lib.isInbox ? .inbox(lib.id) : .library(lib.id)
            case .smartSearch(let ss): return .smartSearch(ss.id)
            case .collection(let col): return .collection(col.id)
            case .scixLibrary(let lib): return .scixLibrary(lib.id)
            case .flagged(let color): return .flagged(color)
            }
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
                if let pubID = publicationForBibTeXSheet,
                   let pub = fetchCDPublication(id: pubID) {
                    IOSBibTeXEditorSheet(publication: pub)
                }
            }
            .sheet(isPresented: $showLibraryPicker) {
                LibraryPickerSheet(
                    isPresented: $showLibraryPicker,
                    libraries: libraryManager.libraries.filter { !$0.isInbox },
                    onSelect: { library in
                        Task {
                            await handleAddToLibrary(multiSelection, library.id)
                            exitSelectionMode()
                        }
                    }
                )
            }
            .task(id: source.id) {
                await loadPublications()
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
            allLibraries: libraryManager.libraries.map { (id: $0.id, name: $0.displayName) },
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
            onDelete: { ids in await handleDelete(ids) },
            onToggleRead: { pubID in await handleToggleRead(pubID) },
            onCopy: { ids in await handleCopy(ids) },
            onCut: { ids in await handleCut(ids) },
            onPaste: { await handlePaste() },
            onAddToLibrary: { ids, libraryID in await handleAddToLibrary(ids, libraryID) },
            onAddToCollection: { ids, collectionID in await handleAddToCollection(ids, collectionID) },
            onRemoveFromAllCollections: { ids in await handleRemoveFromAllCollections(ids) },
            onImport: shouldShowImportButton ? { handleImport() } : nil,
            onOpenPDF: { pubID in handleOpenPDF(pubID) },
            onSaveToLibrary: source.isInbox ? { ids, targetLibraryID in await handleSaveToLibrary(ids, targetLibraryID) } : nil,
            onDismiss: { ids in await handleDismiss(ids) },
            onSetFlag: { ids, color in await handleSetFlag(ids, color) },
            onClearFlag: { ids in await handleClearFlag(ids) },
            onRemoveTag: { pubID, tagID in handleRemoveTag(pubID: pubID, tagID: tagID) },
            onCategoryTap: { cat in handleCategoryTap(cat) },
            onRefresh: { await refreshFromSource() },
            onOpenInBrowser: { pubID, dest in handleOpenInBrowser(pubID, dest) },
            onDownloadPDF: { pubID in handleDownloadPDF(pubID) },
            onViewEditBibTeX: { pubID in handleViewEditBibTeX(pubID) },
            onShare: { pubID in handleShare(pubID) },
            onExploreReferences: { pubID in handleExploreReferences(pubID) },
            onExploreCitations: { pubID in handleExploreCitations(pubID) },
            onExploreSimilar: { pubID in handleExploreSimilar(pubID) }
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
        if case .scixLibrary(let lib) = source, !isSelectionMode {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    syncStatusIcon(for: lib)

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
                    Task {
                        await handleDelete(multiSelection)
                        exitSelectionMode()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func syncStatusIcon(for library: CDSciXLibrary) -> some View {
        switch library.syncStateEnum {
        case .synced:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case .pending:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Computed Properties

    private var shouldShowImportButton: Bool {
        switch source {
        case .library(let lib): return !lib.isInbox
        case .smartSearch, .collection, .scixLibrary, .flagged: return false
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

    /// Load publications from RustStoreAdapter, falling back to Core Data for sources
    /// that haven't been fully migrated yet.
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
        case .library:
            refreshPublicationsList()

        case .smartSearch(let smartSearch):
            await refreshSmartSearch(smartSearch)

        case .collection:
            refreshPublicationsList()

        case .scixLibrary(let library):
            await refreshSciXLibrary(library)

        case .flagged:
            refreshPublicationsList()
        }
    }

    private func refreshSmartSearch(_ smartSearch: CDSmartSearch) async {
        // Route group feeds to GroupFeedRefreshService
        if smartSearch.isGroupFeed {
            do {
                _ = try await GroupFeedRefreshService.shared.refreshGroupFeed(smartSearch)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Group feed error: \(error.localizedDescription)")
            }
        } else {
            let provider = await SmartSearchProviderCache.shared.getOrCreate(
                for: smartSearch,
                sourceManager: searchViewModel.sourceManager,
                repository: searchViewModel.repository
            )

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

    private func refreshSciXLibrary(_ library: CDSciXLibrary) async {
        do {
            try await SciXSyncManager.shared.pullLibraryPapers(libraryID: library.remoteID)
            refreshPublicationsList()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Fetch a CDPublication by ID for legacy APIs that still require Core Data objects.
    private func fetchCDPublication(id: UUID) -> CDPublication? {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id_ == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
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
        _ = RustStoreAdapter.shared.duplicatePublications(ids: Array(ids), toLibraryId: targetLibraryID)
        refreshPublicationsList()
    }

    private func handleAddToCollection(_ ids: Set<UUID>, _ collectionID: UUID) async {
        RustStoreAdapter.shared.addToCollection(publicationIds: Array(ids), collectionId: collectionID)
    }

    private func handleRemoveFromAllCollections(_ ids: Set<UUID>) async {
        // TODO: implement removeFromAllCollections with Rust store
        refreshPublicationsList()
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
        let visualOrder = computeVisualOrder()

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

    /// Remove a tag from a publication
    private func handleRemoveTag(pubID: UUID, tagID: UUID) {
        // TODO: implement tag removal by tagID with Rust store
        // The Rust store uses tag paths, not tag UUIDs. Need to look up the tag path from tagID.
        Task {
            refreshPublicationsList()
        }
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

        Task {
            do {
                // Construct remote PDF URL from arXiv ID or other identifiers
                var pdfURL: URL?
                if let arxivID = pub.arxivID {
                    pdfURL = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
                }

                if let pdfURL {
                    let (data, _) = try await URLSession.shared.data(from: pdfURL)
                    // Use Core Data object for AttachmentManager (legacy API)
                    if let cdPub = fetchCDPublication(id: pubID) {
                        try AttachmentManager.shared.importAttachment(
                            data: data,
                            for: cdPub,
                            fileExtension: "pdf",
                            displayName: "\(pub.citeKey).pdf"
                        )
                        refreshPublicationsList()
                    }
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
    let libraries: [CDLibrary]
    let onSelect: (CDLibrary) -> Void

    var body: some View {
        NavigationStack {
            List(libraries) { library in
                Button {
                    onSelect(library)
                    isPresented = false
                } label: {
                    Label(library.displayName, systemImage: "folder")
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
