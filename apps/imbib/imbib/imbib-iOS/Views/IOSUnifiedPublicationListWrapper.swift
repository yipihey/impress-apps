//
//  IOSUnifiedPublicationListWrapper.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-19.
//

import SwiftUI
import PublicationManagerCore
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
/// and leverages `SelectionAdvancement` and `InboxTriageService` for triage.
struct IOSUnifiedPublicationListWrapper: View {

    // MARK: - Source Type

    /// The data source for the publication list.
    enum Source: Hashable {
        case library(CDLibrary)
        case smartSearch(CDSmartSearch)
        case collection(CDCollection)
        case scixLibrary(CDSciXLibrary)

        var id: UUID {
            switch self {
            case .library(let lib): return lib.id
            case .smartSearch(let ss): return ss.id
            case .collection(let col): return col.id
            case .scixLibrary(let lib): return lib.id
            }
        }

        var isInbox: Bool {
            switch self {
            case .library(let lib): return lib.isInbox
            case .smartSearch(let ss): return ss.feedsToInbox
            case .collection, .scixLibrary: return false
            }
        }

        var navigationTitle: String {
            switch self {
            case .library(let lib): return lib.displayName
            case .smartSearch(let ss): return ss.name
            case .collection(let col): return col.name
            case .scixLibrary(let lib): return lib.displayName
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
            }
        }

        var listID: ListViewID {
            switch self {
            case .library(let lib): return .library(lib.id)
            case .smartSearch(let ss): return .smartSearch(ss.id)
            case .collection(let col): return .collection(col.id)
            case .scixLibrary(let lib): return .scixLibrary(lib.id)
            }
        }

        /// The library that owns these publications (for PDF paths, etc.)
        var owningLibrary: CDLibrary? {
            switch self {
            case .library(let lib): return lib
            case .smartSearch(let ss): return ss.library
            case .collection(let col): return col.effectiveLibrary
            case .scixLibrary: return nil // SciX libraries are remote
            }
        }
    }

    // MARK: - Properties

    let source: Source
    @Binding var selectedPublication: CDPublication?

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel

    // MARK: - State

    @State private var publications: [CDPublication] = []
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
    @State private var publicationForSheet: CDPublication?

    // MARK: - Body

    var body: some View {
        publicationListContent
            .navigationTitle(source.navigationTitle)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showBibTeXEditor) {
                if let publication = publicationForSheet {
                    IOSBibTeXEditorSheet(publication: publication)
                }
            }
            .task(id: source.id) {
                await loadPublications()
            }
            .refreshable {
                await refreshFromSource()
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

    /// Separated to help Swift type checker
    @ViewBuilder
    private var publicationListContent: some View {
        PublicationListView(
            publications: publications,
            selection: $multiSelection,
            selectedPublication: $selectedPublication,
            library: source.owningLibrary,
            allLibraries: libraryManager.libraries,
            showImportButton: shouldShowImportButton,
            showSortMenu: true,
            emptyStateMessage: source.emptyStateMessage,
            emptyStateDescription: source.emptyStateDescription,
            listID: source.listID,
            disableUnreadFilter: source.isInbox,
            isInInbox: source.isInbox,
            keepLibrary: source.isInbox ? libraryManager.getOrCreateKeepLibrary() : nil,
            filterScope: $filterScope,
            sortOrder: $currentSortOrder,
            sortAscending: $currentSortAscending,
            recommendationScores: $recommendationScores,
            onDelete: { ids in await handleDelete(ids) },
            onToggleRead: { pub in await handleToggleRead(pub) },
            onCopy: { ids in await handleCopy(ids) },
            onCut: { ids in await handleCut(ids) },
            onPaste: { await handlePaste() },
            onAddToLibrary: { ids, lib in await handleAddToLibrary(ids, lib) },
            onAddToCollection: { ids, col in await handleAddToCollection(ids, col) },
            onRemoveFromAllCollections: { ids in await handleRemoveFromAllCollections(ids) },
            onImport: shouldShowImportButton ? { handleImport() } : nil,
            onOpenPDF: { pub in handleOpenPDF(pub) },
            onKeepToLibrary: source.isInbox ? { ids, lib in await handleKeepToLibrary(ids, lib) } : nil,
            onDismiss: { ids in await handleDismiss(ids) },
            onCategoryTap: { cat in handleCategoryTap(cat) },
            onOpenInBrowser: { pub, dest in handleOpenInBrowser(pub, dest) },
            onDownloadPDF: { pub in handleDownloadPDF(pub) },
            onViewEditBibTeX: { pub in handleViewEditBibTeX(pub) },
            onShare: { pub in handleShare(pub) },
            onExploreReferences: { pub in handleExploreReferences(pub) },
            onExploreCitations: { pub in handleExploreCitations(pub) },
            onExploreSimilar: { pub in handleExploreSimilar(pub) }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Refresh button for smart searches
        if case .smartSearch = source {
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
        if case .scixLibrary(let lib) = source {
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
        case .smartSearch, .collection, .scixLibrary: return false
        }
    }

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
        case .collection(let col):
            if let lib = col.effectiveLibrary {
                return .regularLibrary(lib)
            }
            return .inboxLibrary
        case .scixLibrary:
            return .inboxLibrary // SciX doesn't support triage
        }
    }

    // MARK: - Visual Order Computation

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
                lhs.dateAdded > rhs.dateAdded
            case .dateModified:
                lhs.dateModified > rhs.dateModified
            case .title:
                (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
            case .year:
                (lhs.year ?? 0) > (rhs.year ?? 0)
            case .citeKey:
                lhs.citeKey.localizedCaseInsensitiveCompare(rhs.citeKey) == .orderedAscending
            case .citationCount:
                (lhs.citationCount ?? 0) > (rhs.citationCount ?? 0)
            case .recommended:
                true  // Handled above, this won't be reached
            }
            return currentSortAscending == currentSortOrder.defaultAscending ? defaultComparison : !defaultComparison
        }

        return sorted
    }

    // MARK: - Data Loading

    private func loadPublications() async {
        switch source {
        case .library(let library):
            loadLibraryPublications(library)

        case .smartSearch(let smartSearch):
            await loadSmartSearchPublications(smartSearch)

        case .collection(let collection):
            await loadCollectionPublications(collection)

        case .scixLibrary(let library):
            loadSciXPublications(library)
            // Auto-refresh if library has no cached publications but should have some
            if publications.isEmpty && library.documentCount > 0 {
                await refreshSciXLibrary(library)
            }
        }
    }

    private func loadLibraryPublications(_ library: CDLibrary) {
        var result = (library.publications ?? [])
            .filter { !$0.isDeleted }

        // Filter out dismissed papers in Inbox
        if library.isInbox {
            result = result.filter { pub in
                !InboxManager.shared.wasDismissed(
                    doi: pub.doi,
                    arxivID: pub.arxivID,
                    bibcode: pub.bibcode
                )
            }
        }

        publications = result.sorted { $0.dateAdded > $1.dateAdded }
    }

    private func loadSmartSearchPublications(_ smartSearch: CDSmartSearch) async {
        guard let collection = smartSearch.resultCollection else {
            publications = []
            return
        }

        publications = (collection.publications ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    private func loadCollectionPublications(_ collection: CDCollection) async {
        var result: [CDPublication]

        if collection.isSmartCollection {
            result = await libraryViewModel.executeSmartCollection(collection)
        } else {
            result = Array(collection.publications ?? [])
                .filter { !$0.isDeleted }
        }

        publications = result.sorted { $0.dateAdded > $1.dateAdded }
    }

    private func loadSciXPublications(_ library: CDSciXLibrary) {
        if let context = library.managedObjectContext {
            context.refresh(library, mergeChanges: true)
        }
        publications = Array(library.publications ?? [])
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    // MARK: - Refresh

    private func refreshFromSource() async {
        isRefreshing = true
        defer { isRefreshing = false }

        switch source {
        case .library(let library):
            loadLibraryPublications(library)

        case .smartSearch(let smartSearch):
            await refreshSmartSearch(smartSearch)

        case .collection(let collection):
            await loadCollectionPublications(collection)

        case .scixLibrary(let library):
            await refreshSciXLibrary(library)
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

        // Reload publications from result collection
        if let collection = smartSearch.resultCollection {
            publications = (collection.publications ?? [])
                .filter { !$0.isDeleted }
                .sorted { $0.dateAdded > $1.dateAdded }
        }
    }

    private func refreshSciXLibrary(_ library: CDSciXLibrary) async {
        do {
            try await SciXSyncManager.shared.pullLibraryPapers(libraryID: library.remoteID)
            loadSciXPublications(library)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Handlers

    private func handleDelete(_ ids: Set<UUID>) async {
        publications.removeAll { ids.contains($0.id) }
        multiSelection.subtract(ids)
        await libraryViewModel.delete(ids: ids)
        await loadPublications()
    }

    private func handleToggleRead(_ publication: CDPublication) async {
        await libraryViewModel.toggleReadStatus(publication)
        await loadPublications()
    }

    private func handleCopy(_ ids: Set<UUID>) async {
        await libraryViewModel.copyToClipboard(ids)
    }

    private func handleCut(_ ids: Set<UUID>) async {
        await libraryViewModel.cutToClipboard(ids)
        await loadPublications()
    }

    private func handlePaste() async {
        try? await libraryViewModel.pasteFromClipboard()
        await loadPublications()
    }

    private func handleAddToLibrary(_ ids: Set<UUID>, _ targetLibrary: CDLibrary) async {
        await libraryViewModel.addToLibrary(ids, library: targetLibrary)
        await loadPublications()
    }

    private func handleAddToCollection(_ ids: Set<UUID>, _ targetCollection: CDCollection) async {
        await libraryViewModel.addToCollection(ids, collection: targetCollection)
    }

    private func handleRemoveFromAllCollections(_ ids: Set<UUID>) async {
        await libraryViewModel.removeFromAllCollections(ids)
        await loadPublications()
    }

    private func handleImport() {
        NotificationCenter.default.post(name: .importBibTeX, object: nil)
    }

    private func handleOpenPDF(_ publication: CDPublication) {
        guard let linkedFiles = publication.linkedFiles,
              let pdfFile = linkedFiles.first(where: { $0.isPDF }),
              let libraryURL = source.owningLibrary?.folderURL else { return }

        let pdfURL = libraryURL.appendingPathComponent(pdfFile.relativePath)
        _ = FileManager_Opener.shared.openFile(pdfURL)
    }

    // MARK: - Inbox Triage Handlers

    private func handleKeepToLibrary(_ ids: Set<UUID>, _ targetLibrary: CDLibrary) async {
        // Compute visual order synchronously for correct selection advancement
        let visualOrder = computeVisualOrder()

        let result = InboxTriageService.shared.keepToLibrary(
            ids: ids,
            from: visualOrder,
            currentSelection: selectedPublication,
            targetLibrary: targetLibrary,
            source: triageSource
        )

        // On iOS, clear selection to stay in list view (no split view detail)
        // But we still compute next selection for potential future use
        multiSelection.removeAll()
        selectedPublication = nil

        await loadPublications()
    }

    private func handleDismiss(_ ids: Set<UUID>) async {
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

        // On iOS, clear selection to stay in list view (no split view detail)
        // But we still compute next selection for potential future use
        multiSelection.removeAll()
        selectedPublication = nil

        await loadPublications()
    }

    // MARK: - Context Menu Handlers

    private func handleCategoryTap(_ category: String) {
        NotificationCenter.default.post(
            name: .searchCategory,
            object: nil,
            userInfo: ["category": category]
        )
    }

    private func handleOpenInBrowser(_ publication: CDPublication, _ destination: BrowserDestination) {
        var urlString: String?

        switch destination {
        case .arxiv:
            if let arxivID = publication.arxivID {
                urlString = "https://arxiv.org/abs/\(arxivID)"
            }
        case .ads:
            if let bibcode = publication.bibcode {
                urlString = "https://ui.adsabs.harvard.edu/abs/\(bibcode)"
            }
        case .doi, .publisher:
            if let doi = publication.doi {
                urlString = doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)"
            }
        }

        if let urlString = urlString, let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    private func handleDownloadPDF(_ publication: CDPublication) {
        Task {
            do {
                if let pdfURL = publication.bestRemotePDFURL {
                    let (data, _) = try await URLSession.shared.data(from: pdfURL)
                    try AttachmentManager.shared.importAttachment(
                        data: data,
                        for: publication,
                        fileExtension: "pdf",
                        displayName: "\(publication.citeKey).pdf"
                    )
                    await loadPublications()
                }
            } catch {
                logger.error("Failed to download PDF: \(error.localizedDescription)")
            }
        }
    }

    private func handleViewEditBibTeX(_ publication: CDPublication) {
        publicationForSheet = publication
        showBibTeXEditor = true
    }

    private func handleShare(_ publication: CDPublication) {
        var items: [Any] = []

        let title = publication.title ?? "Untitled"
        items.append(title)

        if let doi = publication.doi {
            let doiURL = doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)"
            if let url = URL(string: doiURL) {
                items.append(url)
            }
        } else if let arxivID = publication.arxivID {
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

    private func handleExploreReferences(_ publication: CDPublication) {
        NotificationCenter.default.post(name: .exploreReferences, object: publication)
    }

    private func handleExploreCitations(_ publication: CDPublication) {
        NotificationCenter.default.post(name: .exploreCitations, object: publication)
    }

    private func handleExploreSimilar(_ publication: CDPublication) {
        NotificationCenter.default.post(name: .exploreSimilar, object: publication)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        Text("Preview requires LibraryManager")
    }
}
