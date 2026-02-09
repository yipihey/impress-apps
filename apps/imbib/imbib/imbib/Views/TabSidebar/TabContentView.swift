//
//  TabContentView.swift
//  imbib
//
//  Root view using NavigationSplitView with an NSOutlineView-based sidebar.
//  All sidebar state is managed by ImbibSidebarViewModel.
//

import SwiftUI
import PublicationManagerCore
import ImpressSidebar
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

            await libraryViewModel.loadPublications()

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
        .onReceive(NotificationCenter.default.publisher(for: .flagDidChange)) { _ in
            viewModel.refreshFlagCounts()
            viewModel.bumpDataVersion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCollection)) { notification in
            if let collectionID = notification.userInfo?["collectionID"] as? UUID {
                viewModel.navigateToTab(.explorationCollection(collectionID))
                viewModel.explorationRefreshTrigger = UUID()
                viewModel.bumpDataVersion()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .explorationLibraryDidChange)) { _ in
            viewModel.explorationRefreshTrigger = UUID()
            viewModel.bumpDataVersion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSmartSearch)) { notification in
            if let searchID = notification.object as? UUID {
                viewModel.navigateToTab(.exploration(searchID))
                viewModel.explorationRefreshTrigger = UUID()
                viewModel.bumpDataVersion()
            }
        }
        .alert("Delete Library", isPresented: $viewModel.showDeleteConfirmation, presenting: viewModel.libraryToDelete) { library in
            Button("Delete", role: .destructive) {
                try? libraryManager.deleteLibrary(id: library.id)
                viewModel.bumpDataVersion()
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Are you sure you want to delete \"\(library.name)\"? This cannot be undone.")
        }
        // Phase 8: CloudKit sharing sheet removed — will be replaced with Rust-backed sync
        // #if os(macOS)
        // .sheet(item: $viewModel.itemToShareViaICloud) { ... }
        // #endif
    }

}

