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

// MARK: - Focused Pane

/// Represents which pane currently has keyboard focus for vim-style navigation.
/// Used for h/l cycling and j/k per-pane behavior.
enum FocusedPane: String, Hashable, CaseIterable {
    case sidebar
    case list
    case info
    case pdf
    case notes
    case bibtex

    /// All panes in cycle order (same as toolbar tab order for detail tabs)
    static let allPanes: [FocusedPane] = [.sidebar, .list, .info, .pdf, .notes, .bibtex]

    /// Whether this pane is a detail tab (info, pdf, notes, bibtex)
    var isDetailTab: Bool {
        switch self {
        case .info, .pdf, .notes, .bibtex:
            return true
        case .sidebar, .list:
            return false
        }
    }

    /// Convert to DetailTab if this is a detail pane
    var asDetailTab: DetailTab? {
        switch self {
        case .info: return .info
        case .pdf: return .pdf
        case .notes: return .notes
        case .bibtex: return .bibtex
        case .sidebar, .list: return nil
        }
    }

    /// Create from DetailTab
    static func from(_ detailTab: DetailTab) -> FocusedPane {
        switch detailTab {
        case .info: return .info
        case .pdf: return .pdf
        case .notes: return .notes
        case .bibtex: return .bibtex
        }
    }
}

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

    /// Data for unified export sheet (nil = not shown)
    @State private var unifiedExportData: UnifiedExportData?

    /// Data for unified import sheet (nil = not shown)
    @State private var unifiedImportData: UnifiedImportData?

    /// Navigation history for browser-style back/forward
    private var navigationHistory = NavigationHistoryStore.shared

    /// Flag to skip history push when navigating via back/forward
    @State private var isNavigatingViaHistory = false

    /// Centralized focus tracking for vim-style pane navigation (h/l cycling, j/k per-pane)
    /// Using @State instead of @FocusState because we're tracking logical pane focus, not SwiftUI keyboard focus
    @State private var focusedPane: FocusedPane?

    /// Whether to show the stale search index alert
    @State private var showStaleIndexAlert = false

    /// Whether search index rebuild is in progress
    @State private var isRebuildingSearchIndex = false

    /// Feature flag: use new TabView sidebar instead of classic NavigationSplitView
    @AppStorage("useTabSidebar") private var useTabSidebar = false

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
        case .inboxCollection(let collection):
            return .collection(collection.id, collection.name)
        case .inbox, .inboxFeed, .search, .searchForm, .flagged, .none:
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
        if useTabSidebar {
            tabSidebarContent
        } else {
            classicSidebarContent
        }
    }

    /// New TabView-based sidebar (feature flagged)
    private var tabSidebarContent: some View {
        TabContentView()
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet()
            }
            .sheet(item: $batchDownloadData) { data in
                PDFBatchDownloadView(publications: data.publications, library: data.library)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showBatchDownload)) { notification in
                guard let userInfo = notification.userInfo,
                      let publications = userInfo["publications"] as? [CDPublication],
                      let libraryID = userInfo["libraryID"] as? UUID,
                      let library = libraryManager.libraries.first(where: { $0.id == libraryID })
                          ?? libraryManager.sharedWithMeLibraries.first(where: { $0.id == libraryID })
                else { return }
                batchDownloadData = BatchDownloadData(publications: publications, library: library)
            }
            .modifier(ImportExportHandlersModifier(
                importPreviewData: $importPreviewData,
                unifiedExportData: $unifiedExportData,
                unifiedImportData: $unifiedImportData,
                libraryManager: libraryManager,
                selectedPublications: selectedPublications,
                onShowImportPanel: showImportPanel,
                onShowExportPanel: showExportPanel
            ))
            #if os(macOS)
            .modifier(WindowManagementHandlersModifier(
                displayedPublicationID: $displayedPublicationID,
                libraryViewModel: libraryViewModel,
                libraryManager: libraryManager,
                activeLibrary: libraryManager.activeLibrary
            ))
            #endif
            .sheet(item: $importPreviewData) { data in
                importPreviewSheet(for: data)
                    .frame(minWidth: 600, minHeight: 500)
            }
            .sheet(item: $unifiedExportData) { data in
                UnifiedExportView(
                    scope: data.scope,
                    isPresented: Binding(
                        get: { unifiedExportData != nil },
                        set: { if !$0 { unifiedExportData = nil } }
                    )
                )
                .frame(minWidth: 550, minHeight: 450)
            }
            .sheet(item: $unifiedImportData) { data in
                UnifiedImportView(
                    fileURL: data.fileURL,
                    targetLibrary: data.targetLibrary,
                    isPresented: Binding(
                        get: { unifiedImportData != nil },
                        set: { if !$0 { unifiedImportData = nil } }
                    )
                )
                .frame(minWidth: 550, minHeight: 450)
            }
            // Vim-style pane focus cycling (h/l keys)
            .onReceive(NotificationCenter.default.publisher(for: .cycleFocusLeft)) { _ in
                cycleFocusLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cycleFocusRight)) { _ in
                cycleFocusRight()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
                showCommandPalette = true
            }
            .overlay {
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
                if showCommandPalette {
                    CommandPaletteView(isPresented: $showCommandPalette)
                }
            }
            .background {
                Button("Global Search") {
                    showGlobalSearch = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
            }
    }

    /// Classic NavigationSplitView sidebar (existing behavior)
    private var classicSidebarContent: some View {
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
                onOpenArxivSearchWithCategory: handleOpenArxivSearchWithCategory,
                onNavigateBack: navigateBack,
                onNavigateForward: navigateForward
            ))
            .modifier(ImportExportHandlersModifier(
                importPreviewData: $importPreviewData,
                unifiedExportData: $unifiedExportData,
                unifiedImportData: $unifiedImportData,
                libraryManager: libraryManager,
                selectedPublications: selectedPublications,
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
                libraryManager: libraryManager,
                activeLibrary: libraryManager.activeLibrary
            ))
            #endif
            .sheet(item: $importPreviewData) { data in
                importPreviewSheet(for: data)
                    .frame(minWidth: 600, minHeight: 500)
            }
            .sheet(item: $batchDownloadData) { data in
                PDFBatchDownloadView(publications: data.publications, library: data.library)
                    .frame(minWidth: 500, minHeight: 400)
            }
            .sheet(item: $unifiedExportData) { data in
                UnifiedExportView(
                    scope: data.scope,
                    isPresented: Binding(
                        get: { unifiedExportData != nil },
                        set: { if !$0 { unifiedExportData = nil } }
                    )
                )
                .frame(minWidth: 550, minHeight: 450)
            }
            .sheet(item: $unifiedImportData) { data in
                UnifiedImportView(
                    fileURL: data.fileURL,
                    targetLibrary: data.targetLibrary,
                    isPresented: Binding(
                        get: { unifiedImportData != nil },
                        set: { if !$0 { unifiedImportData = nil } }
                    )
                )
                .frame(minWidth: 550, minHeight: 450)
            }
            .overlay {
                // Global search overlay - only render when visible to avoid focus issues
                if showGlobalSearch {
                    GlobalSearchPaletteView(
                        isPresented: $showGlobalSearch,
                        onSelect: { publicationID in
                            print("🔍 [GlobalSearch] onSelect called with ID: \(publicationID)")
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
            // Vim-style pane focus cycling (h/l keys)
            .onReceive(NotificationCenter.default.publisher(for: .cycleFocusLeft)) { _ in
                print("🎯 [VIM] Received cycleFocusLeft, current=\(focusedPane?.rawValue ?? "nil")")
                cycleFocusLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cycleFocusRight)) { _ in
                print("🎯 [VIM] Received cycleFocusRight, current=\(focusedPane?.rawValue ?? "nil")")
                cycleFocusRight()
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet()
            }
            .alert("Paper Not Found", isPresented: $showStaleIndexAlert) {
                Button("Rebuild Index") {
                    rebuildSearchIndex()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This paper may have been deleted. The search index might be out of date. Would you like to rebuild it?")
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
            SidebarView(selection: $selectedSection, expandedLibraries: $expandedLibraries, focusedPane: $focusedPane)
        } content: {
            let _ = contentLogger.info("⏱ contentList creating")
            contentList
                .focusBorder(isFocused: focusedPane == .list)
        } detail: {
            detailView
                .id(displayedPublicationID)
                .transaction { $0.animation = nil }
                .focusBorder(isFocused: [.info, .pdf, .notes, .bibtex].contains(focusedPane))
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

        // Auto-select first paper if nothing was restored (avoids empty detail pane)
        if displayedPublicationID == nil {
            try? await Task.sleep(for: .milliseconds(200))
            if let firstPub = firstPublicationForCurrentSection() {
                selectedPublicationIDs = [firstPub.id]
                displayedPublicationID = firstPub.id
            }
        }

        hasRestoredState = true
        contentLogger.info("Restored app state: section=\(String(describing: selectedSection)), paper=\(selectedPublicationID?.uuidString ?? "none")")
    }

    /// Find the first publication for the currently selected sidebar section.
    /// Used for auto-selecting a paper when no previous selection exists.
    private func firstPublicationForCurrentSection() -> CDPublication? {
        let pubs: Set<CDPublication>?
        switch selectedSection {
        case .library(let library):
            pubs = library.publications
        case .inbox:
            pubs = InboxManager.shared.inboxLibrary?.publications
        case .inboxFeed(let smartSearch):
            pubs = smartSearch.library?.publications
        case .collection(let collection):
            pubs = collection.publications
        case .scixLibrary(let scixLibrary):
            pubs = scixLibrary.publications
        case .smartSearch(let smartSearch):
            pubs = smartSearch.library?.publications
        default:
            pubs = libraryManager.activeLibrary?.publications
        }
        return pubs?
            .filter { !$0.isDeleted && $0.managedObjectContext != nil }
            .sorted { $0.dateAdded > $1.dateAdded }
            .first
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

    // MARK: - Pane Focus Cycling (Vim-style h/l)

    /// Cycle focus to the right (l key): sidebar → list → info → pdf → notes → bibtex → sidebar
    private func cycleFocusRight() {
        guard let current = focusedPane,
              let idx = FocusedPane.allPanes.firstIndex(of: current) else {
            // No current focus - start at sidebar
            print("🎯 [VIM] cycleFocusRight: no current focus, starting at sidebar")
            focusedPane = .sidebar
            return
        }
        let nextPane = FocusedPane.allPanes[(idx + 1) % FocusedPane.allPanes.count]
        print("🎯 [VIM] cycleFocusRight: \(current.rawValue) → \(nextPane.rawValue)")
        setFocusedPane(nextPane)
    }

    /// Cycle focus to the left (h key): bibtex → notes → pdf → info → list → sidebar → bibtex
    private func cycleFocusLeft() {
        guard let current = focusedPane,
              let idx = FocusedPane.allPanes.firstIndex(of: current) else {
            // No current focus - start at bibtex (rightmost)
            print("🎯 [VIM] cycleFocusLeft: no current focus, starting at bibtex")
            focusedPane = .bibtex
            selectedDetailTab = .bibtex
            return
        }
        let prevPane = FocusedPane.allPanes[(idx - 1 + FocusedPane.allPanes.count) % FocusedPane.allPanes.count]
        print("🎯 [VIM] cycleFocusLeft: \(current.rawValue) → \(prevPane.rawValue)")
        setFocusedPane(prevPane)
    }

    /// Set focused pane and switch detail tab if needed (like clicking toolbar button)
    private func setFocusedPane(_ pane: FocusedPane) {
        print("🎯 [VIM] setFocusedPane: \(pane.rawValue), isDetailTab=\(pane.isDetailTab)")
        focusedPane = pane

        // When focusing a detail tab, switch to that tab (same as toolbar buttons)
        if let detailTab = pane.asDetailTab {
            print("🎯 [VIM] Switching to detail tab: \(String(describing: detailTab))")
            selectedDetailTab = detailTab
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
    /// Also expands the library in the sidebar so the user can see which library
    /// contains the paper. Shows an alert if the publication can't be found (stale index).
    func navigateToPublication(_ publicationID: UUID) {
        print("🔍 [Navigate] navigateToPublication called with ID: \(publicationID)")

        guard let publication = libraryViewModel.publication(for: publicationID) else {
            // Publication not found - search index is stale
            print("🔍 [Navigate] Publication NOT FOUND - showing stale index alert")
            contentLogger.warning("Cannot navigate to publication \(publicationID): not found (stale index)")
            showStaleIndexAlert = true
            return
        }

        print("🔍 [Navigate] Found publication: \(publication.citeKey)")
        print("🔍 [Navigate] Libraries count: \(publication.libraries?.count ?? 0)")
        print("🔍 [Navigate] SciX libraries count: \(publication.scixLibraries?.count ?? 0)")

        // Find the library containing this publication (check regular libraries first, then SciX)
        if let library = publication.libraries?.first {
            print("🔍 [Navigate] Navigating to library: \(library.displayName)")
            // Navigate to the regular library
            selectedSection = .library(library)
            // Expand the library in the sidebar so it's visible and the user can see
            // which library contains the paper
            expandedLibraries.insert(library.id)
            print("🔍 [Navigate] Set selectedSection and expanded library")
        } else if let scixLibrary = publication.scixLibraries?.first {
            print("🔍 [Navigate] Navigating to SciX library: \(scixLibrary.name)")
            // Navigate to the SciX library
            selectedSection = .scixLibrary(scixLibrary)
        } else {
            // Publication exists but has no library - also a stale index symptom
            print("🔍 [Navigate] Publication has NO library - showing stale index alert")
            contentLogger.warning("Publication \(publication.citeKey) not in any library (stale index)")
            showStaleIndexAlert = true
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

    /// Rebuild the search indexes (fulltext and semantic) when they become stale.
    private func rebuildSearchIndex() {
        guard !isRebuildingSearchIndex else { return }
        isRebuildingSearchIndex = true

        Task {
            contentLogger.info("Starting search index rebuild...")

            // Rebuild fulltext search index
            await FullTextSearchService.shared.rebuildIndex()

            // Rebuild semantic search index from all libraries
            let libraries = libraryManager.libraries
            await EmbeddingService.shared.buildIndex(from: libraries)

            contentLogger.info("Search index rebuild complete")
            isRebuildingSearchIndex = false
        }
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

    /// Handle openArxivSearchWithCategory notification - opens arXiv search with category pre-filled
    private func handleOpenArxivSearchWithCategory(_ notification: Notification) {
        guard let category = notification.userInfo?["category"] as? String else { return }

        // Navigate to arXiv feed form and pre-fill the category
        showSearchFormInList = true
        selectedSection = .searchForm(.arxivFeed)

        // Post a notification to pre-fill the category in the arXiv form
        // The form will handle parsing "cat:astro-ph" into category selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: .prefillArxivCategory,
                object: nil,
                userInfo: ["category": category]
            )
        }
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

        case .inboxCollection(let id):
            if let collection = findCollection(by: id) {
                return .inboxCollection(collection)
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

        case .flagged(let color):
            return .flagged(color)
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
        case .inboxCollection(let collection):
            return .inboxCollection(collection.id)
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
        case .flagged(let color):
            return .flagged(color)
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

        case .inboxCollection(let collection):
            // Show papers in an Inbox collection
            UnifiedPublicationListWrapper(
                source: .collection(collection),
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
            // ADR-016: Search results displayed via UnifiedPublicationListWrapper using Last Search collection
            if let lastSearchCollection = libraryManager.activeLibrary?.lastSearchCollection {
                UnifiedPublicationListWrapper(
                    source: .lastSearch(lastSearchCollection),
                    selectedPublication: selectedPublicationBinding,
                    selectedPublicationIDs: $selectedPublicationIDs,
                    onDownloadPDFs: handleDownloadPDFs
                )
            } else {
                ContentUnavailableView(
                    "No Active Library",
                    systemImage: "magnifyingglass",
                    description: Text("Select a library to search within")
                )
            }

        case .searchForm(let formType):
            // Show form in list pane initially, then results after search executes
            if showSearchFormInList {
                searchFormForListPane(formType: formType)
            } else {
                // ADR-016: Search results displayed via UnifiedPublicationListWrapper
                if let lastSearchCollection = libraryManager.activeLibrary?.lastSearchCollection {
                    UnifiedPublicationListWrapper(
                        source: .lastSearch(lastSearchCollection),
                        selectedPublication: selectedPublicationBinding,
                        selectedPublicationIDs: $selectedPublicationIDs,
                        onDownloadPDFs: handleDownloadPDFs
                    )
                } else {
                    ContentUnavailableView(
                        "No Active Library",
                        systemImage: "magnifyingglass",
                        description: Text("Select a library to search within")
                    )
                }
            }

        case .smartSearch(let smartSearch):
            UnifiedPublicationListWrapper(
                source: .smartSearch(smartSearch),
                selectedPublication: selectedPublicationBinding,
                selectedPublicationIDs: $selectedPublicationIDs,
                onDownloadPDFs: handleDownloadPDFs
            )

        case .collection(let collection):
            UnifiedPublicationListWrapper(
                source: .collection(collection),
                selectedPublication: selectedPublicationBinding,
                selectedPublicationIDs: $selectedPublicationIDs,
                onDownloadPDFs: handleDownloadPDFs
            )

        case .scixLibrary(let scixLibrary):
            SciXLibraryListView(library: scixLibrary, selection: selectedPublicationBinding, multiSelection: $selectedPublicationIDs)

        case .flagged(let color):
            UnifiedPublicationListWrapper(
                source: .flagged(color),
                selectedPublication: selectedPublicationBinding,
                selectedPublicationIDs: $selectedPublicationIDs,
                onDownloadPDFs: handleDownloadPDFs
            )

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
                .navigationTitle("SciX Search")

        case .adsClassic:
            ADSClassicSearchFormView()
                .navigationTitle("ADS Classic Search")

        case .adsPaper:
            ADSPaperSearchFormView()
                .navigationTitle("SciX Paper Search")

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
            OpenAlexEnhancedSearchFormView()
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
        case .inboxCollection:
            // Inbox collections belong to the Inbox library
            return InboxManager.shared.inboxLibrary?.id
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
        case .flagged:
            // Flagged is cross-library; use active library for detail view
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
        case .inboxCollection:
            return InboxManager.shared.inboxLibrary
        case .library(let library):
            return library
        case .smartSearch(let smartSearch):
            return smartSearch.library
        case .collection(let collection):
            return collection.effectiveLibrary
        case .search, .searchForm, .flagged:
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
            try await importPreviewEntries(entries, to: targetLibrary, newLibraryName: newLibraryName, duplicateHandling: duplicateHandling, collection: data.targetCollection)
        }
    }

    private func importPreviewEntries(
        _ entries: [ImportPreviewEntry],
        to targetLibrary: CDLibrary?,
        newLibraryName: String?,
        duplicateHandling: DuplicateHandlingMode,
        collection: CDCollection? = nil
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

        var importedPublications: [CDPublication] = []
        let repository = PublicationRepository(persistenceController: .shared)

        // Separate duplicate-replace entries from new entries for batching
        var newBibTeXEntries: [BibTeXEntry] = []
        for entry in entries {
            if entry.isDuplicate, let duplicateID = entry.duplicateOfID {
                if duplicateHandling == .replaceWithImported {
                    if let existingPub = library.publications?.first(where: { $0.id == duplicateID }) {
                        updatePublication(existingPub, from: entry)
                        importedPublications.append(existingPub)
                    }
                }
                continue
            }

            // Collect all new entries as BibTeX (RIS is converted internally)
            switch entry.source {
            case .bibtex(let bibtex):
                newBibTeXEntries.append(bibtex)
            case .ris(let ris):
                newBibTeXEntries.append(RISBibTeXConverter.toBibTeX(ris))
            }
        }

        // Batch-create all new publications in a single Core Data transaction
        if !newBibTeXEntries.isEmpty {
            let created = await repository.importEntriesReturningPublications(newBibTeXEntries, in: library)
            importedPublications.append(contentsOf: created)
        }

        // If a target collection was specified, add all imported publications to it
        if let collection, !collection.isSmartCollection, !collection.isDeleted {
            let pubSet = collection.mutableSetValue(forKey: "publications")
            for pub in importedPublications {
                pubSet.add(pub)
            }
        }

        // Save collection assignments and duplicate updates
        PersistenceController.shared.save()
        let count = importedPublications.count

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
    case inboxCollection(CDCollection) // Collection within Inbox (for organizing feeds)
    case library(CDLibrary)           // All publications for specific library
    case search                        // Global search (legacy, kept for compatibility)
    case searchForm(SearchFormType)   // Specific search form (ADS Modern, Classic, Paper)
    case smartSearch(CDSmartSearch)   // Smart search (library-scoped via relationship)
    case collection(CDCollection)     // Collection (library-scoped via relationship)
    case scixLibrary(CDSciXLibrary)   // SciX online library
    case flagged(String?)              // Flagged publications (nil = any flag, or specific color name)
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
    /// Optional target collection (when dropping on a collection row)
    let targetCollection: CDCollection?
    /// When true, defaults to "Create new library" (e.g., sidebar-wide drop)
    let preferCreateNewLibrary: Bool

    init(fileURL: URL, targetLibrary: CDLibrary? = nil, targetCollection: CDCollection? = nil, preferCreateNewLibrary: Bool = false) {
        self.fileURL = fileURL
        self.targetLibrary = targetLibrary
        self.targetCollection = targetCollection
        self.preferCreateNewLibrary = preferCreateNewLibrary
    }
}

/// Data for the unified export sheet.
struct UnifiedExportData: Identifiable {
    let id = UUID()
    let scope: ExportScope
}

/// Data for the unified import sheet.
struct UnifiedImportData: Identifiable {
    let id = UUID()
    /// Optional file URL (nil = show file picker)
    let fileURL: URL?
    /// Optional target library for import
    let targetLibrary: CDLibrary?

    init(fileURL: URL? = nil, targetLibrary: CDLibrary? = nil) {
        self.fileURL = fileURL
        self.targetLibrary = targetLibrary
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
    let onOpenArxivSearchWithCategory: (Notification) -> Void
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
            .onReceive(NotificationCenter.default.publisher(for: .openArxivSearchWithCategory)) { notification in
                onOpenArxivSearchWithCategory(notification)
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
    @Binding var unifiedExportData: UnifiedExportData?
    @Binding var unifiedImportData: UnifiedImportData?
    let libraryManager: LibraryManager
    let selectedPublications: [CDPublication]
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
                let collection = notification.userInfo?["collection"] as? CDCollection
                let preferCreateNew = library == nil
                importPreviewData = ImportPreviewData(fileURL: fileURL, targetLibrary: library, targetCollection: collection, preferCreateNewLibrary: preferCreateNew)
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportBibTeX)) { _ in
                onShowExportPanel()
            }
            // Unified Import/Export handlers
            .onReceive(NotificationCenter.default.publisher(for: .showUnifiedExport)) { notification in
                // Check if a library was passed in userInfo (context menu)
                if let library = notification.userInfo?["library"] as? CDLibrary {
                    unifiedExportData = UnifiedExportData(scope: .library(library))
                } else if let publications = notification.userInfo?["publications"] as? [CDPublication], !publications.isEmpty {
                    // Export selected publications
                    unifiedExportData = UnifiedExportData(scope: .selection(publications))
                } else if !selectedPublications.isEmpty {
                    // Export currently selected publications
                    unifiedExportData = UnifiedExportData(scope: .selection(selectedPublications))
                } else if let activeLibrary = libraryManager.activeLibrary {
                    // Export active library
                    unifiedExportData = UnifiedExportData(scope: .library(activeLibrary))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showUnifiedImport)) { notification in
                let targetLibrary = notification.userInfo?["library"] as? CDLibrary
                unifiedImportData = UnifiedImportData(fileURL: nil, targetLibrary: targetLibrary)
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
    let libraryManager: LibraryManager
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
        DetailWindowController.shared.openTab(
            tab, for: publication, library: activeLibrary,
            libraryViewModel: libraryViewModel, libraryManager: libraryManager
        )
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
