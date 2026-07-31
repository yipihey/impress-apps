#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  SectionContentView.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

import SwiftUI
import OSLog
import ImpressFTUI
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

    // MARK: - Properties

    let viewModel: ImbibSidebarViewModel

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(\.appShellConfiguration) private var shellConfiguration
    @Environment(\.recordViewerRegistry) private var viewerRegistry

    // MARK: - State

    @State private var selectedPublicationIDs = Set<UUID>()
    @State private var displayedPublicationID: UUID?
    @State private var selectedDetailTab: DetailTab = .info
    @State private var selectedArtifactID: UUID?

    /// RAG "Ask Papers" panel state
    @State private var showRAGPanel = false
    @State private var ragViewModel = RAGChatViewModel()

    /// Paper comparison sheet state
    @State private var showComparisonSheet = false
    @State private var comparisonViewModel = PaperComparisonViewModel()

    /// Search form: whether to show the form or results
    @State private var showSearchForm = true

    /// Feed creation: the form type picked from the feed form picker
    @State private var feedCreationFormType: SearchFormType?

    // MARK: - Content Resolution

    private let scixRepository = SciXLibraryRepository.shared
    @State private var scixViewModel = SciXLibraryViewModel()

    /// Resolves the current sidebar selection to a declarative content route.
    /// Reading `viewModel.selectedTab` here establishes a direct @Observable
    /// dependency, so this view re-evaluates when the tab changes.
    private var resolvedRoute: ImbibContentRoute? {
        // The two cross-kind sections. Their rows belong to whichever kind the
        // PRESET binds them to (imprint's Flagged/Dismissed list manuscripts,
        // imbib's list papers), so they resolve before the publication-source
        // path below can claim them.
        //
        // Stage 3: the binding is read as a KIND rather than compared against
        // `.manuscript`, so a shell that binds Flagged to figures or mail
        // routes correctly with no edit here. Behaviour is identical for every
        // shipped preset — only imprint binds these to a non-publication kind.
        if case .flagged(let colorRaw) = viewModel.selectedTab,
           let kind = shellConfiguration.recordKind(for: .flagged),
           kind != .publication {
            return .record(.flagged(kind, colorRaw))
        }
        if case .dismissed = viewModel.selectedTab,
           let kind = shellConfiguration.recordKind(for: .dismissed),
           kind != .publication,
           // The kind's OWN dismissed status, declared once in its descriptor
           // (`.statusChange(dismissed:restoreTo:)`) — this was the literal
           // `.journal(.status(.dismissed))`.
           let dismissed = BuiltinRecordKinds.registry[kind]?.triage.dismissedStatus {
            return .record(.status(kind, dismissed))
        }
        if case .customSurface(let surfaceID) = viewModel.selectedTab {
            return .customSurface(surfaceID)
        }
        // Record-kind tabs pass straight through: the tab already carries the
        // kind and the scope, so there is nothing per-kind left to unwrap.
        // This replaced four `if let xxxRoute = selectedTab?.xxxRoute` probes.
        switch viewModel.selectedTab {
        case .record(let route):
            return .record(route)
        case .recordDetail(let kind, let recordID):
            return .recordDetail(kind, recordID)
        case .auxiliary(let auxiliaryRoute):
            return .auxiliary(auxiliaryRoute)
        default:
            break
        }

        switch viewModel.selectedTab {
        case .searchForm(let formType):
            return .searchForm(ImbibSearchFormRoute(
                formType: formType,
                mode: .explorationSearch
            ))
        case .scixLibrary(let id):
            guard scixRepository.libraries.contains(where: { $0.id == id }) else { return nil }
            return .publicationList(.scixLibrary(id))
        case .allArtifacts:
            return .artifacts(nil)
        case .artifactType(let rawValue):
            return .artifacts(ArtifactType(rawValue: rawValue))
        case .reviewQueue:
            return .reviewQueue
        case .addFeed:
            if let formType = feedCreationFormType {
                return .searchForm(ImbibSearchFormRoute(
                    formType: formType,
                    mode: .inboxFeed
                ))
            }
            return .feedFormPicker
        case .addLibraryFeed(let libraryID):
            let libName = libraryManager.libraries.first(where: { $0.id == libraryID })?.name ?? "Library"
            if let formType = feedCreationFormType {
                return .searchForm(ImbibSearchFormRoute(
                    formType: formType,
                    mode: .libraryFeed(libraryID, libName)
                ))
            }
            return .feedFormPicker
        case .editFeed(let feedID):
            if let formType = feedFormTypeForFeed(feedID) {
                // Determine correct mode based on feed type
                if let ss = RustStoreAdapter.shared.getSmartSearch(id: feedID) {
                    if ss.feedsToInbox {
                        return .searchForm(ImbibSearchFormRoute(
                            formType: formType,
                            mode: .inboxFeed,
                            editingFeedID: feedID
                        ))
                    } else if let libID = ss.libraryID {
                        let libName = libraryManager.libraries.first(where: { $0.id == libID })?.name ?? "Library"
                        return .searchForm(ImbibSearchFormRoute(
                            formType: formType,
                            mode: .libraryFeed(libID, libName),
                            editingFeedID: feedID
                        ))
                    }
                }
                return .searchForm(ImbibSearchFormRoute(
                    formType: formType,
                    mode: .inboxFeed,
                    editingFeedID: feedID
                ))
            }
            return nil
        default:
            return currentSource.map { .publicationList($0) }
        }
    }

    /// Resolves the current sidebar selection to a PublicationSource.
    private var currentSource: PublicationSource? {
        // Multi-selection takes priority. The view model populates this array
        // with the resolvable subset (library / collection nodes) of whatever
        // the user has multi-selected. Mixed-kind selections (e.g. library +
        // smart search) end up with fewer entries than total selection — we
        // surface the resolvable subset rather than silently falling back.
        let combined = viewModel.selectedSourcesForCombinedView
        if combined.count >= 2 {
            return .combined(combined)
        }
        if combined.count == 1 {
            // Multi-select with one resolvable node — show its content
            // directly (no `.combined` wrapper, since a single-element union
            // is just the source itself).
            return combined[0]
        }

        switch viewModel.selectedTab {
        case .inbox:
            return InboxManager.shared.inboxLibrary.map { .inbox($0.id) }
        case .inboxFeed(let id):
            return fetchInboxFeed(id: id).map { .smartSearch($0.id) }
        case .libraryFeed(let id):
            guard RustStoreAdapter.shared.getSmartSearch(id: id) != nil else { return nil }
            return .smartSearch(id)
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
            let collections = RustStoreAdapter.shared.listCollections(libraryId: explorationLib.id)
            guard collections.contains(where: { $0.id == id }) else { return nil }
            return .collection(id)
        case .flagged(let color):
            return .flagged(color)
        case .dismissed:
            return libraryManager.dismissedLibrary.map { _ in .dismissed }
        case .citedInManuscripts:
            return .citedInManuscripts
        case .recent:
            return .recent
        case .watchedFolder(_, let tagPath):
            // ADR-0023 W2: a folder's papers ARE its provenance tag. No new
            // `PublicationSource` case, no new query — `.tag` is fully
            // Rust-backed and was simply never constructed before now.
            return .tag(tagPath)
        case .allArtifacts, .artifactType, .reviewQueue:
            return nil
        case .customSurface:
            return nil
        case .record, .recordDetail, .auxiliary:
            // Record-kind tabs are NOT publication sources — they route
            // through `recordSection` / `recordDetailView` / `auxiliaryView`.
            // (Four per-kind arms before Stage 3.)
            return nil
        case .searchForm, .scixLibrary, .addFeed, .addLibraryFeed, .editFeed, nil:
            return nil
        }
    }

    /// Library ID corresponding to the current sidebar selection.
    private var currentLibraryID: UUID? {
        switch viewModel.selectedTab {
        case .customSurface:
            return nil
        case .inbox, .inboxFeed, .inboxCollection:
            return InboxManager.shared.inboxLibrary?.id
        case .libraryFeed(let feedID):
            return RustStoreAdapter.shared.getSmartSearch(id: feedID)?.libraryID
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
        case .citedInManuscripts, .recent:
            // Cross-library pseudo source — no owning library.
            return nil
        case .watchedFolder:
            // A watched folder imports INTO the default library, but its list
            // is a cross-library tag scope: naming an owning library here would
            // scope the toolbar's per-library affordances to a library the
            // folder does not own.
            return nil
        case .allArtifacts, .artifactType, .reviewQueue:
            return nil
        case .customSurface:
            return nil
        case .record, .recordDetail, .auxiliary:
            // Record-kind tabs have no owning publication library.
            return nil
        case .searchForm, .scixLibrary, .addFeed, .addLibraryFeed, .editFeed, nil:
            return nil
        }
    }

    // MARK: - Derived

    /// Stable key for detecting tab changes — clears selection on change.
    private var tabKey: String {
        resolvedRoute?.stableID ?? "none"
    }

    private var showFeedSettingsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.feedSettingsID != nil },
            set: { newValue in if !newValue { viewModel.feedSettingsID = nil } }
        )
    }

    private var selectedPublicationID: UUID? {
        selectedPublicationIDs.first
    }

    private var selectedPublicationIDBinding: Binding<UUID?> {
        Binding(
            get: { selectedPublicationIDs.first },
            set: { newID in
                // Only replace the full selection set when explicitly navigating
                // to a single item. When called from PublicationListView's
                // .onChange(of: selection) during multi-select, the Set<UUID>
                // binding is the source of truth — don't collapse it here.
                if let id = newID {
                    if selectedPublicationIDs.count <= 1 || !selectedPublicationIDs.contains(id) {
                        selectedPublicationIDs = [id]
                    }
                } else {
                    selectedPublicationIDs.removeAll()
                }
                displayedPublicationID = newID
            }
        )
    }

    @State private var displayedPublication: PublicationRowData?

    /// Get the full publication detail for APIs that need the full model.
    private func getPublicationDetail(id: UUID) -> PublicationModel? {
        RustStoreAdapter.shared.getPublicationDetail(id: id)
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
        // Record-kind routes bypass the publication HSplitView and render
        // full-bleed in the content area (they own their own list|detail
        // split). Stage 3: ONE arm for every kind — this switch had four
        // (.journal/.figures/.mail/.agents) that differed only in which
        // per-kind dispatcher they called.
        if let route = resolvedRoute {
            switch route {
            case .record(let recordRoute):
                recordSection(recordRoute)
            case .recordDetail(let kind, let recordID):
                recordDetailView(kind: kind, recordID: recordID)
            case .auxiliary(let auxiliaryRoute):
                auxiliaryView(auxiliaryRoute)
            case .customSurface(let surfaceID):
                // WP-X0: app-owned surface, FULL-PANE — no list/detail split,
                // no detail toolbar cluster; only the sidebar toggle applies.
                customSurfaceView(surfaceID)
            default:
                contentBody(route)
            }
        } else {
            placeholderView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// THE record-kind sink (Stage 3). Every kind's list|detail section is
    /// resolved here, from a kind id and a chassis scope — replacing
    /// `journalView`/`figuresView`/`mailView`/`agentsView` (four near-identical
    /// per-kind dispatchers, 18 arms) and their four one-line
    /// `xxxSection(scope:)` helpers.
    ///
    /// ONE deliberate exception, matrix-tracked and unchanged: MANUSCRIPTS are
    /// constructed directly rather than registry-resolved, because
    /// `ManuscriptSectionView` owns the editor session and that must stay
    /// host-owned (imbib CLAUDE.md invariant; asserted by
    /// `RecordViewerRegistryTests`, which pins manuscripts as unregistered).
    /// It is an exception about ONE kind's view ownership, not a per-kind
    /// routing arm — a NEW kind still needs no edit here.
    ///
    /// `.id(scope)` on both paths is the mandated `.id(source.id)` rule: without
    /// it, switching between two routes of the same shape (Drafts → Submitted,
    /// folder → folder) reuses the cached view and its stale `@State`
    /// selection. The registry factories carry their own, verbatim.
    @ViewBuilder
    private func recordSection(_ route: RecordRoute) -> some View {
        if route.kind == .manuscript {
            if let scope = ManuscriptListScope(routeScope: route.scope) {
                ManuscriptSectionView(scope: scope).id(scope)
            } else {
                ChassisEmptyState.viewerUnavailable(kind: route.kind).view
            }
        } else if let factory = viewerRegistry[route.kind] {
            // An unregistered kind degrades quietly the way an unknown custom
            // surface does, rather than rendering nothing.
            factory.makeSectionView(RecordSectionContext(scope: route.scope))
        } else {
            ChassisEmptyState.viewerUnavailable(kind: route.kind).view
        }
    }

    /// One record, full-pane, no list — the deep-link shape (⌘F palette hit).
    /// Manuscripts are the only kind with such a view today; the same
    /// host-ownership exception as `recordSection` applies.
    @ViewBuilder
    private func recordDetailView(kind: RecordKindID, recordID: String) -> some View {
        if kind == .manuscript {
            ManuscriptDetailView(manuscriptID: recordID)
                .ignoresSafeArea(.container, edges: .top)
        } else {
            ChassisEmptyState.viewerUnavailable(kind: kind).view
        }
    }

    /// A non-record route the shell preset declares (`AuxiliaryRoute`).
    @ViewBuilder
    private func auxiliaryView(_ route: AuxiliaryRoute) -> some View {
        switch route {
        case .submissionsInbox:
            // Submissions stays full-bleed — it's a triage board, not an
            // item list (GUI-meld plan §5).
            SubmissionsInboxView()
        }
    }

    @ViewBuilder
    private func contentBody(_ route: ImbibContentRoute) -> some View {
        // Declarative pane layout: the detail pane's visibility is part of
        // PaneLayoutStore.current (⌘0, saved layouts, HTTP /api/layout). The
        // toolbar stays attached to the Group so its fragile positioning
        // (see CLAUDE.md "macOS Detail Pane Layout") is untouched when the
        // pane is visible.
        Group {
            let layout = PaneLayoutStore.shared.current
            if layout.listPaneVisible && layout.detailPaneVisible {
                ImpressSplitView(listMinWidth: 200, listIdealWidth: 300, detailMinWidth: 300) {
                    leftPane(route)
                } detail: {
                    detailView
                }
            } else if layout.detailPaneVisible {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                leftPane(route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

                        Divider()
                            .frame(height: 16)

                        Button { showRAGPanel.toggle() } label: {
                            Image(systemName: "text.bubble")
                                .symbolVariant(showRAGPanel ? .fill : .none)
                        }
                        .help("Ask about papers (⌥⌘A)")

                        if selectedPublicationIDs.count >= 2 {
                            Button { showComparisonSheet = true } label: {
                                Image(systemName: "arrow.left.arrow.right")
                            }
                            .help("Compare \(selectedPublicationIDs.count) papers")
                        }

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
        .onAppear {
            displayedPublication = displayedPublicationID.flatMap { libraryViewModel.publication(for: $0) }
        }
        .onChange(of: displayedPublicationID) { _, newID in
            displayedPublication = newID.flatMap { libraryViewModel.publication(for: $0) }
        }
        .onChange(of: RustStoreAdapter.shared.dataVersion) { _, _ in
            if let id = displayedPublicationID {
                let updated = libraryViewModel.publication(for: id)
                if updated != displayedPublication {
                    displayedPublication = updated
                }
            }
        }
        .onChange(of: tabKey) { _, _ in
            selectedPublicationIDs.removeAll()
            displayedPublicationID = nil
            displayedPublication = nil
            selectedArtifactID = nil
            // Reset search form when switching to a search tab
            if route.isSearchForm {
                showSearchForm = true
            }
        }
        .onChange(of: searchViewModel.isSearching) { wasSearching, isSearching in
            if wasSearching && !isSearching {
                showSearchForm = false
            }
        }
        // Two-way mirror between the local detail-tab selection and the
        // declarative layout state (saved layouts + HTTP /api/layout).
        .onChange(of: selectedDetailTab) { _, tab in
            PaneLayoutStore.shared.current.detailTab = tab.rawValue
        }
        .onChange(of: PaneLayoutStore.shared.current.detailTab) { _, raw in
            if let tab = DetailTab(rawValue: raw), tab != selectedDetailTab {
                selectedDetailTab = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSearchFormView)) { _ in
            showSearchForm = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPublication)) { notification in
            guard let publicationID = notification.userInfo?["publicationID"] as? UUID else { return }
            navigateToPublication(publicationID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToManuscript)) { notification in
            // ⌘F palette manuscript hit (GUI-meld §Search): select the
            // Manuscripts section and deep-link to the manuscript detail.
            guard let idString = notification.userInfo?["manuscriptID"] as? String else { return }
            viewModel.selectedTab = .recordDetail(.manuscript, idString)
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartSearchAddDidComplete)) { notification in
            // After Cmd+S → "Add Selected" lands papers, navigate to the
            // library where they went and select the first one so the user
            // can begin reading immediately. `navigateToPublication` does
            // the library lookup + selection in one shot.
            guard let ids = notification.userInfo?["publicationIDs"] as? [UUID],
                  let first = ids.first
            else { return }
            navigateToPublication(first)
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
            guard let pubData = displayedPublication else { return }
            DetailWindowController.shared.closeWindows(forPublicationID: pubData.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRAGPanel)) { _ in
            showRAGPanel.toggle()
        }
        #endif
        .inspector(isPresented: $showRAGPanel) {
            RAGChatPanel(viewModel: ragViewModel,
                         onNavigateToPaper: { id in navigateToPublication(id) })
        }
        .sheet(isPresented: $showComparisonSheet) {
            PaperComparisonView(viewModel: comparisonViewModel,
                                publicationIDs: Array(selectedPublicationIDs),
                                onNavigateToPaper: { id in navigateToPublication(id) })
        }
        .sheet(isPresented: showFeedSettingsBinding) {
            if let feedID = viewModel.feedSettingsID {
                FeedSettingsView(feedID: feedID) {
                    viewModel.feedSettingsID = nil
                }
            }
        }
        .onChange(of: selectedPublicationIDs) { _, newIDs in
            if !newIDs.isEmpty {
                ragViewModel.scope = .papers(Array(newIDs))
            } else if case .collection(let id)? = resolvedRoute?.publicationSource {
                ragViewModel.scope = .collection(id, name: collectionName(for: id))
            } else {
                ragViewModel.scope = .library
            }
        }
    }

    // MARK: - Left Pane

    /// WP-X0 surface host: constructed lazily per selection from the shell's
    /// registry; unknown ids (stale persisted selection after an app update)
    /// degrade to a quiet placeholder.
    @ViewBuilder
    private func customSurfaceView(_ surfaceID: String) -> some View {
        if let surface = shellConfiguration.customSurfaces[surfaceID] {
            surface.makeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChassisEmptyState.surfaceUnavailable(id: surfaceID).view
        }
    }

    @ViewBuilder
    private func leftPane(_ route: ImbibContentRoute) -> some View {
        switch route {
        case .publicationList(let source):
            VStack(spacing: 0) {
                if case .scixLibrary(let id) = source,
                   let library = scixRepository.libraries.first(where: { $0.id == id }) {
                    SciXLibraryHeader(library: library, viewModel: scixViewModel)
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

        case .searchForm(let searchRoute):
            if showSearchForm {
                searchFormView(searchRoute)
            } else {
                searchResultsView
            }

        case .artifacts(let typeFilter):
            ArtifactListView(
                typeFilter: typeFilter,
                selectedArtifactID: $selectedArtifactID
            )

        case .reviewQueue:
            ReviewQueueListView()

        case .feedFormPicker:
            feedFormPickerView

        case .customSurface:
            // Unreachable: the body dispatch renders custom surfaces
            // full-pane before the split is ever constructed.
            EmptyView()
        case .record, .recordDetail, .auxiliary:
            // Unreachable: the body dispatch renders record-kind sections
            // (which own their own split) before this split is constructed.
            EmptyView()
        }
    }

    // MARK: - Placeholder

    @ViewBuilder
    private var placeholderView: some View {
        if viewModel.selectedTab == .inbox {
            ChassisEmptyState.inboxEmpty.view
        } else {
            ChassisEmptyState.noSidebarSelection.view
        }
    }

    // MARK: - Search Form Views

    @ViewBuilder
    private func searchFormView(_ route: ImbibSearchFormRoute) -> some View {
        let formType = route.formType
        let mode = route.mode
        let editingFeedID = route.editingFeedID

        switch formType {
        case .nlSearch:
            // Selecting the AI row opens the ⌘S Smart Search overlay
            // directly (the old copy just told the user which key to press).
            VStack(spacing: 12) {
                Button {
                    ImbibSearchAction.onlineSourceSearch(source: .toolbarButton).post()
                } label: {
                    Label("Open Smart Search", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                Text("Or press ⌘S from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(mode == .inboxFeed ? "Create AI Feed" : "Smart Search (AI)")
        case .adsModern:
            ADSModernSearchFormView(mode: mode, editingFeedID: editingFeedID)
                .navigationTitle(mode == .inboxFeed ? "Create ADS Feed" : "SciX Search")
        case .adsClassic:
            ADSClassicSearchFormView(mode: mode, editingFeedID: editingFeedID)
                .navigationTitle(mode == .inboxFeed ? "Create ADS Classic Feed" : "ADS Classic Search")
        case .adsPaper:
            ADSPaperSearchFormView(mode: mode, editingFeedID: editingFeedID)
                .navigationTitle(mode == .inboxFeed ? "Create Paper Feed" : "SciX Paper Search")
        case .arxivAdvanced:
            ArXivAdvancedSearchFormView(mode: mode, editingFeedID: editingFeedID)
                .navigationTitle(mode == .inboxFeed ? "Create arXiv Feed" : "arXiv Advanced Search")
        case .arxivFeed:
            ArXivFeedFormView(mode: mode)
                .navigationTitle(mode == .inboxFeed ? "arXiv Feed" : "arXiv Category Search")
        case .arxivGroupFeed:
            GroupArXivFeedFormView(mode: mode, editingFeedID: editingFeedID)
                .navigationTitle(mode == .inboxFeed ? "Group arXiv Feed" : "Group arXiv Search")
        case .adsVagueMemory:
            VagueMemorySearchFormView(mode: mode, editingFeedID: editingFeedID)
                .navigationTitle(mode == .inboxFeed ? "Create Memory Feed" : "Vague Memory Search")
        case .openalex:
            OpenAlexEnhancedSearchFormView(mode: mode, editingFeedID: editingFeedID)
                .navigationTitle(mode == .inboxFeed ? "Create OpenAlex Feed" : "OpenAlex Search")
        }
    }

    @ViewBuilder
    private var searchResultsView: some View {
        ChassisEmptyState.searchResultsElsewhere.view
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let artifactID = selectedArtifactID, isArtifactContent {
            ArtifactDetailView(artifactID: artifactID)
        } else if isMultiSelection && selectedDetailTab == .bibtex {
            MultiSelectionBibTeXView(
                publicationIDs: Array(selectedPublicationIDs),
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
            ChassisEmptyState.noRowSelection(isArtifact: isArtifactContent).view
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isArtifactContent: Bool {
        resolvedRoute?.isArtifactRoute == true
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
            ShareLink(
                item: shareText(for: pub),
                subject: Text(pub.title),
                message: Text(shareText(for: pub))
            ) {
                Label("Share Paper...", systemImage: "square.and.arrow.up")
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
        let detachedTab: DetachedTab
        switch selectedDetailTab {
        case .info: detachedTab = .info
        case .bibtex: detachedTab = .bibtex
        case .pdf: detachedTab = .pdf
        case .notes: detachedTab = .notes
        case .source: detachedTab = .info
        }

        DetailWindowController.shared.openTab(
            detachedTab,
            forPublicationID: pub.id,
            libraryID: effectiveLibraryID,
            libraryViewModel: libraryViewModel,
            libraryManager: libraryManager
        )
    }
    #endif

    // MARK: - Window Management

    #if os(macOS)
    private func openDetachedTab(_ tab: DetachedTab) {
        guard let pubData = displayedPublication else { return }
        DetailWindowController.shared.openTab(
            tab,
            forPublicationID: pubData.id,
            libraryID: effectiveLibraryID,
            libraryViewModel: libraryViewModel,
            libraryManager: libraryManager
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

    /// Preferred web URL for a publication (DOI > arXiv > ADS bibcode).
    /// Single source of truth for URL resolution — used by copyLink, shareText, shareViaEmail.
    private func webURL(for pub: PublicationRowData) -> URL? {
        if let doi = pub.doi, !doi.isEmpty {
            return URL(string: "https://doi.org/\(doi)")
        }
        if let arxivID = pub.arxivID, !arxivID.isEmpty {
            return URL(string: "https://arxiv.org/abs/\(arxivID)")
        }
        if let bibcode = pub.bibcode, bibcode.count == 19 {
            return URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }
        return nil
    }

    private func copyLink(for pub: PublicationRowData) {
        guard let url = webURL(for: pub) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
        if let url = webURL(for: pub) {
            body.append("Link: \(url.absoluteString)")
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
        if let url = webURL(for: pub) {
            lines.append("")
            lines.append(url.absoluteString)
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
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(
            name: .showBatchDownload,
            object: nil,
            userInfo: ["publicationIDs": Array(ids), "libraryID": effectiveLibraryID as Any]
        )
    }

    // MARK: - Lookup Helpers

    /// Find which library contains the given collection ID
    private func findCollectionLibraryID(collectionId: UUID) -> UUID? {
        for library in libraryManager.libraries {
            let collections = RustStoreAdapter.shared.listCollections(libraryId: library.id)
            if collections.contains(where: { $0.id == collectionId }) {
                return library.id
            }
        }
        return nil
    }

    /// Look up a collection's display name from its ID.
    private func collectionName(for collectionId: UUID) -> String {
        for library in libraryManager.libraries {
            let collections = RustStoreAdapter.shared.listCollections(libraryId: library.id)
            if let coll = collections.first(where: { $0.id == collectionId }) {
                return coll.name
            }
        }
        return "Collection"
    }

    // MARK: - Feed Helpers

    /// Look up an inbox feed (smart search) by ID.
    private func fetchInboxFeed(id: UUID) -> SmartSearch? {
        guard let inboxLib = InboxManager.shared.inboxLibrary else { return nil }
        let feeds = RustStoreAdapter.shared.listSmartSearches(libraryId: inboxLib.id)
        return feeds.first(where: { $0.id == id })
    }

    /// Determine which search form type matches a feed's source/query.
    private func feedFormTypeForFeed(_ feedID: UUID) -> SearchFormType? {
        guard let feed = RustStoreAdapter.shared.getSmartSearch(id: feedID) else { return nil }
        let sourceIDs = feed.sourceIDs

        // NL-created feeds (name starts with "AI: ")
        if feed.name.hasPrefix("AI: ") {
            return .nlSearch
        }

        // arXiv feeds with category queries
        if sourceIDs == ["arxiv"] {
            let query = feed.query
            if query.contains("cat:") {
                if query.contains("au:") || query.contains("author:") {
                    return .arxivGroupFeed
                }
                return .arxivFeed
            }
            return .arxivAdvanced
        }

        // OpenAlex feeds
        if sourceIDs == ["openalex"] || sourceIDs.contains("openalex") {
            return .openalex
        }

        // ADS feeds — detect subtype from query structure
        if sourceIDs.contains("ads") || sourceIDs.isEmpty {
            let query = feed.query
            if query.contains("bibcode:") || query.contains("doi:") || query.contains("arXiv:") {
                return .adsPaper
            }
            if query.contains("author:") && (query.contains("title:") || query.contains("abstract:")) {
                return .adsClassic
            }
            return .adsModern
        }

        return .adsModern
    }

    /// Feed form picker view — lets user choose which search form type to use for feed creation.
    @ViewBuilder
    private var feedFormPickerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Add Feed", systemImage: "plus.circle")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Choose a search interface to create a new inbox feed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(SearchFormType.allCases) { formType in
                        Button {
                            feedCreationFormType = formType
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: formType.icon)
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .frame(width: 28, height: 28)
                                    Spacer()
                                }
                                Text(formType.displayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(formType.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Navigate to a publication from global search: switch to its library, select it, scroll to it.
    private func navigateToPublication(_ publicationID: UUID) {
        // Find which library the publication belongs to
        let detail = RustStoreAdapter.shared.getPublicationDetail(id: publicationID)
        let needsLibrarySwitch: Bool
        if let libraryID = detail?.libraryIDs.first {
            viewModel.navigateToTab(.library(libraryID))
            needsLibrarySwitch = true
        } else {
            needsLibrarySwitch = false
        }

        // Select the publication after a delay for the list to load.
        // Cross-library navigation needs a longer delay since the entire
        // PublicationListView is recreated (due to .id(source.id)).
        let delay: Duration = needsLibrarySwitch ? .milliseconds(400) : .milliseconds(150)
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            selectedPublicationIDs = [publicationID]
            displayedPublicationID = publicationID

            // Post scroll notification as a fallback for cases where
            // .onChange(of: selection) doesn't trigger scroll (e.g., same selection value)
            try? await Task.sleep(for: .milliseconds(100))
            NotificationCenter.default.post(name: .scrollToSelection, object: nil)

            // Show the Info tab for the selected paper
            selectedDetailTab = .info
        }
    }
}
#endif
