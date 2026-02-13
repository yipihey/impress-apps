//
//  ContentView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
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
    @Environment(\.undoManager) private var undoManager

    // MARK: - State

    /// Data for import preview sheet (nil = not shown)
    @State private var importPreviewData: ImportPreviewData?
    /// Selected detail tab - persisted across paper changes so PDF tab stays selected
    @State private var selectedDetailTab: DetailTab = .info
    /// Single source of truth for selection - supports both single and multi-selection.
    /// Use `selectedPublicationID` computed property to get the primary selection.
    @State private var selectedPublicationIDs = Set<UUID>()

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

    /// Centralized focus tracking for vim-style pane navigation (h/l cycling, j/k per-pane)
    /// Using @State instead of @FocusState because we're tracking logical pane focus, not SwiftUI keyboard focus
    @State private var focusedPane: FocusedPane?

    /// Whether to show the stale search index alert
    @State private var showStaleIndexAlert = false

    /// Whether search index rebuild is in progress
    @State private var isRebuildingSearchIndex = false

    // MARK: - Derived Selection

    /// The primary selected publication ID (first of multi-selection).
    /// Derived from `selectedPublicationIDs` - the single source of truth.
    private var selectedPublicationID: UUID? {
        selectedPublicationIDs.first
    }

    /// The publication ID that the detail view should display.
    /// Updated asynchronously after selection to allow list to feel responsive.
    @State private var displayedPublicationID: UUID?

    /// Derive the selected publication for the detail view.
    private var displayedPublication: PublicationRowData? {
        guard let id = displayedPublicationID else { return nil }
        return libraryViewModel.publication(for: id)
    }

    /// Compute the current search context based on view state.
    /// Used for context-aware global search (Cmd+F).
    private var currentSearchContext: SearchContext {
        if let pubID = displayedPublicationID,
           let pub = displayedPublication {
            if selectedDetailTab == .pdf {
                return .pdf(pubID, pub.title ?? "PDF")
            }
            return .publication(pubID, pub.title ?? "Publication")
        }
        return .global
    }

    /// Get the selected publications for multi-selection operations (e.g., BibTeX export).
    private var selectedPublicationsForExport: [PublicationRowData] {
        selectedPublicationIDs.compactMap { libraryViewModel.publication(for: $0) }
    }

    // MARK: - Body

    var body: some View {
        let _ = contentLogger.info("⏱ ContentView.body START")
        tabSidebarContent
            .onAppear {
                UndoCoordinator.shared.undoManager = undoManager
            }
            .task {
                // Only dedup on startup if papers were imported since last launch.
                // This avoids an 86-second FTS rebuild every single startup.
                let defaults = UserDefaults.standard
                guard defaults.bool(forKey: "needsStartupDedup") else { return }
                defaults.set(false, forKey: "needsStartupDedup")

                let store = RustStoreAdapter.shared
                var totalRemoved = 0
                for lib in store.listLibraries() {
                    let removed = store.deduplicateLibrary(id: lib.id)
                    if removed > 0 {
                        logInfo("Startup dedup: removed \(removed) duplicates from library '\(lib.name)'", category: "dedup")
                        totalRemoved += removed
                    }
                }
                // Rebuild FTS index if duplicates were removed (stale entries would cause search failures)
                if totalRemoved > 0 {
                    // Wait for FTS to be initialized (it's set up in background init)
                    for _ in 0..<60 {
                        let available = await FullTextSearchService.shared.isAvailable
                        if available { break }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    logInfo("Rebuilding FTS index after dedup (\(totalRemoved) entries removed)", category: "search")
                    await FullTextSearchService.shared.rebuildIndex()
                }
            }
            .onChange(of: undoManager) { _, newValue in
                UndoCoordinator.shared.undoManager = newValue
            }
    }

    /// Tab sidebar content — the sole sidebar implementation
    private var tabSidebarContent: some View {
        TabContentView()
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet()
            }
            .sheet(item: $batchDownloadData) { data in
                PDFBatchDownloadView(publicationIDs: data.publicationIDs, libraryID: data.libraryID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showBatchDownload)) { notification in
                handleBatchDownloadNotification(notification)
            }
            .modifier(ImportExportHandlersModifier(
                importPreviewData: $importPreviewData,
                unifiedExportData: $unifiedExportData,
                unifiedImportData: $unifiedImportData,
                libraryManager: libraryManager,
                selectedPublications: selectedPublicationsForExport,
                onShowImportPanel: showImportPanel,
                onShowExportPanel: showExportPanel
            ))
            #if os(macOS)
            .modifier(WindowManagementHandlersModifier(
                displayedPublicationID: $displayedPublicationID,
                libraryViewModel: libraryViewModel,
                libraryManager: libraryManager,
                activeLibraryID: libraryManager.activeLibrary?.id
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
                    targetLibraryID: data.targetLibraryID,
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
            .onReceive(NotificationCenter.default.publisher(for: .showGlobalSearch)) { _ in
                showGlobalSearch = true
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

                Button("Filter") {
                    NotificationCenter.default.post(name: .activateFilter, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
            }
            .alert("Paper Not Found", isPresented: $showStaleIndexAlert) {
                Button("Rebuild Index") {
                    rebuildSearchIndex()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This paper may have been deleted. The search index might be out of date. Would you like to rebuild it?")
            }
    }

    // MARK: - Batch Download Handling

    private func handleBatchDownloadNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let publicationIDs = userInfo["publicationIDs"] as? [UUID],
              let libraryID = userInfo["libraryID"] as? UUID else { return }

        // Try to find the library in owned libraries
        if let libraryModel = libraryManager.libraries.first(where: { $0.id == libraryID }) {
            batchDownloadData = BatchDownloadData(publicationIDs: publicationIDs, libraryID: libraryModel.id)
            return
        }

        // Shared libraries not yet tracked in Rust store
    }

    // MARK: - Pane Focus Cycling (Vim-style h/l)

    /// Cycle focus to the right (l key): sidebar → list → info → pdf → notes → bibtex → sidebar
    private func cycleFocusRight() {
        guard let current = focusedPane,
              let idx = FocusedPane.allPanes.firstIndex(of: current) else {
            focusedPane = .sidebar
            return
        }
        let nextPane = FocusedPane.allPanes[(idx + 1) % FocusedPane.allPanes.count]
        setFocusedPane(nextPane)
    }

    /// Cycle focus to the left (h key): bibtex → notes → pdf → info → list → sidebar → bibtex
    private func cycleFocusLeft() {
        guard let current = focusedPane,
              let idx = FocusedPane.allPanes.firstIndex(of: current) else {
            focusedPane = .bibtex
            selectedDetailTab = .bibtex
            return
        }
        let prevPane = FocusedPane.allPanes[(idx - 1 + FocusedPane.allPanes.count) % FocusedPane.allPanes.count]
        setFocusedPane(prevPane)
    }

    /// Set focused pane and switch detail tab if needed (like clicking toolbar button)
    private func setFocusedPane(_ pane: FocusedPane) {
        focusedPane = pane

        // When focusing a detail tab, switch to that tab (same as toolbar buttons)
        if let detailTab = pane.asDetailTab {
            selectedDetailTab = detailTab
        }
    }

    /// Handle PDF search - triggers in-PDF search with highlighting.
    /// Called when user submits search while in PDF context.
    private func handlePDFSearch(_ query: String) {
        showGlobalSearch = false
        NotificationCenter.default.post(
            name: .pdfSearchRequested,
            object: nil,
            userInfo: ["query": query]
        )
    }

    /// Navigate to a specific publication from global search.
    ///
    /// Finds the library containing the publication and navigates to it.
    /// Shows an alert if the publication can't be found (stale index).
    func navigateToPublication(_ publicationID: UUID) {
        guard libraryViewModel.publication(for: publicationID) != nil else {
            contentLogger.warning("Cannot navigate to publication \(publicationID): not found (stale index)")
            showStaleIndexAlert = true
            return
        }

        // Post notification — SectionContentView handles sidebar navigation,
        // publication selection, and scrolling.
        NotificationCenter.default.post(
            name: .navigateToPublication,
            object: nil,
            userInfo: ["publicationID": publicationID]
        )
    }

    /// Rebuild the search indexes (fulltext and semantic) when they become stale.
    private func rebuildSearchIndex() {
        guard !isRebuildingSearchIndex else { return }
        isRebuildingSearchIndex = true

        Task {
            contentLogger.info("Starting search index rebuild...")
            await FullTextSearchService.shared.rebuildIndex()
            let libraryIDs = libraryManager.libraries.map(\.id)
            await EmbeddingService.shared.buildIndex(from: libraryIDs)
            contentLogger.info("Search index rebuild complete")
            isRebuildingSearchIndex = false
        }
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
            importPreviewData = ImportPreviewData(fileURL: url, targetLibraryID: nil)
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
            preselectedLibraryID: data.targetLibraryID,
            preferCreateNewLibrary: data.preferCreateNewLibrary
        ) { entries, targetLibraryID, newLibraryName, duplicateHandling in
            try await importPreviewEntries(entries, to: targetLibraryID, newLibraryName: newLibraryName, duplicateHandling: duplicateHandling, collectionID: data.targetCollectionID)
        }
    }

    private func importPreviewEntries(
        _ entries: [ImportPreviewEntry],
        to targetLibraryID: UUID?,
        newLibraryName: String?,
        duplicateHandling: DuplicateHandlingMode,
        collectionID: UUID? = nil
    ) async throws -> Int {
        let store = RustStoreAdapter.shared

        // Determine which library to import to
        let libraryID: UUID
        if let existingID = targetLibraryID {
            libraryID = existingID
        } else if let name = newLibraryName {
            guard let libraryModel = libraryManager.createLibrary(name: name) else {
                throw ImportError.noLibrarySelected
            }
            libraryManager.setActive(libraryModel)
            libraryID = libraryModel.id
        } else {
            guard let activeModel = libraryManager.activeLibrary else {
                throw ImportError.noLibrarySelected
            }
            libraryID = activeModel.id
        }

        var importedIDs: [UUID] = []

        // Handle duplicates that should be replaced
        for entry in entries {
            if entry.isDuplicate, let duplicateID = entry.duplicateOfID {
                if duplicateHandling == .replaceWithImported {
                    updatePublicationFromEntry(id: duplicateID, entry: entry)
                    importedIDs.append(duplicateID)
                }
                continue
            }
        }

        // Collect new entries as BibTeX strings and import via Rust store
        var newBibTeXStrings: [String] = []
        for entry in entries {
            if entry.isDuplicate { continue }
            switch entry.source {
            case .bibtex(let bibtex):
                newBibTeXStrings.append(bibtex.rawBibTeX ?? BibTeXExporter().export(bibtex))
            case .ris(let ris):
                let bibtex = RISBibTeXConverter.toBibTeX(ris)
                newBibTeXStrings.append(bibtex.rawBibTeX ?? BibTeXExporter().export(bibtex))
            }
        }

        if !newBibTeXStrings.isEmpty {
            let combinedBibTeX = newBibTeXStrings.joined(separator: "\n\n")
            let createdIDs = store.importBibTeX(combinedBibTeX, libraryId: libraryID)
            importedIDs.append(contentsOf: createdIDs)
        }

        // Add to collection if specified
        if let collectionID, !importedIDs.isEmpty {
            store.addToCollection(publicationIds: importedIDs, collectionId: collectionID)
        }

        let count = importedIDs.count

        await libraryViewModel.loadPublications()

        return count
    }

    /// Update an existing publication with data from an import entry via RustStoreAdapter
    private func updatePublicationFromEntry(id: UUID, entry: ImportPreviewEntry) {
        let store = RustStoreAdapter.shared
        switch entry.source {
        case .bibtex(let bibtex):
            if let title = bibtex.fields["title"] {
                store.updateField(id: id, field: "title", value: title)
            }
            if let abstract = bibtex.fields["abstract"] {
                store.updateField(id: id, field: "abstract_text", value: abstract)
            }
            if let doi = bibtex.fields["doi"] {
                store.updateField(id: id, field: "doi", value: doi)
            }
            if let year = bibtex.fields["year"] {
                store.updateField(id: id, field: "year", value: year)
            }

        case .ris(let ris):
            if let title = ris.title {
                store.updateField(id: id, field: "title", value: title)
            }
            if let abstract = ris.abstract {
                store.updateField(id: id, field: "abstract_text", value: abstract)
            }
            if let doi = ris.doi {
                store.updateField(id: id, field: "doi", value: doi)
            }
            if let year = ris.year {
                store.updateField(id: id, field: "year", value: String(year))
            }
        }
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
    case inboxFeed(UUID)               // Inbox feed (smart search ID with feedsToInbox)
    case inboxCollection(UUID)         // Collection within Inbox (for organizing feeds)
    case library(UUID)                 // All publications for specific library (library ID)
    case search                        // Global search (legacy, kept for compatibility)
    case searchForm(SearchFormType)   // Specific search form (ADS Modern, Classic, Paper)
    case smartSearch(UUID)             // Smart search (ID, library-scoped)
    case collection(UUID)              // Collection (ID, library-scoped)
    case scixLibrary(UUID)             // SciX online library (ID)
    case flagged(String?)              // Flagged publications (nil = any flag, or specific color name)
}

// MARK: - Batch Download Data

/// Data for the batch PDF download sheet.
/// Using Identifiable allows sheet(item:) to properly capture the data when shown.
struct BatchDownloadData: Identifiable {
    let id = UUID()
    let publicationIDs: [UUID]
    let libraryID: UUID
}

/// Data for the import preview sheet.
/// Using Identifiable ensures sheet only shows when we have a valid URL.
struct ImportPreviewData: Identifiable {
    let id = UUID()
    let fileURL: URL
    /// Optional target library ID (pre-selected when dropping on a library)
    let targetLibraryID: UUID?
    /// Optional target collection ID (when dropping on a collection row)
    let targetCollectionID: UUID?
    /// When true, defaults to "Create new library" (e.g., sidebar-wide drop)
    let preferCreateNewLibrary: Bool

    init(fileURL: URL, targetLibraryID: UUID? = nil, targetCollectionID: UUID? = nil, preferCreateNewLibrary: Bool = false) {
        self.fileURL = fileURL
        self.targetLibraryID = targetLibraryID
        self.targetCollectionID = targetCollectionID
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
    /// Optional target library ID for import
    let targetLibraryID: UUID?

    init(fileURL: URL? = nil, targetLibraryID: UUID? = nil) {
        self.fileURL = fileURL
        self.targetLibraryID = targetLibraryID
    }
}

// MARK: - Import/Export Handlers ViewModifier

/// ViewModifier for import/export notification handlers.
struct ImportExportHandlersModifier: ViewModifier {
    @Binding var importPreviewData: ImportPreviewData?
    @Binding var unifiedExportData: UnifiedExportData?
    @Binding var unifiedImportData: UnifiedImportData?
    let libraryManager: LibraryManager
    let selectedPublications: [PublicationRowData]
    let onShowImportPanel: () -> Void
    let onShowExportPanel: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .importBibTeX)) { _ in
                onShowImportPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importBibTeXToLibrary)) { notification in
                guard let fileURL = notification.userInfo?["fileURL"] as? URL else { return }
                let libraryID = notification.userInfo?["libraryID"] as? UUID
                let collectionID = notification.userInfo?["collectionID"] as? UUID
                let preferCreateNew = libraryID == nil
                importPreviewData = ImportPreviewData(fileURL: fileURL, targetLibraryID: libraryID, targetCollectionID: collectionID, preferCreateNewLibrary: preferCreateNew)
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportBibTeX)) { _ in
                onShowExportPanel()
            }
            // Unified Import/Export handlers
            .onReceive(NotificationCenter.default.publisher(for: .showUnifiedExport)) { notification in
                let store = RustStoreAdapter.shared
                if let libraryID = notification.userInfo?["libraryID"] as? UUID,
                   let lib = libraryManager.libraries.first(where: { $0.id == libraryID }) {
                    let count = store.queryPublications(parentId: libraryID).count
                    unifiedExportData = UnifiedExportData(scope: .library(libraryID, lib.name, count))
                } else if let publicationIDs = notification.userInfo?["publicationIDs"] as? [UUID], !publicationIDs.isEmpty {
                    unifiedExportData = UnifiedExportData(scope: .selection(publicationIDs))
                } else if !selectedPublications.isEmpty {
                    unifiedExportData = UnifiedExportData(scope: .selection(selectedPublications.map(\.id)))
                } else if let activeLibraryModel = libraryManager.activeLibrary {
                    let count = store.queryPublications(parentId: activeLibraryModel.id).count
                    unifiedExportData = UnifiedExportData(scope: .library(activeLibraryModel.id, activeLibraryModel.name, count))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showUnifiedImport)) { notification in
                let targetLibraryID = notification.userInfo?["libraryID"] as? UUID
                unifiedImportData = UnifiedImportData(fileURL: nil, targetLibraryID: targetLibraryID)
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
    let activeLibraryID: UUID?

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
                guard let pubID = displayedPublicationID else { return }
                DetailWindowController.shared.closeWindows(forPublicationID: pubID)
            }
    }

    private func openDetachedTab(_ tab: DetachedTab) {
        guard let pubID = displayedPublicationID else { return }
        DetailWindowController.shared.openTab(
            tab, forPublicationID: pubID, libraryID: activeLibraryID,
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
            deduplicationService: DeduplicationService()
        ))
        .environment(SettingsViewModel(
            sourceManager: SourceManager(),
            credentialManager: CredentialManager()
        ))
}
