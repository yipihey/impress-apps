//
//  SectionContentView.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

import SwiftUI
import PublicationManagerCore
import CoreData

/// Reusable 2-column layout for each tab in the TabView sidebar.
///
/// Composes `UnifiedPublicationListWrapper` (list) + `DetailView` (detail)
/// into a NavigationSplitView. Each tab provides a `PublicationSource` and
/// gets a full publication browsing experience.
struct SectionContentView: View {

    // MARK: - Properties

    let source: PublicationSource

    /// Library ID for the detail view (needed to construct LocalPaper).
    /// For flagged/search tabs, falls back to the active library.
    let libraryID: UUID?

    // MARK: - Environment

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - State

    @State private var selectedPublicationIDs = Set<UUID>()
    @State private var displayedPublicationID: UUID?
    @State private var selectedDetailTab: DetailTab = .info

    // MARK: - Derived

    private var selectedPublicationID: UUID? {
        selectedPublicationIDs.first
    }

    private var selectedPublicationBinding: Binding<CDPublication?> {
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

    private var displayedPublication: CDPublication? {
        guard let id = displayedPublicationID else { return nil }
        return libraryViewModel.publication(for: id)
    }

    private var selectedPublications: [CDPublication] {
        selectedPublicationIDs.compactMap { libraryViewModel.publication(for: $0) }
    }

    private var isMultiSelection: Bool {
        selectedPublicationIDs.count > 1
    }

    /// Resolve the library ID, falling back to active library for cross-library sources
    private var effectiveLibraryID: UUID? {
        libraryID ?? libraryManager.activeLibrary?.id
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            UnifiedPublicationListWrapper(
                source: source,
                selectedPublication: selectedPublicationBinding,
                selectedPublicationIDs: $selectedPublicationIDs,
                onDownloadPDFs: handleDownloadPDFs
            )
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 450)
            .clipped()

            detailView
                .id(displayedPublicationID)
                .transaction { $0.animation = nil }
                .frame(minWidth: 300, idealWidth: 500)
                .clipped()
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
            guard let publication = displayedPublication else { return }
            DetailWindowController.shared.closeWindows(for: publication)
        }
        #endif
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if isMultiSelection && selectedDetailTab == .bibtex {
            MultiSelectionBibTeXView(
                publications: selectedPublications,
                onDownloadPDFs: {
                    handleDownloadPDFs(selectedPublicationIDs)
                }
            )
            .id(selectedPublicationIDs)
        } else if let publication = displayedPublication,
                  !publication.isDeleted,
                  publication.managedObjectContext != nil,
                  let libID = effectiveLibraryID,
                  let detail = DetailView(
                      publication: publication,
                      libraryID: libID,
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

    // MARK: - Window Management

    #if os(macOS)
    private func openDetachedTab(_ tab: DetachedTab) {
        guard let publication = displayedPublication else { return }
        DetailWindowController.shared.openTab(
            tab, for: publication, library: libraryManager.activeLibrary,
            libraryViewModel: libraryViewModel, libraryManager: libraryManager
        )
    }
    #endif

    // MARK: - Actions

    private func handleDownloadPDFs(_ ids: Set<UUID>) {
        // Batch download handled by posting notification (picked up by ContentView)
        let publications = ids.compactMap { libraryViewModel.publication(for: $0) }
        guard !publications.isEmpty else { return }
        NotificationCenter.default.post(
            name: .showBatchDownload,
            object: nil,
            userInfo: ["publications": publications, "libraryID": effectiveLibraryID as Any]
        )
    }
}
