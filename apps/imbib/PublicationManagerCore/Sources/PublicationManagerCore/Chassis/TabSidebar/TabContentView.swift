#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  TabContentView.swift
//  imbib
//
//  Root view using NavigationSplitView with an NSOutlineView-based sidebar.
//  All sidebar state is managed by ImbibSidebarViewModel.
//

import SwiftUI
import ImpressKit
import ImpressSidebar
import ImpressStoreKit
import OSLog

/// Root view using NavigationSplitView with an NSOutlineView sidebar.
/// Each sidebar row maps to an `ImbibTab`, and the content area shows
/// the corresponding publication list + detail.
public struct TabContentView: View {

    public init() {}


    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel

    /// Thin-twin app identity — restricts visible sections + default landing
    /// (imbib = everything; imprint = Manuscripts facet). Injected at the app
    /// root; defaults to `.imbib` so imbib is unchanged.
    @Environment(\.appShellConfiguration) private var shellConfiguration

    /// The composed sidebar, when this shell has one. nil in the five sibling
    /// apps; `.impress` in impress, supplied by its root. Applied alongside
    /// `shellConfiguration` below, before `configure()`, so the very first tree
    /// the outline builds is already the composed one.
    @Environment(\.sidebarComposition) private var sidebarComposition

    // MARK: - State

    @State private var viewModel = ImbibSidebarViewModel()
    @State private var didApplyShellConfig = false
    @State private var scixViewModel = SciXLibraryViewModel()

    /// NavigationSplitView column state, driven by the declarative layout
    /// (PaneLayoutStore.current.sidebarVisible ↔ ⌃⌘S / saved layouts /
    /// HTTP /api/layout). Two-way: the split view's own toolbar toggle and
    /// drag-collapse mirror back into the store.
    @State private var columnVisibility: NavigationSplitViewVisibility =
        PaneLayoutStore.shared.current.sidebarVisible ? .all : .detailOnly

    /// SciX library repository for conditional SciX section and content
    private let scixRepository = SciXLibraryRepository.shared

    // MARK: - Body

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            #if os(macOS)
            VStack(spacing: 0) {
                SidebarOutlineView<ImbibSidebarNode>(
                    selectedNodeID: $viewModel.selectedNodeID,
                    expansionState: viewModel.expansionState,
                    configuration: viewModel.outlineConfiguration,
                    dataVersion: viewModel.dataVersion,
                    editingNodeID: $viewModel.editingNodeID
                )
            }
            #else
            Text("iOS sidebar not yet migrated")
                .navigationTitle("imbib")
            #endif
        } detail: {
            // SectionContentView reads viewModel.selectedTab directly via
            // @Observable, so it re-evaluates when the tab changes — independent
            // of whether NavigationSplitView re-evaluates this closure.
            SectionContentView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        // List (middle column) show/hide. Declared on the NavigationSplitView
        // root — the sibling of the system's sidebar toggle — because toolbar
        // items declared inside the detail column's route views never reach
        // the window toolbar.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let visible = PaneLayoutStore.shared.current.listPaneVisible
                Button {
                    PaneLayoutStore.shared.current.listPaneVisible.toggle()
                } label: {
                    Image(systemName: visible
                        ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                }
                .help(visible ? "Hide the list (⌥⌘0)" : "Show the list (⌥⌘0)")
            }
        }
        #endif
        .onChange(of: PaneLayoutStore.shared.current.sidebarVisible) { _, visible in
            let target: NavigationSplitViewVisibility = visible ? .all : .detailOnly
            if columnVisibility != target { columnVisibility = target }
        }
        .onChange(of: columnVisibility) { _, visibility in
            let visible = visibility != .detailOnly
            if PaneLayoutStore.shared.current.sidebarVisible != visible {
                PaneLayoutStore.shared.current.sidebarVisible = visible
            }
        }
        .task {
            // Thin-twin: apply the app-shell identity BEFORE configure() so the
            // default section + section visibility reflect this app (imbib vs
            // imprint). Idempotent across .task re-runs.
            if !didApplyShellConfig {
                viewModel.shellConfiguration = shellConfiguration
                // nil for the five single-preset shells, so this line is the
                // no-op it looks like there; `.impress` for impress, which is
                // what turns the flat sidebar into five app groups.
                viewModel.sidebarComposition = sidebarComposition
                didApplyShellConfig = true
            }
            // Wire up dependencies
            viewModel.configure(
                libraryManager: libraryManager,
                libraryViewModel: libraryViewModel,
                searchViewModel: searchViewModel
            )
            ContextMenuActions.shared.viewModel = viewModel

            // Compute initial flag counts
            viewModel.refreshFlagCounts()

            // Check for ADS/SciX API key. Only shells that surface external
            // search (imbib) may touch these credentials: the keychain items
            // are ACL'd to imbib's code signature, so a sibling app reading
            // them blocks its cooperative pool on a SecurityAgent password
            // prompt (impart/impel/implore each stalled on this at launch).
            // Two gates, and they say different things. `permits(.search)` is
            // the shell's DECLARATION that it surfaces external search (imbib
            // and impress). `itemsAreReadableWithoutPrompting` is the
            // REACHABILITY fact that the items are ACL'd to imbib's code
            // signature — the second half of the ADR-0022 D9 signing decision,
            // which impress's shipping made due.
            guard shellConfiguration.permits(.search),
                  CredentialManager.itemsAreReadableWithoutPrompting else { return }
            let adsKey = await CredentialManager.shared.apiKey(for: "ads")
            let scixKey = await CredentialManager.shared.apiKey(for: "scix")
            if adsKey != nil || scixKey != nil {
                viewModel.hasSciXAPIKey = true
                scixRepository.loadLibraries()
                viewModel.scixSyncing = true
                viewModel.scixSyncError = nil
                viewModel.bumpDataVersion()
                Task.detached {
                    do {
                        try await SciXSyncManager.shared.pullLibraries()
                        await MainActor.run {
                            viewModel.scixSyncing = false
                            viewModel.bumpDataVersion()
                        }
                    } catch {
                        Logger.library.errorCapture("SciX library sync failed: \(error.localizedDescription)", category: "scix")
                        await MainActor.run {
                            viewModel.scixSyncError = error.localizedDescription
                            viewModel.scixSyncing = false
                            viewModel.bumpDataVersion()
                        }
                    }
                }
            }
        }
        .task {
            // Subscribe to the gateway's event stream directly.
            // Structural events re-read the full sidebar; field-only
            // mutations just bump flag counts + a light data version.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                switch event {
                case .structural:
                    viewModel.refreshFromStore()
                case .itemsMutated:
                    viewModel.refreshFlagCounts()
                    viewModel.bumpDataVersionLight()
                case .collectionMembershipChanged:
                    viewModel.refreshFromStore()
                }
            }
        }
        .onNotifications([
            (.sidebarSnapshotDidUpdate, { _ in
                // Phase 3: snapshot refreshed in the background; rebuild
                // the sidebar so the NSOutlineView picks up the new counts.
                // Non-structural — tree shape is unchanged, only badges.
                viewModel.bumpDataVersionLight()
            }),
            (.navigateToCollection, { notification in
                if let collectionID = notification.userInfo?["collectionID"] as? UUID {
                    libraryManager.loadLibraries()
                    viewModel.navigateToTab(.explorationCollection(collectionID))
                    viewModel.explorationRefreshTrigger = UUID()
                    viewModel.bumpDataVersion()
                }
            }),
            (.explorationLibraryDidChange, { _ in
                libraryManager.loadLibraries()
                viewModel.explorationRefreshTrigger = UUID()
                viewModel.bumpDataVersion()
            }),
            (.navigateToSmartSearch, { notification in
                if let searchID = notification.object as? UUID {
                    viewModel.navigateToTab(.exploration(searchID))
                    viewModel.explorationRefreshTrigger = UUID()
                    viewModel.bumpDataVersion()
                }
            }),
            (.openStoreSearch, { _ in
                // WP G4 (ADR-0022 D6): ⌘⇧F in shells with nothing else bound
                // (implore, impel) selects the chassis's builtin search
                // surface. The surface is always registered
                // (`CustomSurfaceRegistry.builtin`), so this never dead-ends.
                viewModel.navigateToTab(.customSurface(StoreSearchSurface.surfaceID))
            }),
            // Stage 4c (ADR-0021 seam, ChassisNavigation.swift): the general
            // case of the two lines above. An app whose DEFAULT window is the
            // chassis has to be able to drive it from its own menu commands
            // (impart's ⌘1-5) and URL scheme (impel://navigate/...), neither of
            // which can reach `viewModel` — and neither of which should learn
            // `ImbibTab`.
            (.chassisNavigateToSurface, { notification in
                guard let surfaceID = notification.object as? String,
                      shellConfiguration.customSurfaces[surfaceID] != nil else {
                    // An id no surface claims navigates nowhere, rather than to
                    // an "unavailable surface" pane the user did not ask for.
                    return
                }
                viewModel.navigateToTab(.customSurface(surfaceID))
            }),
            (.chassisNavigateToDefaultSection, { _ in
                viewModel.selectDefaultSectionLeaf()
            }),
        ])
        .alert("Delete Library", isPresented: $viewModel.showDeleteConfirmation, presenting: viewModel.libraryToDelete) { library in
            Button("Delete", role: .destructive) {
                try? libraryManager.deleteLibrary(id: library.id)
                viewModel.bumpDataVersion()
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Are you sure you want to delete \"\(library.name)\"? This cannot be undone.")
        }
        .alert(
            "Delete \(viewModel.librariesPendingBulkDelete.count) Libraries?",
            isPresented: $viewModel.showDeleteMultipleLibrariesConfirmation
        ) {
            Button("Delete \(viewModel.librariesPendingBulkDelete.count) Libraries", role: .destructive) {
                viewModel.performBulkDeleteLibraries()
            }
            Button("Cancel", role: .cancel) {
                viewModel.librariesPendingBulkDelete = []
            }
        } message: {
            let names = viewModel.librariesPendingBulkDelete.map { $0.name }
            let preview = names.prefix(3).joined(separator: ", ")
            let suffix = names.count > 3 ? ", and \(names.count - 3) more" : ""
            Text("\"\(preview)\(suffix)\" will be removed from the sidebar. The papers they contain are not deleted — they remain in any other libraries they belong to. Papers that are only in these libraries will be unlinked and can be recovered via Edit → Undo.")
        }
        .alert(
            "Delete \(viewModel.collectionsPendingBulkDelete.count) Collections?",
            isPresented: $viewModel.showDeleteMultipleCollectionsConfirmation
        ) {
            Button("Delete \(viewModel.collectionsPendingBulkDelete.count) Collections", role: .destructive) {
                viewModel.performBulkDeleteCollections()
            }
            Button("Cancel", role: .cancel) {
                viewModel.collectionsPendingBulkDelete = []
            }
        } message: {
            Text("\(viewModel.collectionsPendingBulkDelete.count) collections will be removed. The papers they contain stay in their libraries. Recoverable via Edit → Undo.")
        }
        .alert("Delete SciX Library", isPresented: $viewModel.showSciXDeleteConfirmation, presenting: viewModel.scixLibraryToDelete) { library in
            Button("Delete", role: .destructive) {
                Task { try? await scixViewModel.deleteLibrary(library, deleteRemote: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Are you sure you want to remove \"\(library.name)\" from imbib? This removes the local copy; the ADS library is not deleted.")
        }
        .sheet(item: $viewModel.scixLibraryToShowInfo) { library in
            SciXLibraryInfoSheet(library: library, viewModel: scixViewModel)
        }
        .sheet(item: $viewModel.scixLibraryToEdit) { library in
            SciXEditLibrarySheet(library: library, viewModel: scixViewModel)
        }
        // ADR-0023 W5 — the PDFs a watched folder could not attach on its own.
        .sheet(item: $viewModel.attachmentReviewRequest) { request in
            WatchedAttachmentOffersView(
                folderName: request.folderName,
                offers: request.offers,
                onAttach: { offer, candidate in
                    viewModel.confirmAttachment(offer, to: candidate)
                },
                onDismiss: { viewModel.attachmentReviewRequest = nil })
        }
        .task {
            // Run retention cleanup on launch
            RetentionCleanupService.shared.performCleanup()
        }
    }

}

#endif
