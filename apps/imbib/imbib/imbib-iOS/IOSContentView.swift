//
//  IOSContentView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import UniformTypeIdentifiers
import OSLog

private let contentLogger = Logger(subsystem: "com.imbib.app", category: "content")

struct IOSContentView: View {

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var selectedSection: SidebarSection? = nil
    @State private var selectedPublication: CDPublication?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // File import/export
    @State private var showImportPicker = false
    @State private var showExportPicker = false
    @State private var showImportPreview = false
    @State private var importFileURL: URL?

    // Settings
    @State private var showSettings = false

    // Category search (for navigating from category chip tap)
    @State private var pendingCategorySearch: String?

    // Global search palette
    @State private var showGlobalSearch = false

    // Active detail tab (for search context)
    @State private var activeDetailTab: IOSDetailTab = .info

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
                selectedPublication: $selectedPublication,
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
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet()
            }
            .fullScreenCover(isPresented: $showGlobalSearch) {
                GlobalSearchPaletteView(
                    isPresented: $showGlobalSearch,
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
                .environment(\.searchContext, currentSearchContext)
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
                selectedPublication = nil
            }
            .onChange(of: selectedPublication) { _, newValue in
                if let pub = newValue, (pub.isDeleted || pub.managedObjectContext == nil) {
                    selectedPublication = nil
                }
                // Reset active tab when publication changes
                if newValue == nil {
                    activeDetailTab = .info
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .detailTabDidChange)) { notification in
                if let tabRawValue = notification.userInfo?["tab"] as? String,
                   let tab = IOSDetailTab(rawValue: tabRawValue) {
                    activeDetailTab = tab
                }
            }
            .background {
                KeyboardShortcutButtons(
                    showImportPicker: $showImportPicker,
                    showExportPicker: $showExportPicker
                )
            }
    }

    // MARK: - Main Split View

    private var mainSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            IOSSidebarView(
                selection: $selectedSection,
                onNavigateToSmartSearch: { smartSearch in
                    selectedSection = .smartSearch(smartSearch)
                    columnVisibility = .detailOnly
                }
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showGlobalSearch = true
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
                .navigationDestination(item: $selectedPublication) { publication in
                    if let libraryID = selectedLibraryID,
                       let detail = DetailView(publication: publication, libraryID: libraryID, selectedPublication: $selectedPublication, listID: currentListID) {
                        detail
                    } else {
                        // Fallback when DetailView can't be created (publication became invalid or no library context)
                        ContentUnavailableView(
                            "Publication Unavailable",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("This publication is no longer available.")
                        )
                    }
                }
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Content List

    @ViewBuilder
    private var contentList: some View {
        switch selectedSection {
        case .inbox:
            if let inboxLibrary = InboxManager.shared.inboxLibrary {
                IOSUnifiedPublicationListWrapper(
                    source: .library(inboxLibrary),
                    selectedPublication: $selectedPublication
                )
            } else {
                ContentUnavailableView(
                    "Inbox Empty",
                    systemImage: "tray",
                    description: Text("Add feeds to start discovering papers")
                )
            }

        case .inboxFeed(let smartSearch):
            IOSUnifiedPublicationListWrapper(
                source: .smartSearch(smartSearch),
                selectedPublication: $selectedPublication
            )

        case .library(let library):
            IOSUnifiedPublicationListWrapper(
                source: .library(library),
                selectedPublication: $selectedPublication
            )

        case .search:
            IOSSearchView(
                selectedPublication: $selectedPublication,
                initialQuery: pendingCategorySearch
            )
            .onDisappear {
                // Clear pending search when leaving search view
                pendingCategorySearch = nil
            }

        case .searchForm(let formType):
            switch formType {
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
                OpenAlexSearchFormView()
            }

        case .smartSearch(let smartSearch):
            IOSUnifiedPublicationListWrapper(
                source: .smartSearch(smartSearch),
                selectedPublication: $selectedPublication
            )

        case .collection(let collection):
            IOSUnifiedPublicationListWrapper(
                source: .collection(collection),
                selectedPublication: $selectedPublication
            )

        case .scixLibrary(let library):
            IOSUnifiedPublicationListWrapper(
                source: .scixLibrary(library),
                selectedPublication: $selectedPublication
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
        if let publication = selectedPublication,
           !publication.isDeleted,
           publication.managedObjectContext != nil,
           let libraryID = selectedLibraryID,
           let detail = DetailView(publication: publication, libraryID: libraryID, selectedPublication: $selectedPublication, listID: currentListID) {
            detail
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
            return InboxManager.shared.inboxLibrary?.id
        case .inboxFeed(let smartSearch):
            return InboxManager.shared.inboxLibrary?.id ?? smartSearch.library?.id
        case .library(let library):
            return library.id
        case .smartSearch(let smartSearch):
            return smartSearch.library?.id
        case .collection(let collection):
            return collection.effectiveLibrary?.id
        case .scixLibrary(let library):
            // SciX libraries are remote - use the library's own ID for PDF paths
            return library.id
        default:
            return nil
        }
    }

    /// Derive the ListViewID from current section for state persistence
    private var currentListID: ListViewID? {
        switch selectedSection {
        case .inbox:
            return InboxManager.shared.inboxLibrary.map { .library($0.id) }
        case .inboxFeed(let smartSearch):
            return .smartSearch(smartSearch.id)
        case .library(let library):
            return .library(library.id)
        case .smartSearch(let smartSearch):
            return .smartSearch(smartSearch.id)
        case .collection(let collection):
            return .collection(collection.id)
        case .scixLibrary(let library):
            return .scixLibrary(library.id)
        default:
            return nil
        }
    }

    /// Compute the current search context based on view state
    private var currentSearchContext: SearchContext {
        // If viewing a publication, context depends on active tab
        if let pub = selectedPublication {
            if activeDetailTab == .pdf {
                return .pdf(pub.id, pub.title ?? "PDF")
            }
            return .publication(pub.id, pub.title ?? "Publication")
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
            // Inbox and search contexts default to global
            return .global
        }
    }

    // MARK: - Navigation

    /// Navigate to a specific publication from global search.
    private func navigateToPublication(_ publicationID: UUID) {
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
            selectedPublication = publication
        }

        contentLogger.info("Navigated to publication: \(publication.citeKey)")
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

// MARK: - Sidebar Section (shared with macOS)

enum SidebarSection: Hashable {
    case inbox
    case inboxFeed(CDSmartSearch)
    case library(CDLibrary)
    case search                        // Legacy, kept for compatibility
    case searchForm(SearchFormType)    // Specific search form
    case smartSearch(CDSmartSearch)
    case collection(CDCollection)
    case scixLibrary(CDSciXLibrary)
}

// MARK: - iOS Search View

struct IOSSearchView: View {
    @Binding var selectedPublication: CDPublication?

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

    var body: some View {
        VStack(spacing: 0) {
            // Search bar section - stays pinned at top regardless of keyboard
            VStack(spacing: 0) {
                // Collapsed search bar (shows when results are displayed and search bar is collapsed)
                if !isSearchBarExpanded && !searchViewModel.publications.isEmpty {
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
                if !searchViewModel.publications.isEmpty {
                    Button("Clear") {
                        searchText = ""
                        searchViewModel.query = ""
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
        } else if searchViewModel.publications.isEmpty {
            ContentUnavailableView(
                "Search Online",
                systemImage: "magnifyingglass",
                description: Text("Search arXiv, ADS, Crossref, and more")
            )
        } else {
            List(searchViewModel.publications, id: \.id, selection: $multiSelection) { publication in
                VStack(alignment: .leading, spacing: 4) {
                    Text(publication.title ?? "Untitled")
                        .font(.headline)
                        .lineLimit(2)
                    Text(publication.authorString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if publication.year > 0 {
                        Text(String(publication.year))
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
        }
    }

    private func sendSelectedToInbox() {
        guard !multiSelection.isEmpty else { return }

        let inboxManager = InboxManager.shared

        // Add selected publications to Inbox
        for id in multiSelection {
            if let publication = searchViewModel.publications.first(where: { $0.id == id }) {
                inboxManager.addToInbox(publication)
            }
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

// MARK: - Preview

// MARK: - iOS Keyboard Shortcut Buttons

/// Hidden buttons that provide keyboard shortcuts on iPad with external keyboard.
/// These are invisible but respond to keyboard shortcuts.
struct KeyboardShortcutButtons: View {
    @Binding var showImportPicker: Bool
    @Binding var showExportPicker: Bool

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
    @Binding var selectedPublication: CDPublication?
    let libraryManager: LibraryManager
    let libraryViewModel: LibraryViewModel

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
                        selectedPublication = libraryViewModel.publication(for: firstPubID)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showInbox)) { _ in
                if InboxManager.shared.inboxLibrary != nil {
                    selectedSection = .inbox
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleReadStatus)) { _ in
                if let pub = selectedPublication {
                    Task {
                        await libraryViewModel.toggleReadStatus(pub)
                    }
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
            deduplicationService: DeduplicationService(),
            repository: PublicationRepository()
        ))
        .environment(SettingsViewModel(
            sourceManager: SourceManager(),
            credentialManager: CredentialManager()
        ))
}
