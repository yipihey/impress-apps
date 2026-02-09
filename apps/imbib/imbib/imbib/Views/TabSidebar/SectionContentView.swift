//
//  SectionContentView.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

import SwiftUI
import PublicationManagerCore
import CoreData
import OSLog
#if os(macOS)
import AppKit
#endif

private let sectionLogger = Logger(subsystem: "com.imbib.app", category: "section")

/// Single persistent 2-column layout for the detail area.
///
/// Contains ONE `HSplitView` that persists across all tab switches.
/// The left pane switches content (publication list, SciX list, or search form)
/// while the right pane always shows the detail view.
/// This preserves the user's divider position across navigation.
///
/// Takes the sidebar viewModel directly and computes content from
/// `viewModel.selectedTab`, establishing a direct `@Observable` dependency.
/// This ensures the view re-evaluates when the tab changes, independent
/// of NavigationSplitView's closure lifecycle.
struct SectionContentView: View {

    /// What type of content to show in the left pane.
    enum ContentKind: Equatable {
        case source(PublicationSource)
        case searchForm(SearchFormType)
    }

    // MARK: - Properties

    let viewModel: ImbibSidebarViewModel

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel

    // MARK: - State

    @State private var selectedPublicationIDs = Set<UUID>()
    @State private var displayedPublicationID: UUID?
    @State private var selectedDetailTab: DetailTab = .info

    /// Search form: whether to show the form or results
    @State private var showSearchForm = true

    // MARK: - Content Resolution

    private let scixRepository = SciXLibraryRepository.shared

    /// Resolves the current sidebar selection to a `ContentKind`.
    /// Reading `viewModel.selectedTab` here establishes a direct @Observable
    /// dependency, so this view re-evaluates when the tab changes.
    private var resolvedContent: ContentKind? {
        switch viewModel.selectedTab {
        case .searchForm(let formType):
            return .searchForm(formType)
        case .scixLibrary(let id):
            guard scixRepository.libraries.contains(where: { $0.id == id }) else { return nil }
            return .source(.scixLibrary(id))
        default:
            return currentSource.map { .source($0) }
        }
    }

    /// Resolves the current sidebar selection to a PublicationSource.
    private var currentSource: PublicationSource? {
        switch viewModel.selectedTab {
        case .inbox:
            return InboxManager.shared.inboxLibrary.map { .library($0.id) }
        case .inboxFeed(let id):
            return fetchInboxFeed(id: id).map { .smartSearch($0.id) }
        case .inboxCollection(let id):
            guard let inboxLib = InboxManager.shared.inboxLibrary else { return nil }
            let inboxCollections = RustStoreAdapter.shared.listCollections(libraryId: inboxLib.id)
            guard inboxCollections.contains(where: { $0.id == id }) else { return nil }
            return .collection(id)
        case .library(let id):
            guard libraryManager.libraries.contains(where: { $0.id == id }) else { return nil }
            return .library(id)
        case .sharedLibrary(let id):
            // Shared libraries are not yet tracked in LibraryManager
            return .library(id)
        case .exploration(let id):
            guard let explorationLib = libraryManager.explorationLibrary else { return nil }
            let smartSearches = RustStoreAdapter.shared.listSmartSearches(libraryId: explorationLib.id)
            guard smartSearches.contains(where: { $0.id == id }) else { return nil }
            return .smartSearch(id)
        case .collection(let id):
            guard findCollectionLibraryID(collectionId: id) != nil else { return nil }
            return .collection(id)
        case .explorationCollection(let id):
            guard let explorationLib = libraryManager.explorationLibrary else { return nil }
            // Bridge LibraryModel → CDLibrary for collection lookup
            let cdExplLib: CDLibrary? = fetchCDLibrary(id: explorationLib.id)
            guard let cdLib = cdExplLib, findCollection(by: id, in: cdLib) != nil else { return nil }
            return .collection(id)
        case .flagged(let color):
            return .flagged(color)
        case .dismissed:
            return libraryManager.dismissedLibrary.map { .library($0.id) }
        case .searchForm, .scixLibrary, nil:
            return nil
        }
    }

    /// Library ID corresponding to the current sidebar selection.
    private var currentLibraryID: UUID? {
        switch viewModel.selectedTab {
        case .inbox, .inboxFeed, .inboxCollection:
            return InboxManager.shared.inboxLibrary?.id
        case .library(let id):
            return id
        case .sharedLibrary(let id):
            return id
        case .exploration, .explorationCollection:
            return libraryManager.explorationLibrary?.id
        case .collection(let id):
            return findCollectionLibraryID(collectionId: id)
        case .flagged:
            return nil
        case .dismissed:
            return libraryManager.dismissedLibrary?.id
        case .searchForm, .scixLibrary, nil:
            return nil
        }
    }

    // MARK: - Derived

    /// Stable key for detecting tab changes — clears selection on change.
    private var tabKey: String {
        guard let content = resolvedContent else { return "none" }
        switch content {
        case .source(let source): return "source-\(source.viewID)"
        case .searchForm(let type): return "search-\(type.rawValue)"
        }
    }

    private var selectedPublicationID: UUID? {
        selectedPublicationIDs.first
    }

    private var selectedPublicationBinding: Binding<PublicationRowData?> {
        Binding(
            get: {
                guard let id = selectedPublicationID else { return nil }
                return libraryViewModel.publication(for: id)
            },
            set: { newPublication in
                let newID = newPublication?.id
                if let id = newID {
                    if !selectedPublicationIDs.contains(id) {
                        selectedPublicationIDs = [id]
                    }
                } else {
                    selectedPublicationIDs.removeAll()
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    displayedPublicationID = newID
                }
            }
        )
    }

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

    private var displayedPublication: PublicationRowData? {
        guard let id = displayedPublicationID else { return nil }
        return libraryViewModel.publication(for: id)
    }

    /// Fetch the underlying CDPublication for APIs that still require Core Data objects.
    private func fetchCDPublication(id: UUID) -> CDPublication? {
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? PersistenceController.shared.viewContext.fetch(request).first
    }

    /// Fetch the underlying CDLibrary for APIs that still require Core Data objects.
    private func fetchCDLibrary(id: UUID) -> CDLibrary? {
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? PersistenceController.shared.viewContext.fetch(request).first
    }

    private var selectedPublications: [PublicationRowData] {
        selectedPublicationIDs.compactMap { libraryViewModel.publication(for: $0) }
    }

    private var isMultiSelection: Bool {
        selectedPublicationIDs.count > 1
    }

    /// Resolve the library ID, falling back to active library for cross-library sources
    private var effectiveLibraryID: UUID? {
        currentLibraryID ?? libraryManager.activeLibrary?.id
    }

    // MARK: - Body

    var body: some View {
        if let content = resolvedContent {
            contentBody(content)
        } else {
            placeholderView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func contentBody(_ content: ContentKind) -> some View {
        HSplitView {
            // ZStack provides a stable NSView container so NSSplitView never
            // sees its subview replaced when the left pane content switches
            // between different view types (list, SciX, search form).
            ZStack {
                leftPane(content)
            }
            .frame(minWidth: 200, idealWidth: 300)
            .frame(maxHeight: .infinity)
            .clipped()

            ZStack {
                detailView
            }
            .transaction { $0.animation = nil }
            .frame(minWidth: 300)
            .frame(maxHeight: .infinity)
            .clipped()
            #if os(macOS)
            .ignoresSafeArea(.container, edges: .top)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let pub = displayedPublication {
                    HStack(spacing: 6) {
                        Picker("Tab", selection: $selectedDetailTab) {
                            ForEach(availableDetailTabs, id: \.self) { tab in
                                Label(tab.label, systemImage: tab.icon).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()

                        Divider()
                            .frame(height: 16)

                        Button {
                            copyBibTeX()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .help("Copy BibTeX to clipboard")

                        if let webURL = webURL(for: pub) {
                            Link(destination: webURL) {
                                Image(systemName: "link")
                            }
                            .help("Open paper's web page")
                        }

                        shareMenu(for: pub)

                        Button {
                            openInSeparateWindow(pub)
                        } label: {
                            Image(systemName: ScreenConfigurationObserver.shared.hasSecondaryScreen
                                  ? "rectangle.portrait.on.rectangle.portrait.angled"
                                  : "uiwindow.split.2x1")
                        }
                        .help(ScreenConfigurationObserver.shared.hasSecondaryScreen
                              ? "Open \(selectedDetailTab.rawValue) on secondary display"
                              : "Open \(selectedDetailTab.rawValue) in new window")
                    }
                }
            }
        }
        #endif
        .onChange(of: tabKey) { _, _ in
            selectedPublicationIDs.removeAll()
            displayedPublicationID = nil
            // Reset search form when switching to a search tab
            if case .searchForm = content {
                showSearchForm = true
            }
        }
        .onChange(of: searchViewModel.isSearching) { wasSearching, isSearching in
            if wasSearching && !isSearching {
                showSearchForm = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSearchFormView)) { _ in
            showSearchForm = true
        }
        #if os(macOS)
        // Window management: open detail tabs in separate windows (Shift+P/N/I/B)
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
        .onReceive(NotificationCenter.default.publisher(for: .closeDetachedWindows)) { _ in
            guard let pubData = displayedPublication,
                  let cdPub = fetchCDPublication(id: pubData.id) else { return }
            DetailWindowController.shared.closeWindows(for: cdPub)
        }
        #endif
    }

    // MARK: - Left Pane

    @ViewBuilder
    private func leftPane(_ content: ContentKind) -> some View {
        switch content {
        case .source(let source):
            VStack(spacing: 0) {
                if case .scixLibrary(let id) = source,
                   let library = scixRepository.libraries.first(where: { $0.id == id }) {
                    SciXLibraryHeader(library: library)
                    Divider()
                }
                UnifiedPublicationListWrapper(
                    source: source,
                    selectedPublicationID: selectedPublicationIDBinding,
                    selectedPublicationIDs: $selectedPublicationIDs,
                    onDownloadPDFs: handleDownloadPDFs
                )
                .id(source.viewID)
            }

        case .searchForm(let formType):
            if showSearchForm {
                searchFormView(formType)
            } else {
                searchResultsView
            }
        }
    }

    // MARK: - Placeholder

    @ViewBuilder
    private var placeholderView: some View {
        if viewModel.selectedTab == .inbox {
            ContentUnavailableView(
                "Inbox Empty",
                systemImage: "tray",
                description: Text("Add feeds to start discovering papers")
            )
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.left",
                description: Text("Select an item from the sidebar")
            )
        }
    }

    // MARK: - Search Form Views

    @ViewBuilder
    private func searchFormView(_ formType: SearchFormType) -> some View {
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

    @ViewBuilder
    private var searchResultsView: some View {
        if let lastSearchCollection = libraryManager.getOrCreateLastSearchCollection() {
            UnifiedPublicationListWrapper(
                source: .collection(lastSearchCollection.id),
                selectedPublicationID: selectedPublicationIDBinding,
                selectedPublicationIDs: $selectedPublicationIDs,
                onDownloadPDFs: { _ in }
            )
        } else {
            ContentUnavailableView(
                "No Active Library",
                systemImage: "magnifyingglass",
                description: Text("Select a library to search within")
            )
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if isMultiSelection && selectedDetailTab == .bibtex {
            let cdPubs = selectedPublicationIDs.compactMap { fetchCDPublication(id: $0) }
            MultiSelectionBibTeXView(
                publications: cdPubs,
                onDownloadPDFs: {
                    handleDownloadPDFs(selectedPublicationIDs)
                }
            )
        } else if let pubData = displayedPublication,
                  let detail = DetailView(
                      publicationID: pubData.id,
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Detail Toolbar (Liquid Glass)

    #if os(macOS)
    /// Inline toolbar with Liquid Glass segmented picker and action buttons.
    /// Placed as a direct child of the right pane VStack, above the detail ZStack,
    /// so it's structurally constrained to the right pane width and stays at the top.
    private var detailToolbar: some View {
        HStack(spacing: 8) {
            Picker("Tab", selection: $selectedDetailTab) {
                ForEach(availableDetailTabs, id: \.self) { tab in
                    Label(tab.label, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .focusable(false)
            .focusEffectDisabled()

            Spacer()

            HStack(spacing: 6) {
                Button {
                    copyBibTeX()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy BibTeX to clipboard")

                if let pub = displayedPublication, let webURL = webURL(for: pub) {
                    Link(destination: webURL) {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Open paper's web page")
                }

                if let pub = displayedPublication {
                    shareMenu(for: pub)
                }

                if let pub = displayedPublication {
                    Divider()
                        .frame(height: 16)

                    Button {
                        openInSeparateWindow(pub)
                    } label: {
                        Image(systemName: ScreenConfigurationObserver.shared.hasSecondaryScreen
                              ? "rectangle.portrait.on.rectangle.portrait.angled"
                              : "uiwindow.split.2x1")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(ScreenConfigurationObserver.shared.hasSecondaryScreen
                          ? "Open \(selectedDetailTab.rawValue) on secondary display"
                          : "Open \(selectedDetailTab.rawValue) in new window")
                }
            }
        }
        .focusable(false)
        .focusEffectDisabled()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
    }

    /// Available tabs based on whether the publication supports editing
    private var availableDetailTabs: [DetailTab] {
        displayedPublication != nil ? DetailTab.allCases : [.info, .pdf, .bibtex]
    }

    /// Share menu for a publication
    private func shareMenu(for pub: PublicationRowData) -> some View {
        Menu {
            if let cdPub = fetchCDPublication(id: pub.id) {
                ShareLink(
                    item: ShareablePublication(from: cdPub),
                    preview: SharePreview(
                        pub.title,
                        image: Image(systemName: "doc.text")
                    )
                ) {
                    Label("Share Paper...", systemImage: "square.and.arrow.up")
                }
            }

            ShareLink(
                item: shareText(for: pub),
                subject: Text(pub.title),
                message: Text(shareText(for: pub))
            ) {
                Label("Share Citation...", systemImage: "text.bubble")
            }

            Divider()

            Button {
                copyBibTeX()
            } label: {
                Label("Copy BibTeX", systemImage: "doc.on.doc")
            }

            Button {
                copyLink(for: pub)
            } label: {
                Label("Copy Link", systemImage: "link")
            }

            Divider()

            Button {
                shareViaEmail(pub)
            } label: {
                Label("Email with PDF & BibTeX...", systemImage: "envelope.badge.fill")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .help("Share options")
    }

    /// Open the current tab in a separate window
    private func openInSeparateWindow(_ pub: PublicationRowData) {
        guard let cdPub = fetchCDPublication(id: pub.id) else { return }
        let cdLib: CDLibrary? = libraryManager.activeLibrary.flatMap { fetchCDLibrary(id: $0.id) }

        let detachedTab: DetachedTab
        switch selectedDetailTab {
        case .info: detachedTab = .info
        case .bibtex: detachedTab = .bibtex
        case .pdf: detachedTab = .pdf
        case .notes: detachedTab = .notes
        }

        DetailWindowController.shared.openTab(
            detachedTab, for: cdPub, library: cdLib,
            libraryViewModel: libraryViewModel, libraryManager: libraryManager
        )
    }
    #endif

    // MARK: - Window Management

    #if os(macOS)
    private func openDetachedTab(_ tab: DetachedTab) {
        guard let pubData = displayedPublication,
              let cdPub = fetchCDPublication(id: pubData.id) else { return }
        let cdLib: CDLibrary? = libraryManager.activeLibrary.flatMap { fetchCDLibrary(id: $0.id) }
        DetailWindowController.shared.openTab(
            tab, for: cdPub, library: cdLib,
            libraryViewModel: libraryViewModel, libraryManager: libraryManager
        )
    }
    #endif

    // MARK: - Toolbar Actions

    #if os(macOS)
    private func copyBibTeX() {
        guard let pub = displayedPublication else { return }
        let bibtex = RustStoreAdapter.shared.exportBibTeX(ids: [pub.id])
        guard !bibtex.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bibtex, forType: .string)
    }

    /// Get the web URL for a publication (DOI > arXiv > ADS)
    private func webURL(for pub: PublicationRowData) -> URL? {
        // Prefer DOI
        if let doi = pub.doi, !doi.isEmpty {
            return URL(string: "https://doi.org/\(doi)")
        }
        // Then arXiv
        if let arxivID = pub.arxivID, !arxivID.isEmpty {
            return URL(string: "https://arxiv.org/abs/\(arxivID)")
        }
        // Then ADS bibcode
        if let bibcode = pub.bibcode, bibcode.count == 19 {
            return URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }
        return nil
    }

    private func copyLink(for pub: PublicationRowData) {
        var link: String?

        // Prefer DOI
        if let doi = pub.doi, !doi.isEmpty {
            link = "https://doi.org/\(doi)"
        }
        // Then arXiv
        else if let arxivID = pub.arxivID, !arxivID.isEmpty {
            link = "https://arxiv.org/abs/\(arxivID)"
        }
        // Then ADS bibcode
        else if let bibcode = pub.bibcode, bibcode.count == 19 {
            link = "https://ui.adsabs.harvard.edu/abs/\(bibcode)"
        }

        if let link {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
    }

    private func shareViaEmail(_ pub: PublicationRowData) {
        // Build email body with abstract
        var body: [String] = []

        // Title
        body.append(pub.title)
        body.append("")

        // Authors
        if !pub.authorString.isEmpty {
            body.append("Authors: \(pub.authorString)")
        }

        // Year and venue
        if let year = pub.year {
            if let venue = pub.venue, !venue.isEmpty {
                body.append("Published: \(venue), \(year)")
            } else {
                body.append("Year: \(year)")
            }
        }

        // URL
        if let doi = pub.doi, !doi.isEmpty {
            body.append("Link: https://doi.org/\(doi)")
        } else if let arxivID = pub.arxivID, !arxivID.isEmpty {
            body.append("Link: https://arxiv.org/abs/\(arxivID)")
        } else if let bibcode = pub.bibcode, bibcode.count == 19 {
            body.append("Link: https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }

        // Abstract
        if let abstract = pub.abstract, !abstract.isEmpty {
            body.append("")
            body.append("Abstract:")
            body.append(abstract)
        }

        // Citation key
        body.append("")
        body.append("---")
        body.append("Citation key: \(pub.citeKey)")

        let emailBody = body.joined(separator: "\n")

        // Build items to share
        var items: [Any] = [emailBody]

        // Add PDF attachments
        let linkedFiles = RustStoreAdapter.shared.listLinkedFiles(publicationId: pub.id)
        for file in linkedFiles where file.isPDF {
            if let url = AttachmentManager.shared.resolveURL(for: file, in: libraryManager.activeLibrary?.id) {
                items.append(url)
            }
        }

        // Create temporary BibTeX file
        let bibtex = RustStoreAdapter.shared.exportBibTeX(ids: [pub.id])
        let tempBibURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(pub.citeKey).bib")
        if let _ = try? bibtex.write(to: tempBibURL, atomically: true, encoding: .utf8) {
            items.append(tempBibURL)
        }

        // Show sharing service picker
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }

    /// Generate share text for a publication (used by ShareLink)
    private func shareText(for pub: PublicationRowData) -> String {
        var lines: [String] = []

        // Title
        lines.append(pub.title)

        // Authors
        if !pub.authorString.isEmpty {
            lines.append(pub.authorString)
        }

        // Year and venue
        var yearVenue: [String] = []
        if let year = pub.year {
            yearVenue.append("(\(year))")
        }
        if let venue = pub.venue, !venue.isEmpty {
            yearVenue.append(venue)
        }
        if !yearVenue.isEmpty {
            lines.append(yearVenue.joined(separator: " "))
        }

        // URL (prefer DOI, then arXiv, then ADS)
        if let doi = pub.doi, !doi.isEmpty {
            lines.append("")
            lines.append("https://doi.org/\(doi)")
        } else if let arxivID = pub.arxivID, !arxivID.isEmpty {
            lines.append("")
            lines.append("https://arxiv.org/abs/\(arxivID)")
        } else if let bibcode = pub.bibcode, bibcode.count == 19 {
            lines.append("")
            lines.append("https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }

        // Citation key for reference
        lines.append("")
        lines.append("Citation key: \(pub.citeKey)")

        return lines.joined(separator: "\n")
    }
    #endif

    // MARK: - Actions

    private func handleDownloadPDFs(_ ids: Set<UUID>) {
        // Batch download handled by posting notification (picked up by ContentView)
        let publications = ids.compactMap { fetchCDPublication(id: $0) }
        guard !publications.isEmpty else { return }
        NotificationCenter.default.post(
            name: .showBatchDownload,
            object: nil,
            userInfo: ["publications": publications, "libraryID": effectiveLibraryID as Any]
        )
    }

    // MARK: - Lookup Helpers

    private func fetchInboxFeed(id: UUID) -> CDSmartSearch? {
        let request = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        request.predicate = NSPredicate(format: "feedsToInbox == YES")
        let feeds = (try? PersistenceController.shared.viewContext.fetch(request)) ?? []
        return feeds.first { $0.id == id }
    }

    /// Recursively find a collection in a library's collection tree
    private func findCollection(by id: UUID, in library: CDLibrary) -> CDCollection? {
        guard let collections = library.collections as? Set<CDCollection> else { return nil }
        func findRecursive(in cols: Set<CDCollection>) -> CDCollection? {
            for col in cols {
                if col.id == id { return col }
                if let children = col.childCollections as? Set<CDCollection>, !children.isEmpty {
                    if let found = findRecursive(in: children) { return found }
                }
            }
            return nil
        }
        return findRecursive(in: collections)
    }

    /// Find which library contains the given collection ID
    private func findCollectionLibraryID(collectionId: UUID) -> UUID? {
        for library in libraryManager.libraries {
            guard let cdLib = fetchCDLibrary(id: library.id) else { continue }
            if findCollection(by: collectionId, in: cdLib) != nil {
                return library.id
            }
        }
        return nil
    }
}

