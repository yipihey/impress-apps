//
//  IOSUnifiedPublicationListWrapper.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-19.
//  Revived on 2026-07-20: ported off the deleted Core Data types
//  (CDLibrary/CDCollection/CDSmartSearch/CDSciXLibrary/CDPublication)
//  to the value-type + RustStoreAdapter world.
//
//  Stage 5d (2026-07-30): the model half moved to the chassis. This file is now
//  iOS CHROME over `PublicationListCore` + `PublicationScope` +
//  `PublicationListOrder` + `PublicationListMutations`, which macOS's
//  `UnifiedPublicationListWrapper` reads too (see each file's header for what
//  the duplication was costing — four invariant violations lived in the copies
//  this file used to carry, including an unconditional `deletePublications`).
//
//  What stays here, and why:
//
//    * The `Source` enum. It is the SIDEBAR ROUTE, not a second
//      `PublicationSource`: `.library(id, name, isInbox:)` carries a display
//      name the chassis enum cannot express, which is the whole reason it
//      exists. It no longer derives ids or list keys — it maps to a
//      `PublicationSource` and asks. Its hand-copied `flaggedID(for:)` table,
//      which claimed to match macOS's and did not, is gone.
//    * The empty-state and title COPY. iOS ships different words than macOS
//      ("Add feeds to start discovering papers." vs "No new papers in your
//      inbox.") and guards an empty smart-search query where macOS renders
//      `No Results for ""`. Unifying strings changes the frozen macOS pane;
//      that is a product decision, not a refactor.
//    * The toolbar (Select/Done, per-scope refresh button, SciX sync glyph,
//      the bottom bar), the library-picker sheet, the BibTeX sheet, share and
//      open-in-browser. Touch chrome and iOS-only affordances — macOS's list has
//      no equivalents to converge with.
//    * Selection policy. Triage CLEARS the selection here rather than advancing
//      it: on a phone the split view is a stack, so writing a selection pushes
//      the detail view over the list the user is triaging in.
//

import SwiftUI
import PublicationManagerCore
import ImpressFTUI  // FlagColor
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "ios-list")

/// Unified iOS wrapper for displaying publications from any source.
///
/// It uses the shared `PublicationListView` for rows and the shared
/// `PublicationListCore` for scope → rows, and leaves the chrome here.
struct IOSUnifiedPublicationListWrapper: View {

    // MARK: - Source Type

    /// The sidebar route whose publications we display.
    ///
    /// All cases carry only value types (ids / strings) so the view is fully
    /// decoupled from the underlying store handle. Everything derivable from a
    /// `PublicationSource` is derived there — see `publicationSource` below and
    /// `Chassis/Shared/PublicationScope.swift`.
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

        /// Convert to `PublicationSource` for chassis queries and derivations.
        ///
        /// ADR-0018 D3: the shared half CONSUMES `PublicationSource` and never
        /// redefines or widens it. This is the one seam where the iOS route type
        /// meets it.
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

        /// Stable identity for `.task(id:)` / `.id()`.
        ///
        /// Delegates to `PublicationSource.viewID` — the chassis's one
        /// deterministic table. The previous local `flaggedID(for:)` mapped
        /// red/amber/blue/gray to `F1A99ED0-000n-…` while the chassis maps them
        /// into `00000000-…-%012x` by a different colour index, so the two
        /// platforms silently read and wrote different `ListViewStateStore`
        /// entries for every flagged scope. Deleting the copy costs iOS its
        /// previously-saved sort/unread state for flagged scopes exactly once.
        @MainActor
        var id: UUID { publicationSource.viewID }

        /// Display name for the navigation bar. iOS-specific copy — see the
        /// file header for why the strings are not shared.
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
                return publicationSource.isInboxScope ? "Inbox Empty" : "No Publications"
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
                return publicationSource.isInboxScope
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
    }

    // MARK: - Properties

    let source: Source
    @Binding var selectedPublicationID: UUID?

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel

    // MARK: - State

    /// Scope → rows, the sort, the store subscription and the network refresh.
    /// The shared half; see Chassis/Shared/PublicationListCore.swift.
    @State private var core: PublicationListCore

    @State private var multiSelection = Set<UUID>()
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var filterScope: FilterScope = .current

    /// Sort selection lives with the host because `PublicationListView` renders
    /// the sort menu and binds it; the core turns it into an `ORDER BY`.
    @State private var currentSortOrder: LibrarySortOrder = .dateAdded
    @State private var currentSortAscending: Bool = false

    /// ADR-020: Recommendation scores for sorted display.
    @State private var recommendationScores: [UUID: Double] = [:]

    /// The BibTeX sheet's target, as ONE piece of state.
    ///
    /// This used to be `showBibTeXEditor: Bool` + `publicationForBibTeXSheet:
    /// UUID?`, presented with `.sheet(isPresented:)` and an `if let` inside the
    /// content builder. `handleViewEditBibTeX` writes both in the same runloop
    /// turn, and SwiftUI evaluated the builder while the id was still nil — so
    /// **the row action presented a completely EMPTY sheet**, which is what it
    /// had been doing (no test covered it; the sheet's `NavigationStack` never
    /// even reached the view tree). `.sheet(item:)` derives presentation FROM
    /// the id, so there is no order to get wrong.
    @State private var bibTeXTarget: BibTeXSheetTarget?

    /// `UUID` is not `Identifiable`; `.sheet(item:)` needs it to be.
    private struct BibTeXSheetTarget: Identifiable {
        let id: UUID
    }

    // Selection mode (for multi-selection like Mail app)
    @State private var isSelectionMode = false

    // Library picker for bulk add
    @State private var showLibraryPicker = false

    // MARK: - Init

    /// Builds the core eagerly so the FIRST render shows rows rather than an
    /// empty list — `PublicationListCore.init` loads page one synchronously,
    /// which is what macOS's wrapper has always done. The core is replaced in
    /// `.task(id:)` when the scope changes, because SwiftUI keeps `@State`
    /// across a same-branch route change (the `.id(source.id)` hazard).
    init(source: Source, selectedPublicationID: Binding<UUID?>) {
        self.source = source
        self._selectedPublicationID = selectedPublicationID
        _core = State(initialValue: PublicationListCore(source: source.publicationSource))
    }

    // MARK: - Derived scope facts

    private var scope: PublicationSource { core.source }

    private var isInbox: Bool { scope.isInboxScope }

    /// Whether this scope IS the Dismissed library — i.e. whether Delete means
    /// "permanently", the way emptying a Trash does. iOS routes its Dismissed
    /// screen through `.libraryByID(dismissed.id)` rather than
    /// `PublicationSource.dismissed`, so the test is an id comparison.
    private var isViewingDismissedLibrary: Bool {
        guard let dismissed = libraryManager.dismissedLibrary else { return false }
        return scope.owningLibraryID == dismissed.id
    }

    // MARK: - Body

    var body: some View {
        publicationListContent
            .navigationTitle(source.navigationTitle)
            .toolbar { toolbarContent }
            .environment(\.editMode, isSelectionMode ? .constant(.active) : .constant(.inactive))
            .sheet(item: $bibTeXTarget) { target in
                IOSBibTeXEditorSheet(publicationID: target.id)
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
            // One task per scope: swap the core when the route changes, then run
            // its store subscription for as long as that scope is on screen.
            // Cancelled and restarted by SwiftUI when `source.id` changes.
            .task(id: source.id) {
                let target = source.publicationSource
                let active: PublicationListCore
                if core.source == target {
                    active = core
                } else {
                    active = PublicationListCore(
                        source: target,
                        sortOrder: currentSortOrder,
                        sortAscending: currentSortAscending
                    )
                    core = active
                }
                logger.info(
                    "Loaded \(active.rows.count) publications for \(source.navigationTitle)")
                await active.observeStoreEvents()
            }
            // The edge iOS never had: a sort change is an ORDER BY, so it has to
            // reach the store. Without these the sort menu ticked and the list
            // did not move.
            .onChange(of: currentSortOrder) { _, newOrder in
                core.applySort(newOrder, ascending: currentSortAscending)
            }
            .onChange(of: currentSortAscending) { _, newAscending in
                core.applySort(currentSortOrder, ascending: newAscending)
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            // Disable swipe-back gesture when inbox has swipe actions
            // to prevent conflict with "keep" swipe right gesture
            .modifier(ConditionalDisableSwipeBackModifier(isEnabled: isInbox))
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
            publications: core.rows,
            selection: $multiSelection,
            selectedPublicationID: $selectedPublicationID,
            libraryID: scope.owningLibraryID,
            allLibraries: libraryManager.libraries.map { (id: $0.id, name: $0.name) },
            showImportButton: shouldShowImportButton,
            showSortMenu: true,
            emptyStateMessage: source.emptyStateMessage,
            emptyStateDescription: source.emptyStateDescription,
            listID: scope.listViewID,
            disableUnreadFilter: isInbox,
            isInInbox: isInbox,
            saveLibraryID: isInbox ? libraryManager.getOrCreateSaveLibrary().id : nil,
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
                a.onSaveToLibrary = isInbox ? { ids, targetLibraryID in await handleSaveToLibrary(ids, targetLibraryID) } : nil
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
            }(),
            // Pagination, which iOS did not have: it used to read the whole
            // scope in one unbounded query. The core reads pages, so the tail
            // has to ask for the next one.
            onRowAppeared: { id in core.loadMoreIfNeeded(after: id) }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Select/Done button (always visible when there are publications)
        if !core.rows.isEmpty {
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
            return !isInbox
        case .smartSearch, .collection, .scixLibrary, .flagged, .citedInManuscripts, .recent:
            return false
        }
    }

    // MARK: - Refresh

    /// Pull-to-refresh and the toolbar refresh button. The scope→network mapping
    /// is the core's; the spinner and the alert are this file's.
    private func refreshFromSource() async {
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = await core.refreshFromSource(sourceManager: searchViewModel.sourceManager)
    }

    // MARK: - Handlers

    /// Delete = soft-delete to Dismissed, except when already viewing Dismissed.
    ///
    /// This used to call `deletePublications` unconditionally, from every scope,
    /// so "Delete" on a phone destroyed the paper while the same word on the Mac
    /// moved it to a recoverable Dismissed library.
    private func handleDelete(_ ids: Set<UUID>) async {
        core.optimisticallyRemove(ids: ids)
        multiSelection.subtract(ids)
        PublicationListMutations.delete(
            ids: ids,
            source: scope,
            permanently: isViewingDismissedLibrary,
            dismissedLibraryID: { libraryManager.getOrCreateDismissedLibrary().id }
        )
        core.reload()
    }

    private func handleToggleRead(_ pubID: UUID) async {
        let store = RustStoreAdapter.shared
        let pub = store.getPublication(id: pubID)
        store.setRead(ids: [pubID], read: !(pub?.isRead ?? false))
        core.reload()
    }

    private func handleCopy(_ ids: Set<UUID>) async {
        await libraryViewModel.copyToClipboard(ids)
    }

    private func handleCut(_ ids: Set<UUID>) async {
        await libraryViewModel.cutToClipboard(ids)
        core.reload()
    }

    private func handlePaste() async {
        try? await libraryViewModel.pasteFromClipboard()
        core.reload()
    }

    private func handleAddToLibrary(_ ids: Set<UUID>, _ targetLibraryID: UUID) async {
        // Multi-library membership via Contains edges — no duplicate item created.
        RustStoreAdapter.shared.libraryAddMembers(libraryId: targetLibraryID, publicationIds: Array(ids))
        core.reload()
    }

    private func handleAddToCollection(_ ids: Set<UUID>, _ collectionID: UUID) async {
        RustStoreAdapter.shared.addToCollection(publicationIds: Array(ids), collectionId: collectionID)
    }

    private func handleRemoveFromAllCollections(_ ids: Set<UUID>) async {
        PublicationListMutations.removeFromAllCollections(ids: ids)
        core.reload()
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

    /// Save out of a feed. Selection is CLEARED, not advanced — see the file
    /// header (a phone's split view is a stack).
    private func handleSaveToLibrary(_ ids: Set<UUID>, _ targetLibraryID: UUID) async {
        // Record the dismissal FIRST: this is imbib's first critical invariant
        // ("Dismissed papers must never re-enter the inbox"), and this file used
        // to skip it entirely — a paper saved out of the inbox came back on the
        // next feed refresh.
        PublicationListMutations.trackInboxDismissals(ids: ids, source: scope)
        PublicationListMutations.save(ids: ids, to: targetLibraryID, source: scope)

        multiSelection.removeAll()
        selectedPublicationID = nil

        core.reload()
    }

    /// Dismiss to the Dismissed library, tracking the dismissal so feeds cannot
    /// bring the paper back.
    private func handleDismiss(_ ids: Set<UUID>) async {
        let dismissedLibrary = libraryManager.getOrCreateDismissedLibrary()
        PublicationListMutations.dismiss(
            ids: ids, source: scope, dismissedLibraryID: dismissedLibrary.id)

        multiSelection.removeAll()
        selectedPublicationID = nil

        core.reload()
    }

    // MARK: - Flag Handlers

    private func handleSetFlag(_ ids: Set<UUID>, _ color: FlagColor) async {
        RustStoreAdapter.shared.setFlag(ids: Array(ids), color: color.rawValue)
        core.reload()
    }

    private func handleClearFlag(_ ids: Set<UUID>) async {
        RustStoreAdapter.shared.setFlag(ids: Array(ids), color: nil)
        core.reload()
    }

    /// Remove a tag from a publication.
    private func handleRemoveTag(pubID: UUID, tagID: UUID) {
        // Migration debt, on BOTH platforms: the Rust store keys tag membership
        // by tag PATH, but this callback hands us a tag UUID and there is no
        // tagID→path lookup in the store (TagDefinition.id is the path string,
        // not a UUID). macOS's `handleRemoveTag` is the same no-op with the same
        // TODO. No-op until the row model surfaces the tag path or the store
        // gains a UUID-keyed removal.
        logger.warning("removeTag is a no-op — no tagID(\(tagID))→path mapping in Rust store for pub \(pubID)")
        core.reload()
    }

    // MARK: - Context Menu Handlers

    private func handleCategoryTap(_ category: String) {
        NotificationCenter.default.post(
            name: .searchCategory,
            object: nil,
            userInfo: ["category": category]
        )
    }

    /// iOS-only: macOS's list has no `onOpenInBrowser` action, and the chassis's
    /// `BrowserURLProviderRegistry` answers "the one best URL for this paper",
    /// not "the URL for this destination". Nothing to converge with.
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
        let libraryID = scope.owningLibraryID

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
                    core.reload()
                }
            } catch {
                logger.error("Failed to download PDF: \(error.localizedDescription)")
            }
        }
    }

    private func handleViewEditBibTeX(_ pubID: UUID) {
        // One write. See `bibTeXTarget` for the empty-sheet bug two writes
        // caused.
        bibTeXTarget = BibTeXSheetTarget(id: pubID)
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
