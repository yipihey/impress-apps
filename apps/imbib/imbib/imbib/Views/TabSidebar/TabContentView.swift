//
//  TabContentView.swift
//  imbib
//
//  Root view using NavigationSplitView with an NSOutlineView-based sidebar.
//  All sidebar state is managed by ImbibSidebarViewModel.
//

import SwiftUI
import PublicationManagerCore
import ImpressKit
import ImpressSidebar
import ImpressStoreKit
import OSLog

/// Root view using NavigationSplitView with an NSOutlineView sidebar.
/// Each sidebar row maps to an `ImbibTab`, and the content area shows
/// the corresponding publication list + detail.
struct TabContentView: View {

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(SearchViewModel.self) private var searchViewModel

    // MARK: - State

    @State private var viewModel = ImbibSidebarViewModel()
    @State private var scixViewModel = SciXLibraryViewModel()

    /// SciX library repository for conditional SciX section and content
    private let scixRepository = SciXLibraryRepository.shared

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
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
        .task {
            // Wire up dependencies
            viewModel.configure(
                libraryManager: libraryManager,
                libraryViewModel: libraryViewModel,
                searchViewModel: searchViewModel
            )
            ContextMenuActions.shared.viewModel = viewModel

            // Compute initial flag counts
            viewModel.refreshFlagCounts()

            // Check for ADS/SciX API key
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
        .task {
            // Run retention cleanup on launch
            RetentionCleanupService.shared.performCleanup()
        }
    }

}

