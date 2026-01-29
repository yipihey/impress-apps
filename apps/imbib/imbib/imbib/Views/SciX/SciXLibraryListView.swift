//
//  SciXLibraryListView.swift
//  imbib
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import CoreData
import PublicationManagerCore

/// List view for displaying papers from a SciX online library.
struct SciXLibraryListView: View {

    // MARK: - Properties

    let library: CDSciXLibrary
    @Binding var selection: CDPublication?
    @Binding var multiSelection: Set<UUID>

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var publications: [CDPublication] = []
    @State private var isLoading = false
    @State private var error: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header with library info and sync status
            header

            Divider()

            // Publications list
            if isLoading {
                ProgressView("Loading papers...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if publications.isEmpty {
                ContentUnavailableView(
                    "No Papers",
                    systemImage: "doc.text",
                    description: Text("This SciX library is empty")
                )
            } else {
                PublicationListView(
                    publications: publications,
                    selection: $multiSelection,
                    selectedPublication: $selection,
                    library: nil,  // SciX libraries don't have a local CDLibrary
                    allLibraries: libraryManager.libraries,
                    showImportButton: false,
                    showSortMenu: true,
                    emptyStateMessage: "No Papers",
                    emptyStateDescription: "This SciX library is empty.",
                    listID: .scixLibrary(library.id),
                    filterScope: .constant(.current),  // SciX libraries are remote, scope doesn't apply
                    onDelete: nil,  // SciX deletion handled via pending changes
                    onAddToLibrary: { ids, targetLibrary in
                        await copyToLocalLibrary(ids: ids, library: targetLibrary)
                    },
                    onAddToCollection: nil  // No local collections for SciX papers
                )
            }
        }
        .onAppear {
            loadPublications()
            // Auto-refresh if library has no cached publications but should have some
            if publications.isEmpty && library.documentCount > 0 {
                Task {
                    await refreshFromServer()
                }
            }
        }
        .onChange(of: library.id) {
            loadPublications()
            // Auto-refresh when switching to a library with no cached publications
            if publications.isEmpty && library.documentCount > 0 {
                Task {
                    await refreshFromServer()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // Cloud icon
            Image(systemName: "cloud")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(library.displayName)
                    .font(.headline)

                HStack(spacing: 8) {
                    // Permission badge
                    Label(library.permissionLevelEnum.rawValue.capitalized, systemImage: library.permissionLevelEnum.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Sync status
                    syncStatusBadge
                }
            }

            Spacer()

            // Refresh button
            Button {
                Task {
                    await refreshFromServer()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)

            // Pending changes indicator
            if library.hasPendingChanges {
                Button {
                    // TODO: Show push confirmation sheet
                } label: {
                    Label("\(library.pendingChangeCount)", systemImage: "arrow.up.circle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Pending changes to sync")
            }
        }
        .padding()
    }

    @ViewBuilder
    private var syncStatusBadge: some View {
        switch library.syncStateEnum {
        case .synced:
            Label("Synced", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .pending:
            Label("Pending", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.orange)
        case .error:
            Label("Error", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Data Loading

    private func loadPublications() {
        // Refresh the managed object to get latest relationships from Core Data
        if let context = library.managedObjectContext {
            context.refresh(library, mergeChanges: true)
        }
        publications = Array(library.publications ?? [])
            .sorted { ($0.dateAdded) > ($1.dateAdded) }
    }

    private func refreshFromServer() async {
        isLoading = true
        error = nil

        do {
            try await SciXSyncManager.shared.pullLibraryPapers(libraryID: library.remoteID)
            loadPublications()
        } catch let scixError as SciXLibraryError {
            error = scixError.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Actions

    private func copyToLocalLibrary(ids: Set<UUID>, library: CDLibrary) async {
        // Copy selected papers to a local library
        for publication in publications where ids.contains(publication.id) {
            publication.addToLibrary(library)
        }

        try? PersistenceController.shared.viewContext.save()
    }
}

