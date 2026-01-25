//
//  ContentView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import CoreData
import PublicationManagerCore
import OSLog

private let contentLogger = Logger(subsystem: "com.imbib.app", category: "content")

struct ContentView: View {

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var selectedSection: SidebarSection? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Data for import preview sheet (nil = not shown)
    @State private var importPreviewData: ImportPreviewData?
    /// Selected detail tab - persisted across paper changes so PDF tab stays selected
    @State private var selectedDetailTab: DetailTab = .info
    /// Expanded libraries in sidebar - passed as binding for persistence
    @State private var expandedLibraries: Set<UUID> = []
    /// Whether initial state restoration has completed
    @State private var hasRestoredState = false
    /// Single source of truth for selection - supports both single and multi-selection.
    /// Use `selectedPublicationID` computed property to get the primary selection.
    @State private var selectedPublicationIDs = Set<UUID>()

    /// Whether to show search form (true) or results (false) in list pane
    /// Form is shown initially; switches to results after search executes
    @State private var showSearchFormInList: Bool = true

    /// Data for batch PDF download sheet (nil = not shown)
    @State private var batchDownloadData: BatchDownloadData?

    /// Whether to show the global search palette (Cmd+K)
    @State private var showGlobalSearch = false

    /// Whether to show the command palette (Cmd+Shift+P)
    @State private var showCommandPalette = false

    /// Whether to show the onboarding sheet
    @State private var showOnboarding = false

    /// Navigation history for browser-style back/forward
    private var navigationHistory = NavigationHistoryStore.shared

    /// Flag to skip history push when navigating via back/forward
    @State private var isNavigatingViaHistory = false

    // MARK: - Derived Selection

    /// The primary selected publication ID (first of multi-selection).
    /// Derived from `selectedPublicationIDs` - the single source of truth.
    private var selectedPublicationID: UUID? {
        selectedPublicationIDs.first
    }

    /// Binding for components that need to read/write the primary selection.
    /// Maps between single UUID and the Set-based source of truth.
    private var selectedPublicationIDBinding: Binding<UUID?> {
        Binding(
            get: { selectedPublicationIDs.first },
            set: { newID in
                if let id = newID {
                    selectedPublicationIDs = [id]
                } else {
                    selectedPublicationIDs.removeAll()
                }
            }
        )
    }

    /// The publication ID that the detail view should display.
    /// Updated asynchronously after selection to allow list to feel responsive.
    @State private var displayedPublicationID: UUID?

    /// Derive the selected publication for the detail view.
    private var displayedPublication: CDPublication? {
        guard let id = displayedPublicationID else { return nil }
        return libraryViewModel.publication(for: id)
    }

    /// Compute the current search context based on view state.
    /// Used for context-aware global search (Cmd+F).
    private var currentSearchContext: SearchContext {
        // If viewing a publication, context depends on active tab
        if let pubID = displayedPublicationID,
           let pub = displayedPublication {
            if selectedDetailTab == .pdf {
                return .pdf(pubID, pub.title ?? "PDF")
            }
            return .publication(pubID, pub.title ?? "Publication")
        }

        // Otherwise, context is based on selected section
        switch selectedSection {
        case .library(let library):
            return .library(library.id, library.displayName)
        case .collection(let collection):
            return .collection(collection.id, collection.name)
        case .smartSearch(let smartSearch):
            return .smartSearch(smartSearch.id, smartSearch.name)
        case .scixLibrary(let library):
            return .library(library.id, library.name)
        case .inbox, .inboxFeed, .search, .searchForm, .none:
            return .global
        }
    }

    /// Get the selected publications for multi-selection operations (e.g., BibTeX export).
    private var selectedPublications: [CDPublication] {
        selectedPublicationIDs.compactMap { libraryViewModel.publication(for: $0) }
    }

    /// Whether multiple papers are selected.
    private var isMultiSelection: Bool {
        selectedPublicationIDs.count > 1
    }

    /// Create a binding that maps UUID to CDPublication for list views.
    /// Updates list selection immediately, defers detail view for responsive feel.
    private var selectedPublicationBinding: Binding<CDPublication?> {
        Binding(
            get: {
                guard let id = selectedPublicationID else { return nil }
                return libraryViewModel.publication(for: id)
            },
            set: { newPublication in
                let newID = newPublication?.id
                // Only update selection if it's changing the primary selection AND
                // we're not in multi-selection mode. This preserves multi-selection
                // when PublicationListView updates selectedPublication to sync with
                // the first item in the selection.
                if let id = newID {
                    // Only replace selection if the new ID isn't already in the selection
                    // This prevents multi-selection from being cleared when the list view
                    // syncs selectedPublication with the first item of a multi-selection
                    if !selectedPublicationIDs.contains(id) {
                        selectedPublicationIDs = [id]
                    }
                } else {
                    selectedPublicationIDs.removeAll()
                }

                // Defer detail view update - user sees selection change first,
                // then detail view catches up (feels more responsive)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    displayedPublicationID = newID
                }
            }
        )
    }

    // MARK: - Body

    var body: some View {
        let _ = contentLogger.info("⏱ ContentView.body START")
        mainContent
            .modifier(NavigationHandlersModifier(
                selectedSection: $selectedSection,
                showSearchFormInList: $showSearchFormInList,
                displayedPublicationID: $displayedPublicationID,
                selectedPublicationIDs: $selectedPublicationIDs,
                isNavigatingViaHistory: $isNavigatingViaHistory,
                libraryManager: libraryManager,
                searchViewModel: searchViewModel,
                onEditSmartSearch: handleEditSmartSearch,
                onNavigateToSearchSection: handleNavigateToSearchSection,
                onNavigateBack: navigateBack,
                onNavigateForward: navigateForward
            ))
            .modifier(ImportExportHandlersModifier(
                importPreviewData: $importPreviewData,
                onShowImportPanel: showImportPanel,
                onShowExportPanel: showExportPanel
            ))
            .modifier(StateChangeHandlersModifier(
                selectedSection: $selectedSection,
                showSearchFormInList: $showSearchFormInList,
                selectedPublicationIDs: $selectedPublicationIDs,
                displayedPublicationID: $displayedPublicationID,
                selectedDetailTab: $selectedDetailTab,
                expandedLibraries: $expandedLibraries,
                isNavigatingViaHistory: $isNavigatingViaHistory,
                hasRestoredState: $hasRestoredState,
                searchViewModel: searchViewModel,
                libraryViewModel: libraryViewModel,
                navigationHistory: navigationHistory,
                sidebarSelectionStateFrom: sidebarSelectionStateFrom,
                saveAppState: saveAppState
            ))
            #if os(macOS)
            .modifier(WindowManagementHandlersModifier(
                displayedPublicationID: $displayedPublicationID,
                libraryViewModel: libraryViewModel,
                activeLibrary: libraryManager.activeLibrary
            ))
            #endif
            .sheet(item: $importPreviewData) { data in
                importPreviewSheet(for: data)
            }
            .sheet(item: $batchDownloadData) { data in
                PDFBatchDownloadView(publications: data.publications, library: data.library)
            }
            .overlay {
                // Global search overlay - only render when visible to avoid focus issues
                if showGlobalSearch {
                    GlobalSearchPaletteView(
                        isPresented: $showGlobalSearch,
                        onSelect: { publicationID in
                            navigateToPublication(publicationID)
                        },
                        onPDFSearch: handlePDFSearch
                    )
                    .environment(\.searchContext, currentSearchContext)
                }
            }
            .overlay {
                // Command palette overlay - only render when visible
                if showCommandPalette {
                    CommandPaletteView(isPresented: $showCommandPalette)
                }
            }
            .background {
                // Hidden button for Cmd+F global search shortcut
                Button("Global Search") {
                    showGlobalSearch = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
                showCommandPalette = true
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet()
            }
            .task {
                await libraryViewModel.loadPublications()
                await restoreAppState()

                // Check if onboarding should be shown after initial setup
                if OnboardingManager.shared.shouldShowOnboarding {
                    showOnboarding = true
                }
            }
            .onAppear {
                contentLogger.info("⏱ ContentView.onAppear - window visible")

                // Register main window for flip positions feature (works from detached windows too)
                #if os(macOS)
                DispatchQueue.main.async {
                    if let mainWindow = NSApp.mainWindow {
                        DetailWindowController.shared.registerMainWindow(mainWindow)
                    }
                }
                #endif
            }
    }

    /// Main NavigationSplitView content - extracted to reduce body complexity
    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            let _ = contentLogger.info("⏱ SidebarView creating")
            SidebarView(selection: $selectedSection, expandedLibraries: $expandedLibraries)
        } content: {
            let _ = contentLogger.info("⏱ contentList creating")
            contentList
        } detail: {
            detailView
                .id(displayedPublicationID)
                .transaction { $0.animation = nil }
        }
    }

    // MARK: - State Persistence

    /// Restore app state from persistent storage
    private func restoreAppState() async {
        let state = await AppStateStore.shared.state

        // Restore expanded libraries first
        expandedLibraries = state.expandedLibraries

        // Restore detail tab
        if let tab = DetailTab(rawValue: state.selectedDetailTab) {
            selectedDetailTab = tab
        }

        // Restore sidebar selection
        if let sidebarState = state.sidebarSelection {
            selectedSection = sidebarSectionFrom(sidebarState)
        }

        // Restore selected publication (with small delay to let list load)
        if let pubID = state.selectedPublicationID {
            try? await Task.sleep(for: .milliseconds(100))
            if libraryViewModel.publication(for: pubID) != nil {
                selectedPublicationIDs = [pubID]
                displayedPublicationID = pubID
            }
        }

        hasRestoredState = true
        contentLogger.info("Restored app state: section=\(String(describing: selectedSection)), paper=\(selectedPublicationID?.uuidString ?? "none")")
    }

    /// Save current app state to persistent storage
    private func saveAppState() {
        Task {
            let state = AppState(
                sidebarSelection: sidebarSelectionStateFrom(selectedSection),
                selectedPublicationID: selectedPublicationID,
                selectedDetailTab: selectedDetailTab.rawValue,
                expandedLibraries: expandedLibraries
            )
            await AppStateStore.shared.save(state)
        }
    }

    // MARK: - Navigation History

    /// Navigate back in history (Cmd+[)
    func navigateBack() {
        guard let state = navigationHistory.goBack() else { return }
        isNavigatingViaHistory = true
        if let section = sidebarSectionFrom(state) {
            selectedSection = section
        } else {
            // If section is invalid (e.g., collection was deleted), try again
            navigateBack()
        }
    }

    /// Navigate forward in history (Cmd+])
    func navigateForward() {
        guard let state = navigationHistory.goForward() else { return }
        isNavigatingViaHistory = true
        if let section = sidebarSectionFrom(state) {
            selectedSection = section
        } else {
            // If section is invalid (e.g., collection was deleted), try again
            navigateForward()
        }
    }

    /// Handle PDF search - triggers in-PDF search with highlighting.
    /// Called when user submits search while in PDF context.
    private func handlePDFSearch(_ query: String) {
        // Close the search palette
        showGlobalSearch = false
        // Post notification to trigger in-PDF search
        NotificationCenter.default.post(
            name: .pdfSearchRequested,
            object: nil,
            userInfo: ["query": query]
        )
    }

    /// Navigate to a specific publication from global search.
    ///
    /// Finds the library containing the publication and navigates to it.
    func navigateToPublication(_ publicationID: UUID) {
        guard let publication = libraryViewModel.publication(for: publicationID) else {
            contentLogger.warning("Cannot navigate to publication \(publicationID): not found")
            return
        }

        // Find the library containing this publication (check regular libraries first, then SciX)
        if let library = publication.libraries?.first {
            // Navigate to the regular library
            selectedSection = .library(library)
        } else if let scixLibrary = publication.scixLibraries?.first {
            // Navigate to the SciX library
            selectedSection = .scixLibrary(scixLibrary)
        } else {
            contentLogger.warning("Publication \(publication.citeKey) not in any library")
            return
        }

        // Select the publication after a brief delay to let the list load
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            // Set the selection (single source of truth)
            selectedPublicationIDs = [publicationID]
            displayedPublicationID = publicationID

            // Scroll the list view to show the selected publication
            try? await Task.sleep(for: .milliseconds(50))
            NotificationCenter.default.post(name: .scrollToSelection, object: nil)
        }

        contentLogger.info("Navigated to publication: \(publication.citeKey)")
    }

    // MARK: - Notification Handlers

    /// Handle editSmartSearch notification - loads smart search into search form for editing
    private func handleEditSmartSearch(_ notification: NotificationCenter.Publisher.Output) {
        guard let smartSearchID = notification.object as? UUID else { return }

        // Find the smart search
        guard let smartSearch = findSmartSearch(by: smartSearchID) else { return }

        // Load the smart search into the search view model
        searchViewModel.loadSmartSearch(smartSearch)

        // Navigate to the appropriate search form based on detected form type
        let formType: SearchFormType
        switch searchViewModel.editFormType {
        case .classic:
            formType = .adsClassic
        case .modern:
            formType = .adsModern
        case .paper:
            formType = .adsPaper
        case .arxiv:
            formType = .arxivAdvanced
        case .openalex:
            formType = .openalex
        case .vagueMemory:
            formType = .adsVagueMemory
        }

        // Navigate to the search form and show the form in the list pane
        showSearchFormInList = true
        selectedSection = .searchForm(formType)

        contentLogger.info("Editing smart search '\(smartSearch.name)' using \(String(describing: formType)) form")
    }

    /// Handle navigateToSearchSection notification - navigates to default search form
    private func handleNavigateToSearchSection() {
        showSearchFormInList = true
        selectedSection = .searchForm(.adsClassic)  // Default to Classic form
    }

    /// Convert SidebarSelectionState (serializable) to SidebarSection (with Core Data objects)
    private func sidebarSectionFrom(_ state: SidebarSelectionState) -> SidebarSection? {
        switch state {
        case .inbox:
            return .inbox

        case .inboxFeed(let id):
            if let smartSearch = findSmartSearch(by: id) {
                return .inboxFeed(smartSearch)
            }
            return nil

        case .library(let id):
            if let library = libraryManager.libraries.first(where: { $0.id == id }) {
                return .library(library)
            }
            return nil

        case .search:
            return .search

        case .searchForm(let formType):
            return .searchForm(formType)

        case .smartSearch(let id):
            if let smartSearch = findSmartSearch(by: id) {
                return .smartSearch(smartSearch)
            }
            return nil

        case .collection(let id):
            if let collection = findCollection(by: id) {
                return .collection(collection)
            }
            return nil

        case .scixLibrary(let id):
            if let scixLibrary = findSciXLibrary(by: id) {
                return .scixLibrary(scixLibrary)
            }
            return nil
        }
    }

    /// Convert SidebarSection (with Core Data objects) to SidebarSelectionState (serializable UUIDs)
    private func sidebarSelectionStateFrom(_ section: SidebarSection?) -> SidebarSelectionState? {
        guard let section = section else { return nil }

        switch section {
        case .inbox:
            return .inbox
        case .inboxFeed(let smartSearch):
            return .inboxFeed(smartSearch.id)
        case .library(let library):
            return .library(library.id)
        case .search:
            return .search
        case .searchForm(let formType):
            return .searchForm(formType)
        case .smartSearch(let smartSearch):
            return .smartSearch(smartSearch.id)
        case .collection(let collection):
            return .collection(collection.id)
        case .scixLibrary(let scixLibrary):
            return .scixLibrary(scixLibrary.id)
        }
    }

    /// Find a smart search by UUID
    private func findSmartSearch(by id: UUID) -> CDSmartSearch? {
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? PersistenceController.shared.viewContext.fetch(request).first
    }

    /// Find a collection by UUID
    private func findCollection(by id: UUID) -> CDCollection? {
        let request = NSFetchRequest<CDCollection>(entityName: "Collection")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? PersistenceController.shared.viewContext.fetch(request).first
    }

    /// Find a SciX library by UUID
    private func findSciXLibrary(by id: UUID) -> CDSciXLibrary? {
        let request = NSFetchRequest<CDSciXLibrary>(entityName: "SciXLibrary")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? PersistenceController.shared.viewContext.fetch(request).first
    }

    // MARK: - Content List

    @ViewBuilder
    private var contentList: some View {
        switch selectedSection {
        case .inbox:
            // Show all papers in the Inbox library
            if let inboxLibrary = InboxManager.shared.inboxLibrary {
                UnifiedPublicationListWrapper(
                    source: .library(inboxLibrary),
                    selectedPublication: selectedPublicationBinding,
                    selectedPublicationIDs: $selectedPublicationIDs,
                    onDownloadPDFs: handleDownloadPDFs
                )
            } else {
                ContentUnavailableView(
                    "Inbox Empty",
                    systemImage: "tray",
                    description: Text("Add feeds to start discovering papers")
                )
            }

        case .inboxFeed(let smartSearch):
            // Show papers from a specific inbox feed (same as smart search)
            UnifiedPublicationListWrapper(
                source: .smartSearch(smartSearch),
                selectedPublication: selectedPublicationBinding,
                selectedPublicationIDs: $selectedPublicationIDs,
                onDownloadPDFs: handleDownloadPDFs
            )

        case .library(let library):
            UnifiedPublicationListWrapper(
                source: .library(library),
                selectedPublication: selectedPublicationBinding,
                selectedPublicationIDs: $selectedPublicationIDs,
                onDownloadPDFs: handleDownloadPDFs
            )

        case .search:
            SearchResultsListView(selectedPublication: selectedPublicationBinding)

        case .searchForm(let formType):
            // Show form in list pane initially, then results after search executes
            if showSearchFormInList {
                searchFormForListPane(formType: formType)
            } else {
                SearchResultsListView(selectedPublication: selectedPublicationBinding)
            }

        case .smartSearch(let smartSearch):
            UnifiedPublicationListWrapper(
                source: .smartSearch(smartSearch),
                selectedPublication: selectedPublicationBinding,
                selectedPublicationIDs: $selectedPublicationIDs,
                onDownloadPDFs: handleDownloadPDFs
            )

        case .collection(let collection):
            CollectionListView(collection: collection, selection: selectedPublicationBinding, multiSelection: $selectedPublicationIDs)

        case .scixLibrary(let scixLibrary):
            SciXLibraryListView(library: scixLibrary, selection: selectedPublicationBinding, multiSelection: $selectedPublicationIDs)

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
        // Multi-selection on BibTeX tab: show combined BibTeX view
        if isMultiSelection && selectedDetailTab == .bibtex {
            MultiSelectionBibTeXView(
                publications: selectedPublications,
                onDownloadPDFs: {
                    handleDownloadPDFs(selectedPublicationIDs)
                }
            )
            // Force view recreation when selection changes
            .id(selectedPublicationIDs)
        }
        // Guard against deleted Core Data objects - check isDeleted and managedObjectContext
        // DetailView.init is failable and returns nil for deleted publications
        // Uses displayedPublication (deferred) instead of immediate selection for smoother UX
        // In multi-selection mode, show the first selected paper's details (PDF/Info/Notes tabs still work)
        else if let publication = displayedPublication,
           !publication.isDeleted,
           publication.managedObjectContext != nil,
           let libraryID = selectedLibraryID,
           let detail = DetailView(
               publication: publication,
               libraryID: libraryID,
               selectedTab: $selectedDetailTab,
               isMultiSelection: isMultiSelection,
               selectedPublicationIDs: selectedPublicationIDs,
               onDownloadPDFs: { handleDownloadPDFs(selectedPublicationIDs) }
           ) {
            detail
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "doc.text",
                description: Text("Select a publication to view details")
            )
        }
    }

    // MARK: - Search Form for List Pane

    /// Render search form in the list pane (middle column)
    @ViewBuilder
    private func searchFormForListPane(formType: SearchFormType) -> some View {
        switch formType {
        case .adsModern:
            ADSModernSearchFormView()
                .navigationTitle("ADS Modern Search")

        case .adsClassic:
            ADSClassicSearchFormView()
                .navigationTitle("ADS Classic Search")

        case .adsPaper:
            ADSPaperSearchFormView()
                .navigationTitle("ADS Paper Search")

        case .arxivAdvanced:
            ArXivAdvancedSearchFormView()
                .navigationTitle("arXiv Advanced Search")

        case .arxivFeed:
            ArXivFeedFormView(mode: .inboxFeed)
                .navigationTitle("arXiv Feed")

        case .arxivGroupFeed:
            GroupArXivFeedFormView(mode: .inboxFeed)
                .navigationTitle("Group arXiv Feed")

        case .adsVagueMemory:
            VagueMemorySearchFormView()
                .navigationTitle("Vague Memory Search")

        case .openalex:
            OpenAlexSearchFormView()
                .navigationTitle("OpenAlex Search")
        }
    }

    /// Extract library ID from current section selection
    private var selectedLibraryID: UUID? {
        switch selectedSection {
        case .inbox:
            return InboxManager.shared.inboxLibrary?.id
        case .inboxFeed(let smartSearch):
            // Inbox feeds belong to the Inbox library
            return InboxManager.shared.inboxLibrary?.id ?? smartSearch.library?.id
        case .library(let library):
            return library.id
        case .smartSearch(let smartSearch):
            return smartSearch.library?.id
        case .collection(let collection):
            return collection.effectiveLibrary?.id
        case .scixLibrary(let scixLibrary):
            // SciX libraries use their own ID (not a local CDLibrary)
            return scixLibrary.id
        case .search, .searchForm:
            // Search results are imported to the active library's "Last Search" collection
            return libraryManager.activeLibrary?.id
        default:
            return nil
        }
    }

    /// Get the current CDLibrary for batch PDF downloads
    private var currentLibrary: CDLibrary? {
        switch selectedSection {
        case .inbox:
            return InboxManager.shared.inboxLibrary
        case .inboxFeed(let smartSearch):
            return InboxManager.shared.inboxLibrary ?? smartSearch.library
        case .library(let library):
            return library
        case .smartSearch(let smartSearch):
            return smartSearch.library
        case .collection(let collection):
            return collection.effectiveLibrary
        case .search, .searchForm:
            return libraryManager.activeLibrary
        default:
            return nil
        }
    }

    // MARK: - Batch PDF Download

    /// Handle "Download PDFs" context menu action
    private func handleDownloadPDFs(_ ids: Set<UUID>) {
        let publications = ids.compactMap { libraryViewModel.publication(for: $0) }
        guard !publications.isEmpty, let library = currentLibrary else { return }

        contentLogger.info("[BatchDownload] Starting batch download for \(publications.count) papers")
        batchDownloadData = BatchDownloadData(publications: publications, library: library)
    }

    // MARK: - Import/Export

    private func showImportPanel() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "bib")!,
            .init(filenameExtension: "ris")!
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a BibTeX (.bib) or RIS (.ris) file to import"

        if panel.runModal() == .OK, let url = panel.url {
            importPreviewData = ImportPreviewData(fileURL: url, targetLibrary: nil)
        }
        #endif
    }

    /// Create the import preview sheet view (extracted to help compiler type checking)
    @ViewBuilder
    private func importPreviewSheet(for data: ImportPreviewData) -> some View {
        ImportPreviewView(
            isPresented: Binding(
                get: { importPreviewData != nil },
                set: { if !$0 { importPreviewData = nil } }
            ),
            fileURL: data.fileURL,
            preselectedLibrary: data.targetLibrary,
            preferCreateNewLibrary: data.preferCreateNewLibrary
        ) { entries, targetLibrary, newLibraryName, duplicateHandling in
            try await importPreviewEntries(entries, to: targetLibrary, newLibraryName: newLibraryName, duplicateHandling: duplicateHandling)
        }
    }

    private func importPreviewEntries(
        _ entries: [ImportPreviewEntry],
        to targetLibrary: CDLibrary?,
        newLibraryName: String?,
        duplicateHandling: DuplicateHandlingMode
    ) async throws -> Int {
        // Determine which library to import to
        let library: CDLibrary
        if let existingLibrary = targetLibrary {
            library = existingLibrary
        } else if let name = newLibraryName {
            // Create new library
            library = libraryManager.createLibrary(name: name)
            // Switch to the new library
            libraryManager.setActive(library)
        } else {
            // Fallback to active library
            guard let active = libraryManager.activeLibrary else {
                throw ImportError.noLibrarySelected
            }
            library = active
        }

        var count = 0
        let repository = PublicationRepository(persistenceController: .shared)

        for entry in entries {
            // Handle duplicates
            if entry.isDuplicate, let duplicateID = entry.duplicateOfID {
                if duplicateHandling == .replaceWithImported {
                    // Find and update the existing publication
                    if let existingPub = library.publications?.first(where: { $0.id == duplicateID }) {
                        // Update the existing publication with imported data
                        updatePublication(existingPub, from: entry)
                        count += 1
                    }
                }
                // Skip duplicates when mode is .skipDuplicates (they shouldn't be in selected entries anyway)
                continue
            }

            // Create new publication
            let publication: CDPublication
            switch entry.source {
            case .bibtex(let bibtex):
                publication = await repository.create(from: bibtex, in: library)

            case .ris(let ris):
                publication = await repository.create(from: ris, in: library)
            }

            // Add the publication to the target library
            publication.addToLibrary(library)
            count += 1
        }

        // Save after adding all publications to the library
        PersistenceController.shared.save()

        // Reload publications for the library
        await libraryViewModel.loadPublications()

        // Post notification to refresh sidebar
        NotificationCenter.default.post(name: .libraryContentDidChange, object: library)

        return count
    }

    /// Update an existing publication with data from an import entry
    private func updatePublication(_ publication: CDPublication, from entry: ImportPreviewEntry) {
        switch entry.source {
        case .bibtex(let bibtex):
            // Update core fields from BibTeX
            if let title = bibtex.fields["title"] {
                publication.title = title
            }
            if let abstract = bibtex.fields["abstract"] {
                publication.abstract = abstract
            }
            if let doi = bibtex.fields["doi"] {
                publication.doi = doi
            }
            if let year = bibtex.fields["year"], let yearInt = Int16(year) {
                publication.year = yearInt
            }

        case .ris(let ris):
            // Update core fields from RIS
            if let title = ris.title {
                publication.title = title
            }
            if let abstract = ris.abstract {
                publication.abstract = abstract
            }
            if let doi = ris.doi {
                publication.doi = doi
            }
            if let year = ris.year {
                publication.year = Int16(year)
            }
        }

        publication.dateModified = Date()
    }

    private func showExportPanel() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bib")!]
        panel.nameFieldStringValue = "library.bib"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let bibtex = await libraryViewModel.exportAll()
                do {
                    try bibtex.write(to: url, atomically: true, encoding: .utf8)
                    print("Exported to \(url.path)")
                } catch {
                    print("Export failed: \(error)")
                }
            }
        }
        #endif
    }
}

// MARK: - Sidebar Section

enum SidebarSection: Hashable {
    case inbox                         // Inbox - all papers waiting for triage
    case inboxFeed(CDSmartSearch)      // Inbox feed (smart search with feedsToInbox)
    case library(CDLibrary)           // All publications for specific library
    case search                        // Global search (legacy, kept for compatibility)
    case searchForm(SearchFormType)   // Specific search form (ADS Modern, Classic, Paper)
    case smartSearch(CDSmartSearch)   // Smart search (library-scoped via relationship)
    case collection(CDCollection)     // Collection (library-scoped via relationship)
    case scixLibrary(CDSciXLibrary)   // SciX online library
}

// MARK: - Batch Download Data

/// Data for the batch PDF download sheet.
/// Using Identifiable allows sheet(item:) to properly capture the data when shown.
struct BatchDownloadData: Identifiable {
    let id = UUID()
    let publications: [CDPublication]
    let library: CDLibrary
}

/// Data for the import preview sheet.
/// Using Identifiable ensures sheet only shows when we have a valid URL.
struct ImportPreviewData: Identifiable {
    let id = UUID()
    let fileURL: URL
    /// Optional target library (pre-selected when dropping on a library)
    let targetLibrary: CDLibrary?
    /// When true, defaults to "Create new library" (e.g., sidebar-wide drop)
    let preferCreateNewLibrary: Bool

    init(fileURL: URL, targetLibrary: CDLibrary? = nil, preferCreateNewLibrary: Bool = false) {
        self.fileURL = fileURL
        self.targetLibrary = targetLibrary
        self.preferCreateNewLibrary = preferCreateNewLibrary
    }
}

// MARK: - Collection List View

struct CollectionListView: View {
    let collection: CDCollection
    @Binding var selection: CDPublication?
    @Binding var multiSelection: Set<UUID>

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var publications: [CDPublication] = []
    @State private var filterMode: LibraryFilterMode = .all
    @State private var filterScope: FilterScope = .current
    @StateObject private var dropHandler = FileDropHandler()

    // Drop preview sheet state (for list background drops)
    @StateObject private var dragDropCoordinator = DragDropCoordinator.shared
    @State private var showingDropPreview = false
    @State private var dropPreviewTargetLibraryID: UUID?

    // State for duplicate file alert
    @State private var showDuplicateAlert = false
    @State private var duplicateFilename = ""

    // State for triage flash feedback
    @State private var keyboardTriageFlash: (UUID, Color)?

    // MARK: - Computed Properties

    /// Whether this is an exploration collection (in the system Exploration library)
    private var isExplorationCollection: Bool {
        collection.library?.isSystemLibrary == true
    }

    // MARK: - Body

    var body: some View {
        PublicationListView(
            publications: publications,
            selection: $multiSelection,
            selectedPublication: $selection,
            library: collection.effectiveLibrary,
            allLibraries: libraryManager.libraries,
            showImportButton: false,
            showSortMenu: true,
            emptyStateMessage: "No Publications",
            emptyStateDescription: "Drag publications to this collection.",
            listID: .collection(collection.id),
            filterScope: $filterScope,
            onDelete: { ids in
                // Remove from local state FIRST to prevent SwiftUI from rendering deleted objects
                publications.removeAll { ids.contains($0.id) }
                multiSelection.subtract(ids)
                await libraryViewModel.delete(ids: ids)
                refreshPublications()
            },
            onToggleRead: { publication in
                await libraryViewModel.toggleReadStatus(publication)
                refreshPublications()
            },
            onCopy: { ids in
                await libraryViewModel.copyToClipboard(ids)
            },
            onCut: { ids in
                await libraryViewModel.cutToClipboard(ids)
                refreshPublications()
            },
            onPaste: {
                try? await libraryViewModel.pasteFromClipboard()
                refreshPublications()
            },
            onAddToLibrary: { ids, targetLibrary in
                await libraryViewModel.addToLibrary(ids, library: targetLibrary)
                refreshPublications()
            },
            onAddToCollection: { ids, targetCollection in
                await libraryViewModel.addToCollection(ids, collection: targetCollection)
            },
            onRemoveFromAllCollections: { ids in
                await libraryViewModel.removeFromAllCollections(ids)
                refreshPublications()
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
                        in: collection.effectiveLibrary
                    )
                    refreshPublications()
                }
            },
            onListDrop: { providers, target in
                // Handle PDF drop on collection list for import
                Task {
                    let result = await DragDropCoordinator.shared.performDrop(
                        DragDropInfo(providers: providers),
                        target: target
                    )
                    if case .needsConfirmation = result {
                        await MainActor.run {
                            // Extract library ID from target for the preview sheet
                            switch target {
                            case .library(let libraryID):
                                dropPreviewTargetLibraryID = libraryID
                            case .collection(_, let libraryID):
                                dropPreviewTargetLibraryID = libraryID
                            case .inbox, .publication, .newLibraryZone:
                                // Use collection's library as fallback
                                dropPreviewTargetLibraryID = collection.effectiveLibrary?.id
                            }
                            showingDropPreview = true
                        }
                    }
                    refreshPublications()
                }
            }
        )
        .sheet(isPresented: $showingDropPreview) {
            collectionDropPreviewSheetContent
        }
        .navigationTitle(collection.name)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.init("k")) { handleKeepKey() }
        .onKeyPress(.init("d")) { handleDismissKey() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Filter", selection: $filterMode) {
                    Text("All").tag(LibraryFilterMode.all)
                    Text("Unread").tag(LibraryFilterMode.unread)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

        }
        .task(id: collection.id) {
            refreshPublications()
        }
        .onChange(of: filterMode) { _, _ in
            refreshPublications()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleReadStatus)) { _ in
            toggleReadStatusForSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyPublications)) { _ in
            Task { await copySelectedPublications() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cutPublications)) { _ in
            Task { await cutSelectedPublications() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pastePublications)) { _ in
            Task {
                try? await libraryViewModel.pasteFromClipboard()
                refreshPublications()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAllPublications)) { _ in
            selectAllPublications()
        }
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
    }

    // MARK: - Data Refresh

    private func refreshPublications() {
        Task {
            var result: [CDPublication]

            if collection.isSmartCollection {
                // Execute predicate for smart collections
                result = await libraryViewModel.executeSmartCollection(collection)
            } else {
                // For static collections, use direct relationship
                result = Array(collection.publications ?? [])
                    .filter { !$0.isDeleted }
            }

            if filterMode == .unread {
                result = result.filter { !$0.isRead }
            }

            publications = result.sorted { $0.dateAdded > $1.dateAdded }
        }
    }

    // MARK: - Drop Preview Sheet

    /// Drop preview sheet content for collection list drops
    @ViewBuilder
    private var collectionDropPreviewSheetContent: some View {
        if let libraryID = dropPreviewTargetLibraryID {
            DropPreviewSheet(
                preview: $dragDropCoordinator.pendingPreview,
                libraryID: libraryID,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                dropPreviewTargetLibraryID = nil
                refreshPublications()
            }
        } else if let library = collection.effectiveLibrary {
            // Fallback: use collection's library
            DropPreviewSheet(
                preview: $dragDropCoordinator.pendingPreview,
                libraryID: library.id,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                refreshPublications()
            }
        } else {
            VStack {
                Text("No library selected for import")
                    .font(.headline)
                Text("Please select a library first.")
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

    // MARK: - Notification Handlers

    private func selectAllPublications() {
        multiSelection = Set(publications.map { $0.id })
    }

    private func toggleReadStatusForSelected() {
        guard !multiSelection.isEmpty else { return }

        Task {
            // Apple Mail behavior: if ANY are unread, mark ALL as read
            // If ALL are read, mark ALL as unread
            await libraryViewModel.smartToggleReadStatus(multiSelection)
            refreshPublications()
        }
    }

    private func copySelectedPublications() async {
        guard !multiSelection.isEmpty else { return }
        await libraryViewModel.copyToClipboard(multiSelection)
    }

    private func cutSelectedPublications() async {
        guard !multiSelection.isEmpty else { return }
        await libraryViewModel.cutToClipboard(multiSelection)
        refreshPublications()
    }

    // MARK: - Helpers

    private func openPDF(for publication: CDPublication) {
        // Check user preference for opening PDFs
        let openExternally = UserDefaults.standard.bool(forKey: "openPDFInExternalViewer")

        if openExternally {
            // Open in external viewer (Preview, Adobe, etc.)
            if let linkedFiles = publication.linkedFiles,
               let pdfFile = linkedFiles.first(where: { $0.isPDF }),
               let libraryURL = collection.effectiveLibrary?.folderURL {
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

    // MARK: - Exploration Triage Handlers

    /// Handle 'K' key - keep selected to default library (exploration collections only)
    private func handleKeepKey() -> KeyPress.Result {
        guard isExplorationCollection, !multiSelection.isEmpty else { return .ignored }
        keepSelectedToLibrary()
        return .handled
    }

    /// Handle 'D' key - dismiss/remove from exploration collection
    private func handleDismissKey() -> KeyPress.Result {
        guard isExplorationCollection, !multiSelection.isEmpty else { return .ignored }
        removeSelectedFromExploration()
        return .handled
    }

    /// Keep selected publications to the Keep library
    private func keepSelectedToLibrary() {
        let keepLibrary = libraryManager.getOrCreateKeepLibrary()
        let ids = multiSelection
        guard let firstID = ids.first else { return }

        // Show green flash for keep action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .green)
        }

        // Compute next selection before removal
        let nextID = computeNextSelection(removing: ids)

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }
            }

            // Add to Keep library and remove from exploration collection
            let pubs = publications.filter { ids.contains($0.id) }
            await MainActor.run {
                for pub in pubs {
                    pub.addToLibrary(keepLibrary)
                    pub.removeFromCollection(collection)
                }
                try? PersistenceController.shared.viewContext.save()

                if let nextID {
                    multiSelection = [nextID]
                    selection = publications.first { $0.id == nextID }
                } else {
                    multiSelection = []
                    selection = nil
                }
                refreshPublications()
            }
        }
    }

    /// Remove selected publications from the exploration collection
    private func removeSelectedFromExploration() {
        let ids = multiSelection
        guard let firstID = ids.first else { return }

        // Show orange flash for dismiss action
        withAnimation(.easeIn(duration: 0.1)) {
            keyboardTriageFlash = (firstID, .orange)
        }

        // Compute next selection before removal
        let nextID = computeNextSelection(removing: ids)

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.1)) {
                    keyboardTriageFlash = nil
                }
            }

            // Remove from exploration collection
            let pubs = publications.filter { ids.contains($0.id) }
            await MainActor.run {
                for pub in pubs {
                    pub.removeFromCollection(collection)
                }
                try? PersistenceController.shared.viewContext.save()

                if let nextID {
                    multiSelection = [nextID]
                    selection = publications.first { $0.id == nextID }
                } else {
                    multiSelection = []
                    selection = nil
                }
                refreshPublications()
            }
        }
    }

    /// Compute the next selection ID after removing the given IDs
    private func computeNextSelection(removing ids: Set<UUID>) -> UUID? {
        // Find the current position of the first selected item
        guard let firstSelectedID = ids.first,
              let currentIndex = publications.firstIndex(where: { $0.id == firstSelectedID }) else {
            return nil
        }

        // Find the next item that isn't being removed
        for i in (currentIndex + 1)..<publications.count {
            if !ids.contains(publications[i].id) {
                return publications[i].id
            }
        }

        // If no next item, try previous
        for i in (0..<currentIndex).reversed() {
            if !ids.contains(publications[i].id) {
                return publications[i].id
            }
        }

        return nil
    }
}

// MARK: - Navigation Handlers ViewModifier

/// ViewModifier for navigation-related notification handlers.
/// Extracted to reduce ContentView.body complexity for the Swift type checker.
struct NavigationHandlersModifier: ViewModifier {
    @Binding var selectedSection: SidebarSection?
    @Binding var showSearchFormInList: Bool
    @Binding var displayedPublicationID: UUID?
    @Binding var selectedPublicationIDs: Set<UUID>
    @Binding var isNavigatingViaHistory: Bool
    let libraryManager: LibraryManager
    let searchViewModel: SearchViewModel
    let onEditSmartSearch: (Notification) -> Void
    let onNavigateToSearchSection: () -> Void
    let onNavigateBack: () -> Void
    let onNavigateForward: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showLibrary)) { notification in
                if let library = notification.object as? CDLibrary {
                    selectedSection = .library(library)
                } else if let firstLibrary = libraryManager.libraries.first {
                    selectedSection = .library(firstLibrary)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSearch)) { _ in
                selectedSection = .search
            }
            .onReceive(NotificationCenter.default.publisher(for: .resetSearchFormView)) { _ in
                showSearchFormInList = true
                displayedPublicationID = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { notification in
                if let firstPubID = notification.userInfo?["firstPublicationID"] as? UUID {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        selectedPublicationIDs = [firstPubID]
                        displayedPublicationID = firstPubID
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSmartSearch)) { notification in
                guard let smartSearchID = notification.object as? UUID else { return }
                if let explorationLib = libraryManager.explorationLibrary,
                   let smartSearch = explorationLib.smartSearches?.first(where: { $0.id == smartSearchID }) {
                    isNavigatingViaHistory = true
                    selectedSection = .smartSearch(smartSearch)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .editSmartSearch)) { notification in
                onEditSmartSearch(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSearchSection)) { _ in
                onNavigateToSearchSection()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateBack)) { _ in
                onNavigateBack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateForward)) { _ in
                onNavigateForward()
            }
    }
}

// MARK: - Import/Export Handlers ViewModifier

/// ViewModifier for import/export notification handlers.
struct ImportExportHandlersModifier: ViewModifier {
    @Binding var importPreviewData: ImportPreviewData?
    let onShowImportPanel: () -> Void
    let onShowExportPanel: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .importBibTeX)) { _ in
                onShowImportPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importBibTeXToLibrary)) { notification in
                guard let fileURL = notification.userInfo?["fileURL"] as? URL else { return }
                let library = notification.userInfo?["library"] as? CDLibrary
                let preferCreateNew = library == nil
                importPreviewData = ImportPreviewData(fileURL: fileURL, targetLibrary: library, preferCreateNewLibrary: preferCreateNew)
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportBibTeX)) { _ in
                onShowExportPanel()
            }
    }
}

// MARK: - State Change Handlers ViewModifier

/// ViewModifier for state change handlers (onChange modifiers).
struct StateChangeHandlersModifier: ViewModifier {
    @Binding var selectedSection: SidebarSection?
    @Binding var showSearchFormInList: Bool
    @Binding var selectedPublicationIDs: Set<UUID>
    @Binding var displayedPublicationID: UUID?
    @Binding var selectedDetailTab: DetailTab
    @Binding var expandedLibraries: Set<UUID>
    @Binding var isNavigatingViaHistory: Bool
    @Binding var hasRestoredState: Bool
    let searchViewModel: SearchViewModel
    let libraryViewModel: LibraryViewModel
    let navigationHistory: NavigationHistoryStore
    let sidebarSelectionStateFrom: (SidebarSection?) -> SidebarSelectionState?
    let saveAppState: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedSection) { oldValue, newValue in
                if oldValue != newValue {
                    if case .searchForm = newValue {
                        showSearchFormInList = true
                        // Only clear selection when navigating to search form
                        selectedPublicationIDs.removeAll()
                        displayedPublicationID = nil
                    }
                    // Don't clear selection for normal section navigation

                    if !isNavigatingViaHistory {
                        if let state = sidebarSelectionStateFrom(newValue) {
                            navigationHistory.push(state)
                        }
                    }
                    isNavigatingViaHistory = false
                }
                if hasRestoredState {
                    saveAppState()
                }
            }
            .onChange(of: searchViewModel.isSearching) { wasSearching, isSearching in
                if wasSearching && !isSearching {
                    showSearchFormInList = false
                }
            }
            .onChange(of: selectedPublicationIDs) { _, newIDs in
                // Only save state, don't validate here - validation during Core Data
                // background merges can incorrectly clear selection when managedObjectContext
                // is temporarily nil. Let the list view handle showing valid items.
                if hasRestoredState {
                    saveAppState()
                }
            }
            .onChange(of: selectedDetailTab) { _, _ in
                if hasRestoredState {
                    saveAppState()
                }
            }
            .onChange(of: expandedLibraries) { _, _ in
                if hasRestoredState {
                    saveAppState()
                }
            }
    }
}

#if os(macOS)
// MARK: - Window Management Handlers ViewModifier

/// ViewModifier for dual-monitor and window management notification handlers.
struct WindowManagementHandlersModifier: ViewModifier {
    @Binding var displayedPublicationID: UUID?
    let libraryViewModel: LibraryViewModel
    let activeLibrary: CDLibrary?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .detachPDFTab)) { _ in
                openDetachedTab(.pdf)
            }
            .onReceive(NotificationCenter.default.publisher(for: .detachNotesTab)) { _ in
                openDetachedTab(.notes)
            }
            .onReceive(NotificationCenter.default.publisher(for: .detachBibTeXTab)) { _ in
                openDetachedTab(.bibtex)
            }
            .onReceive(NotificationCenter.default.publisher(for: .detachInfoTab)) { _ in
                openDetachedTab(.info)
            }
            // Note: .flipWindowPositions is handled by DetailWindowController directly
            // so it works from both main window and detached windows
            .onReceive(NotificationCenter.default.publisher(for: .closeDetachedWindows)) { _ in
                guard let pubID = displayedPublicationID,
                      let publication = libraryViewModel.publication(for: pubID) else { return }
                DetailWindowController.shared.closeWindows(for: publication)
            }
    }

    private func openDetachedTab(_ tab: DetachedTab) {
        guard let pubID = displayedPublicationID,
              let publication = libraryViewModel.publication(for: pubID) else { return }
        DetailWindowController.shared.openTab(tab, for: publication, library: activeLibrary)
    }
}
#endif

#Preview {
    ContentView()
        .environment(LibraryManager())
        .environment(LibraryViewModel())
        .environment(SearchViewModel(
            sourceManager: SourceManager(),
            deduplicationService: DeduplicationService(),
            repository: PublicationRepository()
        ))
        .environment(SettingsViewModel(
            sourceManager: SourceManager(),
            credentialManager: CredentialManager()
        ))
}
