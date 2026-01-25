//
//  SearchView.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import PublicationManagerCore

/// Displays ad-hoc search results as CDPublication entities.
///
/// ADR-016: Search results are auto-imported to the active library's "Last Search"
/// collection. This provides full library capabilities (editing, notes, etc.)
/// for all search results.
struct SearchResultsListView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var viewModel
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Bindings (for selection)

    @Binding var selectedPublication: CDPublication?

    // Drop preview sheet state (for list background drops)
    @StateObject private var dragDropCoordinator = DragDropCoordinator.shared
    @State private var showingDropPreview = false
    @State private var dropPreviewTargetLibraryID: UUID?

    // MARK: - Initialization

    init(selectedPublication: Binding<CDPublication?> = .constant(nil)) {
        self._selectedPublication = selectedPublication
    }

    // MARK: - Body

    var body: some View {
        @Bindable var viewModel = viewModel

        // Results list only - search form is in the detail pane
        resultsList
            .navigationTitle("Search Results")
            .task {
                // Ensure SearchViewModel has access to LibraryManager
                viewModel.setLibraryManager(libraryManager)
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
            Task { try? await libraryViewModel.pasteFromClipboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAllPublications)) { _ in
            selectAllPublications()
        }
    }

    // MARK: - Notification Handlers

    private func selectAllPublications() {
        viewModel.selectedPublicationIDs = Set(viewModel.publications.map { $0.id })
    }

    private func toggleReadStatusForSelected() {
        guard !viewModel.selectedPublicationIDs.isEmpty else { return }

        Task {
            // Apple Mail behavior: if ANY are unread, mark ALL as read
            // If ALL are read, mark ALL as unread
            await libraryViewModel.smartToggleReadStatus(viewModel.selectedPublicationIDs)
        }
    }

    private func copySelectedPublications() async {
        guard !viewModel.selectedPublicationIDs.isEmpty else { return }
        await libraryViewModel.copyToClipboard(viewModel.selectedPublicationIDs)
    }

    private func cutSelectedPublications() async {
        guard !viewModel.selectedPublicationIDs.isEmpty else { return }
        await libraryViewModel.cutToClipboard(viewModel.selectedPublicationIDs)
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        @Bindable var viewModel = viewModel

        if viewModel.isSearching {
            ProgressView("Searching...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.publications.isEmpty {
            emptyState
        } else {
            PublicationListView(
                publications: viewModel.publications,
                selection: $viewModel.selectedPublicationIDs,
                selectedPublication: $selectedPublication,
                library: libraryManager.activeLibrary,
                allLibraries: libraryManager.libraries,
                showImportButton: false,  // Search view doesn't need import
                showSortMenu: true,
                emptyStateMessage: "No Results",
                emptyStateDescription: "Enter a query to search across multiple sources.",
                listID: libraryManager.activeLibrary?.lastSearchCollection.map { .lastSearch($0.id) },
                filterScope: .constant(.current),  // Search results are already filtered
                onDelete: { ids in
                    await libraryViewModel.delete(ids: ids)
                },
                onToggleRead: { publication in
                    await libraryViewModel.toggleReadStatus(publication)
                },
                onCopy: { ids in
                    await libraryViewModel.copyToClipboard(ids)
                },
                onCut: { ids in
                    await libraryViewModel.cutToClipboard(ids)
                },
                onPaste: {
                    try? await libraryViewModel.pasteFromClipboard()
                },
                onAddToLibrary: { ids, targetLibrary in
                    await libraryViewModel.addToLibrary(ids, library: targetLibrary)
                },
                onAddToCollection: { ids, collection in
                    await libraryViewModel.addToCollection(ids, collection: collection)
                },
                onRemoveFromAllCollections: { ids in
                    await libraryViewModel.removeFromAllCollections(ids)
                },
                onOpenPDF: { publication in
                    openPDF(for: publication)
                },
                onListDrop: { providers, target in
                    // Handle PDF drop on search results for import
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
                                    // Use active library as fallback
                                    dropPreviewTargetLibraryID = libraryManager.activeLibrary?.id
                                }
                                showingDropPreview = true
                            }
                        }
                    }
                }
            )
            .sheet(isPresented: $showingDropPreview) {
                searchDropPreviewSheetContent
            }
        }
    }

    // MARK: - Drop Preview Sheet

    /// Drop preview sheet content for search list drops
    @ViewBuilder
    private var searchDropPreviewSheetContent: some View {
        if let libraryID = dropPreviewTargetLibraryID {
            DropPreviewSheet(
                preview: $dragDropCoordinator.pendingPreview,
                libraryID: libraryID,
                coordinator: dragDropCoordinator
            )
            .onDisappear {
                dropPreviewTargetLibraryID = nil
            }
        } else if let library = libraryManager.activeLibrary {
            // Fallback: use active library
            DropPreviewSheet(
                preview: $dragDropCoordinator.pendingPreview,
                libraryID: library.id,
                coordinator: dragDropCoordinator
            )
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

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Search Publications", systemImage: "magnifyingglass")
        } description: {
            Text("Enter a query to search across multiple sources.")
        }
    }

    // MARK: - Actions

    private func openPDF(for publication: CDPublication) {
        // Check user preference for opening PDFs
        let openExternally = UserDefaults.standard.bool(forKey: "openPDFInExternalViewer")

        if openExternally {
            // Open in external viewer (Preview, Adobe, etc.)
            if let linkedFiles = publication.linkedFiles,
               let pdfFile = linkedFiles.first(where: { $0.isPDF }),
               let libraryURL = libraryManager.activeLibrary?.folderURL {
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
}

// MARK: - Preview

#Preview {
    SearchResultsListView(selectedPublication: .constant(nil))
        .environment(SearchViewModel(
            sourceManager: SourceManager(),
            deduplicationService: DeduplicationService(),
            repository: PublicationRepository()
        ))
        .environment(LibraryViewModel(repository: PublicationRepository()))
        .environment(LibraryManager())
}
