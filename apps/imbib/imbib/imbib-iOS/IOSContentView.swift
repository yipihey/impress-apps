//
//  IOSContentView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import ImpressKeyboard
import UniformTypeIdentifiers
import OSLog

private let contentLogger = Logger(subsystem: "com.imbib.app", category: "content")

struct IOSContentView: View {

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // MARK: - State

    @State private var selectedSection: SidebarSection? = nil
    /// UUID-based selection for the publication list wrappers.
    @State private var selectedPublicationID: UUID?
    /// Selected manuscript (manuscript@1.0.0 item) for the manuscripts section.
    @State private var selectedManuscriptID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // File import/export
    @State private var showImportPicker = false
    @State private var showExportPicker = false
    @State private var showImportPreview = false
    @State private var importFileURL: URL?

    // Settings
    @State private var showSettings = false

    /// Smart Search presented full-screen — the iOS "⌘S anywhere": reached
    /// from the root swipe-right gesture (and available to any future
    /// trigger). The sidebar's "Smart Search (AI)" row shows the same view
    /// embedded as its content pane.
    @State private var showSmartSearch = false

    // Keyboard shortcuts help sheet (Cmd+/)
    @State private var showShortcutsHelp = false

    // Category search (for navigating from category chip tap)
    @State private var pendingCategorySearch: String?

    // Cmd+F local find and Cmd+S online source search
    @State private var searchPresenter = ImbibSearchPresenter()

    // Active detail tab (for search context)
    @State private var activeDetailTab: DetailTab = .info

    // PDF search query (passed to PDF tab when searching in PDF context)
    @State private var pendingPDFSearchQuery: String?

    // Onboarding
    @State private var showOnboarding = false

    // MARK: - Body

    var body: some View {
        mainSplitView
            .modifier(NotificationHandlers(
                selectedSection: $selectedSection,
                showImportPicker: $showImportPicker,
                showExportPicker: $showExportPicker,
                pendingCategorySearch: $pendingCategorySearch,
                selectedPublicationID: $selectedPublicationID,
                libraryManager: libraryManager,
                libraryViewModel: libraryViewModel
            ))
            .modifier(FileHandlers(
                showImportPicker: $showImportPicker,
                showExportPicker: $showExportPicker,
                showImportPreview: $showImportPreview,
                importFileURL: $importFileURL,
                importAction: importPreviewEntries
            ))
            .sheet(isPresented: $showSettings) {
                IOSSettingsView()
            }
            .sheet(isPresented: $showShortcutsHelp) {
                NavigationStack {
                    IOSKeyboardShortcutsSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showShortcutsHelp = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet()
            }
            .fullScreenCover(isPresented: $showSmartSearch) {
                NavigationStack {
                    IOSSmartSearchView(onDismiss: { showSmartSearch = false })
                }
            }
            .fullScreenCover(isPresented: localFindPresented) {
                GlobalSearchPaletteView(
                    isPresented: localFindPresented,
                    onSelect: { publicationID in
                        navigateToPublication(publicationID)
                    },
                    onPDFSearch: { query in
                        // Trigger PDF search in the current PDF tab
                        pendingPDFSearchQuery = query
                        NotificationCenter.default.post(
                            name: .pdfSearchRequested,
                            object: nil,
                            userInfo: ["query": query]
                        )
                    }
                )
                .environment(\.searchContext, searchPresenter.localFindContext)
            }
            .task {
                await libraryViewModel.loadPublications()

                // Check if onboarding should be shown after initial setup
                if OnboardingManager.shared.shouldShowOnboarding {
                    showOnboarding = true
                }
            }
            .onAppear {
                contentLogger.info("IOSContentView appeared")
            }
            .onChange(of: selectedSection) { _, _ in
                selectedPublicationID = nil
                selectedManuscriptID = nil
            }
            .onChange(of: selectedPublicationID) { _, newValue in
                // Reset active tab when publication changes
                if newValue == nil {
                    activeDetailTab = .info
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .detailTabDidChange)) { notification in
                if let tabRawValue = notification.userInfo?["tab"] as? String,
                   let tab = DetailTab(rawValue: tabRawValue) {
                    activeDetailTab = tab
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .performSearchAction)) { notification in
                guard let action = ImbibSearchAction.from(notification) else { return }
                presentSearch(action)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showGlobalSearch)) { _ in
                presentSearch(.localFind(context: currentSearchContext, source: .notificationBridge))
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
                presentSearch(.localFind(context: currentSearchContext, source: .notificationBridge))
            }
            .onReceive(NotificationCenter.default.publisher(for: .showNLSearch)) { _ in
                presentSearch(.onlineSourceSearch(source: .notificationBridge))
            }
            .background {
                KeyboardShortcutButtons(
                    showImportPicker: $showImportPicker,
                    showExportPicker: $showExportPicker,
                    columnVisibility: $columnVisibility,
                    showSettings: $showSettings,
                    showShortcutsHelp: $showShortcutsHelp,
                    onLocalFind: {
                        presentSearch(.localFind(context: currentSearchContext, source: .keyboardShortcut))
                    },
                    onOnlineSourceSearch: {
                        presentSearch(.onlineSourceSearch(source: .keyboardShortcut))
                    },
                    onReEnrichSelection: {
                        reEnrichSelectedPublication()
                    }
                )
            }
    }

    private var localFindPresented: Binding<Bool> {
        Binding(
            get: { searchPresenter.isLocalFindPresented },
            set: { isPresented in
                if !isPresented {
                    searchPresenter.dismiss(.localFind)
                }
            }
        )
    }

    // MARK: - Main Split View

    private var mainSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            IOSSidebarView(
                selection: $selectedSection,
                onNavigateToSmartSearch: { smartSearchID in
                    selectedSection = .smartSearch(smartSearchID)
                    columnVisibility = .detailOnly
                }
            )
            // Swipe RIGHT anywhere on the root sidebar → Smart Search,
            // giving it the privileged "top screen" feel of macOS ⌘S.
            // A content drag, deliberately NOT an edge gesture: the left
            // screen edge is owned by the split view's sidebar-reveal and
            // the navigation back-swipe, so the drag must start >30pt in
            // and be decisively horizontal to fire. simultaneousGesture so
            // list taps/scrolls are unaffected. Compact only — on iPad the
            // sidebar is persistent and the row/toolbar affordances serve.
            .simultaneousGesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        guard horizontalSizeClass == .compact else { return }
                        let dx = value.translation.width
                        let dy = abs(value.translation.height)
                        if value.startLocation.x > 30, dx > 90, dy < dx / 2 {
                            showSmartSearch = true
                        }
                    }
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentSearch(.localFind(context: currentSearchContext, source: .toolbarButton))
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityIdentifier(AccessibilityID.Sidebar.settingsButton)
                }
            }
        } content: {
            contentList
                // COMPACT ONLY: in regular width (iPad, Pro-Max landscape) the
                // detail COLUMN already shows this publication from the same
                // binding; pushing a second copy here meant the back chevron
                // (a two-way navigationDestination binding) nil'ed the shared
                // selection and tore down BOTH — "back from notes dumps you on
                // the publication list". The proxy binding makes the push
                // exist only where it's the sole detail surface.
                .navigationDestination(item: compactOnlyPublicationSelection) { pubID in
                    if let libraryID = selectedLibraryID {
                        DetailView(publicationID: pubID, libraryID: libraryID, selectedPublicationID: $selectedPublicationID, listID: currentListID)
                    } else {
                        // Fallback when no library context
                        ContentUnavailableView(
                            "Publication Unavailable",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("This publication is no longer available.")
                        )
                    }
                }
                .navigationDestination(item: $selectedManuscriptID) { manuscriptID in
                    IOSManuscriptDetailView(manuscriptID: manuscriptID)
                }
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Selection proxy that exposes the publication push ONLY in compact
    /// width. Reads nil in regular width (no redundant push next to the
    /// detail column); writes only apply in compact, so popping the pushed
    /// detail on an iPhone clears selection normally while a regular-width
    /// pop can never nil the detail column's selection.
    private var compactOnlyPublicationSelection: Binding<UUID?> {
        Binding(
            get: { horizontalSizeClass == .compact ? selectedPublicationID : nil },
            set: { newValue in
                if horizontalSizeClass == .compact {
                    selectedPublicationID = newValue
                }
            }
        )
    }

    private func presentSearch(_ action: ImbibSearchAction) {
        switch action.workflow {
        case .localFind:
            searchPresenter.perform(action)

        case .onlineSourceSearch:
            searchPresenter.dismiss()
            selectedSection = .searchForm(.adsModern)
            Logger.search.infoCapture(
                "Presenting iOS online source search fallback from \(action.source.rawValue)",
                category: "search"
            )
        }
    }

    // MARK: - Content List

    @ViewBuilder
    private var contentList: some View {
        switch selectedSection {
        case .inbox:
            if let inboxLibrary = RustStoreAdapter.shared.getInboxLibrary() {
                IOSUnifiedPublicationListWrapper(
                    source: .library(inboxLibrary.id, inboxLibrary.name, isInbox: true),
                    selectedPublicationID: $selectedPublicationID
                )
            } else {
                ContentUnavailableView(
                    "Inbox Empty",
                    systemImage: "tray",
                    description: Text("Add feeds to start discovering papers")
                )
            }

        case .inboxCollection(let collectionID):
            IOSUnifiedPublicationListWrapper(
                source: .collection(collectionID),
                selectedPublicationID: $selectedPublicationID
            )

        case .library(let libraryID):
            IOSUnifiedPublicationListWrapper(
                source: .libraryByID(libraryID),
                selectedPublicationID: $selectedPublicationID
            )

        case .search:
            IOSSearchView(
                selectedPublicationID: $selectedPublicationID,
                initialQuery: pendingCategorySearch
            )
            .onDisappear {
                // Clear pending search when leaving search view
                pendingCategorySearch = nil
            }

        case .searchForm(let formType):
            switch formType {
            case .nlSearch:
                // The real Smart Search interface (was a dead-end "Use Cmd+S"
                // hint — meaningless on touch). Same SmartSearchService the
                // macOS ⌘S overlay drives.
                IOSSmartSearchView()
            case .adsModern:
                ADSModernSearchFormView()
            case .adsClassic:
                ADSClassicSearchFormView()
            case .adsPaper:
                ADSPaperSearchFormView()
            case .adsVagueMemory:
                VagueMemorySearchFormView()
            case .arxivAdvanced:
                ArXivAdvancedSearchFormView()
            case .arxivFeed:
                ArXivFeedFormView()
            case .arxivGroupFeed:
                GroupArXivFeedFormView()
            case .openalex:
                OpenAlexEnhancedSearchFormView()
            }

        case .smartSearch(let smartSearchID):
            IOSUnifiedPublicationListWrapper(
                source: .smartSearch(smartSearchID),
                selectedPublicationID: $selectedPublicationID
            )

        case .collection(let collectionID):
            IOSUnifiedPublicationListWrapper(
                source: .collection(collectionID),
                selectedPublicationID: $selectedPublicationID
            )

        case .scixLibrary(let scixLibID):
            IOSUnifiedPublicationListWrapper(
                source: .scixLibrary(scixLibID),
                selectedPublicationID: $selectedPublicationID
            )

        case .flagged(let color):
            IOSUnifiedPublicationListWrapper(
                source: .flagged(color),
                selectedPublicationID: $selectedPublicationID
            )

        case .citedInManuscripts:
            IOSUnifiedPublicationListWrapper(
                source: .citedInManuscripts,
                selectedPublicationID: $selectedPublicationID
            )

        case .manuscripts:
            IOSManuscriptList(selectedManuscriptID: $selectedManuscriptID)

        case .none:
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.left",
                description: Text("Select a library or collection from the sidebar")
            )
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let manuscriptID = selectedManuscriptID {
            IOSManuscriptDetailView(manuscriptID: manuscriptID)
        } else if let pubID = selectedPublicationID,
           let libraryID = selectedLibraryID {
            DetailView(publicationID: pubID, libraryID: libraryID, selectedPublicationID: $selectedPublicationID, listID: currentListID)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "doc.text",
                description: Text("Select a publication to view details")
            )
        }
    }

    /// Extract library ID from current section selection
    private var selectedLibraryID: UUID? {
        switch selectedSection {
        case .inbox:
            return RustStoreAdapter.shared.getInboxLibrary()?.id
        case .inboxCollection:
            return RustStoreAdapter.shared.getInboxLibrary()?.id
        case .library(let libraryID):
            return libraryID
        case .smartSearch(let ssID):
            return RustStoreAdapter.shared.getSmartSearch(id: ssID)?.libraryID
        case .collection(let colID):
            // Look up the collection's library from the store
            let store = RustStoreAdapter.shared
            // Try to find the collection in each library
            for lib in store.listLibraries() {
                let collections = store.listCollections(libraryId: lib.id)
                if collections.contains(where: { $0.id == colID }) {
                    return lib.id
                }
            }
            return nil
        case .scixLibrary(let libID):
            return libID
        case .flagged:
            return RustStoreAdapter.shared.getDefaultLibrary()?.id
        case .citedInManuscripts:
            // Cross-library pseudo source — no owning library.
            return nil
        default:
            return nil
        }
    }

    /// Derive the ListViewID from current section for state persistence
    private var currentListID: ListViewID? {
        switch selectedSection {
        case .inbox:
            return RustStoreAdapter.shared.getInboxLibrary().map { .library($0.id) }
        case .inboxCollection(let colID):
            return .collection(colID)
        case .library(let libraryID):
            return .library(libraryID)
        case .smartSearch(let ssID):
            return .smartSearch(ssID)
        case .collection(let colID):
            return .collection(colID)
        case .scixLibrary(let libID):
            return .scixLibrary(libID)
        case .flagged(let color):
            let source = IOSUnifiedPublicationListWrapper.Source.flagged(color)
            return .flagged(source.id)
        case .citedInManuscripts:
            return .library(UUID(uuidString: "00000000-0000-0000-AAAA-000000000004")!)
        default:
            return nil
        }
    }

    /// Compute the current search context based on view state
    private var currentSearchContext: SearchContext {
        // If viewing a publication, context depends on active tab
        if let pubID = selectedPublicationID {
            let store = RustStoreAdapter.shared
            let pub = store.getPublication(id: pubID)
            let title = pub?.title ?? "Publication"
            if activeDetailTab == .pdf {
                return .pdf(pubID, title)
            }
            return .publication(pubID, title)
        }

        // Otherwise, context is based on selected section
        switch selectedSection {
        case .library(let libraryID):
            let name = RustStoreAdapter.shared.getLibrary(id: libraryID)?.name ?? "Library"
            return .library(libraryID, name)

        case .collection(let colID):
            return .collection(colID, "Collection")

        case .smartSearch(let ssID):
            let name = RustStoreAdapter.shared.getSmartSearch(id: ssID)?.name ?? "Search"
            return .smartSearch(ssID, name)

        case .scixLibrary(let libID):
            return .library(libID, "SciX Library")

        case .inboxCollection(let colID):
            return .collection(colID, "Collection")

        case .inbox, .search, .searchForm, .flagged, .citedInManuscripts, .manuscripts, .none:
            return .global
        }
    }

    // MARK: - Navigation

    /// Navigate to a specific publication from global search.
    private func navigateToPublication(_ publicationID: UUID) {
        let store = RustStoreAdapter.shared
        guard let pub = store.getPublication(id: publicationID) else {
            contentLogger.warning("Cannot navigate to publication \(publicationID): not found")
            return
        }

        // Find the library containing this publication
        if let detail = store.getPublicationDetail(id: publicationID),
           let firstLibID = detail.libraryIDs.first {
            selectedSection = .library(firstLibID)
        } else {
            contentLogger.warning("Publication \(pub.citeKey) not in any library")
            return
        }

        // Select the publication after a brief delay to let the list load
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            selectedPublicationID = publicationID
        }

        contentLogger.info("Navigated to publication: \(pub.citeKey)")
    }

    /// Re-enrich the currently selected publication (⇧⌘R). Queues a fresh
    /// metadata-resolve pass through the same EnrichmentCoordinator the app uses
    /// on launch. No-op when nothing is selected.
    private func reEnrichSelectedPublication() {
        guard let pubID = selectedPublicationID else {
            contentLogger.info("Re-enrich requested but no publication selected")
            return
        }
        contentLogger.info("Re-enrich requested for publication \(pubID)")
        Task {
            await EnrichmentCoordinator.shared.queueForEnrichment(
                publicationID: pubID,
                priority: .userTriggered
            )
        }
    }

    // MARK: - Import

    private func importPreviewEntries(_ entries: [ImportPreviewEntry]) async throws -> Int {
        var count = 0

        for entry in entries {
            switch entry.source {
            case .bibtex(let bibtex):
                await libraryViewModel.importEntry(bibtex)
                count += 1

            case .ris(let ris):
                let bibtex = RISBibTeXConverter.toBibTeX(ris)
                await libraryViewModel.importEntry(bibtex)
                count += 1
            }
        }

        await libraryViewModel.loadPublications()
        return count
    }
}

// MARK: - BibTeX Document (for export)

struct BibTeXDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "bib") ?? .plainText] }

    var content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            content = String(data: data, encoding: .utf8) ?? ""
        } else {
            content = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Sidebar Section

/// Sidebar navigation targets using UUIDs and value types only (no Core Data).
enum SidebarSection: Hashable {
    case inbox
    case inboxCollection(UUID)        // Collection ID
    case library(UUID)                // Library ID
    case search                       // Legacy, kept for compatibility
    case searchForm(SearchFormType)   // Specific search form
    case smartSearch(UUID)            // SmartSearch ID
    case collection(UUID)             // Collection ID
    case scixLibrary(UUID)            // SciXLibrary ID
    case flagged(String?)             // Flagged publications (nil = any flag, or specific color name)
    case citedInManuscripts           // Papers cited in any imprint manuscript
    case manuscripts                  // All manuscripts (manuscript@1.0.0 items)
}

// MARK: - iOS Search View

struct IOSSearchView: View {
    @Binding var selectedPublicationID: UUID?

    /// Optional initial query (e.g., from category chip tap)
    var initialQuery: String?

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(LibraryViewModel.self) private var libraryViewModel

    @State private var searchText = ""
    @State private var multiSelection = Set<UUID>()
    @State private var hasAppliedInitialQuery = false
    @State private var availableSources: [SourceMetadata] = []
    @State private var isSearchBarExpanded = true
    @FocusState private var isSearchFieldFocused: Bool

    /// Rows for the last online search. ADR-016 auto-imports deduped results
    /// into the Exploration library and `SearchViewModel` no longer keeps a
    /// `.publications` array — it exposes `lastImportedPublicationIDs` instead.
    /// We hydrate those IDs into row data via `RustStoreAdapter.getPublication(id:)`
    /// (the same row shape the revived list wrapper renders), refreshed after
    /// each search completes and on `store.dataVersion` bumps (async enrichment).
    @State private var searchResults: [PublicationRowData] = []

    var body: some View {
        VStack(spacing: 0) {
            // Search bar section - stays pinned at top regardless of keyboard
            VStack(spacing: 0) {
                // Collapsed search bar (shows when results are displayed and search bar is collapsed)
                if !isSearchBarExpanded && !searchResults.isEmpty {
                    collapsedSearchBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }

                // Expanded search bar - stays at fixed position
                if isSearchBarExpanded {
                    searchBar
                        .padding()
                }

                // Source filter chips
                if !availableSources.isEmpty && isSearchBarExpanded {
                    sourceFilterBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }

                Divider()
            }
            .background(.bar)

            // Results list - keyboard overlays this area without pushing content
            resultsList
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Clear results / Cancel button
            ToolbarItem(placement: .topBarLeading) {
                if !searchResults.isEmpty {
                    Button("Clear") {
                        searchText = ""
                        searchViewModel.query = ""
                        searchResults = []
                        multiSelection.removeAll()
                        isSearchBarExpanded = true
                    }
                }
            }
            // Send to Inbox button
            ToolbarItem(placement: .topBarTrailing) {
                if !multiSelection.isEmpty {
                    Button {
                        sendSelectedToInbox()
                    } label: {
                        Label("Send to Inbox", systemImage: "tray.and.arrow.down")
                    }
                }
            }
        }
        .task {
            availableSources = await searchViewModel.availableSources
            // Ensure SearchViewModel has access to LibraryManager
            searchViewModel.setLibraryManager(libraryManager)
        }
        .onAppear {
            applyInitialQueryIfNeeded()
        }
        .onChange(of: initialQuery) { _, newValue in
            if newValue != nil {
                hasAppliedInitialQuery = false
                applyInitialQueryIfNeeded()
            }
        }
        .onChange(of: RustStoreAdapter.shared.dataVersion) { _, _ in
            // Async enrichment/indexing after import mutates rows — re-hydrate.
            guard !searchViewModel.lastImportedPublicationIDs.isEmpty else { return }
            refreshSearchResults()
        }
    }

    // MARK: - Collapsed Search Bar

    private var collapsedSearchBar: some View {
        Button {
            isSearchBarExpanded = true
            isSearchFieldFocused = true
        } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(searchText.isEmpty ? "Search..." : searchText)
                    .foregroundStyle(searchText.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search...", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    performSearch()
                }
                .accessibilityIdentifier(AccessibilityID.Search.searchField)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchViewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Search.clearButton)
            }

            Button("Search") {
                performSearch()
            }
            .buttonStyle(.borderedProminent)
            .disabled(searchText.isEmpty)
            .accessibilityIdentifier(AccessibilityID.Search.searchButton)
        }
    }

    // MARK: - Source Filter Bar

    private var sourceFilterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(availableSources, id: \.id) { source in
                    IOSSourceChip(
                        source: source,
                        isSelected: searchViewModel.selectedSourceIDs.contains(source.id)
                    ) {
                        searchViewModel.toggleSource(source.id)
                    }
                }

                Divider()
                    .frame(height: 20)

                Button("All") {
                    Task {
                        await searchViewModel.selectAllSources()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        if searchViewModel.isSearching {
            ProgressView("Searching...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            ContentUnavailableView(
                "Search Online",
                systemImage: "magnifyingglass",
                description: Text("Search arXiv, ADS, Crossref, and more")
            )
        } else {
            List(searchResults, id: \.id, selection: $multiSelection) { publication in
                VStack(alignment: .leading, spacing: 4) {
                    Text(publication.title ?? "Untitled")
                        .font(.headline)
                        .lineLimit(2)
                    Text(publication.authorString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let year = publication.year, year > 0 {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Actions

    private func applyInitialQueryIfNeeded() {
        guard !hasAppliedInitialQuery, let query = initialQuery, !query.isEmpty else { return }
        hasAppliedInitialQuery = true
        searchText = query
        performSearch()
    }

    private func performSearch() {
        guard !searchText.isEmpty else { return }
        searchViewModel.query = searchText

        // Dismiss keyboard
        isSearchFieldFocused = false

        // Collapse search bar after search
        isSearchBarExpanded = false

        Task {
            await searchViewModel.search()
            refreshSearchResults()
        }
    }

    /// Hydrate row data for the last search's imported/deduped publications.
    ///
    /// ADR-016 imports results into the Exploration library; we resolve the
    /// view model's `lastImportedPublicationIDs` into `PublicationRowData`
    /// via the same store accessor the list wrapper uses.
    private func refreshSearchResults() {
        let store = RustStoreAdapter.shared
        let ids = searchViewModel.lastImportedPublicationIDs
        searchResults = ids.compactMap { store.getPublication(id: $0) }
        Logger.search.infoCapture(
            "iOS search results hydrated: \(searchResults.count)/\(ids.count) rows",
            category: "search"
        )
    }

    private func sendSelectedToInbox() {
        guard !multiSelection.isEmpty else { return }

        let inboxManager = InboxManager.shared

        // Add selected publications to Inbox
        for id in multiSelection {
            inboxManager.addToInbox(id)
        }

        // Clear selection after sending
        multiSelection.removeAll()
    }
}

// MARK: - iOS Source Chip

struct IOSSourceChip: View {
    let source: SourceMetadata
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: source.iconName)
                    .font(.caption)
                Text(source.name)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iOS Keyboard Shortcut Buttons

/// Hidden buttons that provide keyboard shortcuts on iPad with external keyboard.
/// These are invisible but respond to keyboard shortcuts.
struct KeyboardShortcutButtons: View {
    @Binding var showImportPicker: Bool
    @Binding var showExportPicker: Bool
    /// Detail/secondary-column visibility toggled by ⌘0 (UniversalShortcut.toggleSecondaryPane).
    @Binding var columnVisibility: NavigationSplitViewVisibility
    /// Settings sheet presentation, opened by ⌘, (standard iPad convention).
    @Binding var showSettings: Bool
    /// Keyboard-shortcuts help sheet, opened by ⌘/ (UniversalShortcut.shortcutsHelp).
    @Binding var showShortcutsHelp: Bool
    let onLocalFind: () -> Void
    let onOnlineSourceSearch: () -> Void
    /// Re-enrich the selected paper (⇧⌘R). No-op when nothing is selected.
    let onReEnrichSelection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Import (Cmd+I)
            Button("Import") {
                showImportPicker = true
            }
            .keyboardShortcut("i", modifiers: .command)

            // Export (Cmd+Shift+E)
            Button("Export") {
                showExportPicker = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            // Find in Library (Cmd+F)
            Button("Find in Library", action: onLocalFind)
                .keyboardShortcut("f", modifiers: .command)

            // Search Online Sources (Cmd+S)
            Button("Search Online Sources", action: onOnlineSourceSearch)
                .keyboardShortcut("s", modifiers: .command)

            // Show Library (Cmd+1)
            Button("Library") {
                NotificationCenter.default.post(name: .showLibrary, object: nil)
            }
            .keyboardShortcut("1", modifiers: .command)

            // Show Search (Cmd+2)
            Button("Search") {
                NotificationCenter.default.post(name: .showSearch, object: nil)
            }
            .keyboardShortcut("2", modifiers: .command)

            // Show Inbox (Cmd+3)
            Button("Inbox") {
                NotificationCenter.default.post(name: .showInbox, object: nil)
            }
            .keyboardShortcut("3", modifiers: .command)

            // Toggle Read/Unread (Cmd+Shift+U)
            Button("Toggle Read") {
                NotificationCenter.default.post(name: .toggleReadStatus, object: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])

            // Open Notes (Cmd+R) - if a publication is selected
            Button("Notes") {
                NotificationCenter.default.post(name: .showNotesTab, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            // PDF Tab (Cmd+4)
            Button("PDF") {
                NotificationCenter.default.post(name: .showPDFTab, object: nil)
            }
            .keyboardShortcut("4", modifiers: .command)

            // BibTeX Tab (Cmd+5)
            Button("BibTeX") {
                NotificationCenter.default.post(name: .showBibTeXTab, object: nil)
            }
            .keyboardShortcut("5", modifiers: .command)

            // Notes Tab (Cmd+6)
            Button("Notes Tab") {
                NotificationCenter.default.post(name: .showNotesTab, object: nil)
            }
            .keyboardShortcut("6", modifiers: .command)

            // Toggle Detail Column (Cmd+0) — shared grammar: UniversalShortcut.toggleSecondaryPane
            Button("Toggle Detail Pane") {
                columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
            }
            .keyboardShortcut(
                UniversalShortcut.toggleSecondaryPane.key,
                modifiers: UniversalShortcut.toggleSecondaryPane.modifiers
            )
            .accessibilityIdentifier("shortcut.toggleDetailPane")

            // Refresh Metadata / Re-enrich selected (Cmd+Shift+R) — no catalog case, literal chord
            Button("Refresh Metadata", action: onReEnrichSelection)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .accessibilityIdentifier("shortcut.refreshMetadata")

            // Keyboard Shortcuts Help (Cmd+/) — shared grammar: UniversalShortcut.shortcutsHelp
            Button("Keyboard Shortcuts") {
                showShortcutsHelp = true
            }
            .keyboardShortcut(
                UniversalShortcut.shortcutsHelp.key,
                modifiers: UniversalShortcut.shortcutsHelp.modifiers
            )
            .accessibilityIdentifier("shortcut.keyboardShortcutsHelp")

            // Open Settings (Cmd+,) — standard iPad convention, no catalog case
            Button("Settings") {
                showSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityIdentifier("shortcut.openSettings")
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Notification Handlers ViewModifier

private struct NotificationHandlers: ViewModifier {
    @Binding var selectedSection: SidebarSection?
    @Binding var showImportPicker: Bool
    @Binding var showExportPicker: Bool
    @Binding var pendingCategorySearch: String?
    @Binding var selectedPublicationID: UUID?
    let libraryManager: LibraryManager
    let libraryViewModel: LibraryViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showLibrary)) { notification in
                if let libraryID = notification.object as? UUID {
                    selectedSection = .library(libraryID)
                } else if let firstLibrary = RustStoreAdapter.shared.listLibraries().first {
                    selectedSection = .library(firstLibrary.id)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSearch)) { _ in
                selectedSection = .search
            }
            .onReceive(NotificationCenter.default.publisher(for: .importBibTeX)) { _ in
                showImportPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportBibTeX)) { _ in
                showExportPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchCategory)) { notification in
                if let category = notification.userInfo?["category"] as? String {
                    pendingCategorySearch = "cat:\(category)"
                    selectedSection = .search
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { notification in
                if let firstPubID = notification.userInfo?["firstPublicationID"] as? UUID {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        selectedPublicationID = firstPubID
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showInbox)) { _ in
                if RustStoreAdapter.shared.getInboxLibrary() != nil {
                    selectedSection = .inbox
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadStatus)) { _ in
                if let pubID = selectedPublicationID {
                    let store = RustStoreAdapter.shared
                    let pub = store.getPublication(id: pubID)
                    store.setRead(ids: [pubID], read: !(pub?.isRead ?? false))
                }
            }
    }
}

// MARK: - File Handlers ViewModifier

private struct FileHandlers: ViewModifier {
    @Binding var showImportPicker: Bool
    @Binding var showExportPicker: Bool
    @Binding var showImportPreview: Bool
    @Binding var importFileURL: URL?
    let importAction: ([ImportPreviewEntry]) async throws -> Int

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [
                    UTType(filenameExtension: "bib") ?? .plainText,
                    UTType(filenameExtension: "ris") ?? .plainText
                ],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        importFileURL = url
                        showImportPreview = true
                    }
                case .failure(let error):
                    Logger(subsystem: "com.imbib.app", category: "content")
                        .error("Import picker error: \(error.localizedDescription)")
                }
            }
            .fileExporter(
                isPresented: $showExportPicker,
                document: BibTeXDocument(content: ""),
                contentType: UTType(filenameExtension: "bib") ?? .plainText,
                defaultFilename: "library.bib"
            ) { result in
                switch result {
                case .success(let url):
                    Logger(subsystem: "com.imbib.app", category: "content")
                        .info("Exported to \(url.path)")
                case .failure(let error):
                    Logger(subsystem: "com.imbib.app", category: "content")
                        .error("Export error: \(error.localizedDescription)")
                }
            }
            .sheet(isPresented: $showImportPreview) {
                if let url = importFileURL {
                    ImportPreviewView(
                        isPresented: $showImportPreview,
                        fileURL: url
                    ) { entries, _, _, _ in
                        try await importAction(entries)
                    }
                }
            }
    }
}

#Preview {
    IOSContentView()
        .environment(LibraryManager())
        .environment(LibraryViewModel())
        .environment(SearchViewModel(
            sourceManager: SourceManager(),
            deduplicationService: DeduplicationService()
        ))
        .environment(SettingsViewModel(
            sourceManager: SourceManager(),
            credentialManager: CredentialManager()
        ))
}
