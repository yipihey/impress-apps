//
//  SearchTabContent.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

import SwiftUI
import PublicationManagerCore
import CoreData

/// Content view for a search form tab.
///
/// Shows the search form initially, switches to results after search executes.
/// Reuses the existing search form views from ContentView.
struct SearchTabContent: View {

    // MARK: - Properties

    let formType: SearchFormType

    // MARK: - Environment

    @Environment(LibraryManager.self) private var libraryManager
    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(SearchViewModel.self) private var searchViewModel

    // MARK: - State

    @State private var showForm = true
    @State private var selectedPublicationIDs = Set<UUID>()
    @State private var displayedPublicationID: UUID?
    @State private var selectedDetailTab: DetailTab = .info

    // MARK: - Derived

    private var selectedPublicationBinding: Binding<CDPublication?> {
        Binding(
            get: {
                guard let id = selectedPublicationIDs.first else { return nil }
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

    private var displayedPublication: CDPublication? {
        guard let id = displayedPublicationID else { return nil }
        return libraryViewModel.publication(for: id)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if showForm {
                searchFormView
            } else {
                HSplitView {
                    resultsView
                        .frame(minWidth: 250, idealWidth: 300, maxWidth: 450)

                    detailView
                        .id(displayedPublicationID)
                        .transaction { $0.animation = nil }
                        .frame(minWidth: 300, idealWidth: 500)
                }
            }
        }
        .onChange(of: searchViewModel.isSearching) { wasSearching, isSearching in
            if wasSearching && !isSearching {
                showForm = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSearchFormView)) { _ in
            showForm = true
        }
    }

    // MARK: - Search Form

    @ViewBuilder
    private var searchFormView: some View {
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

    // MARK: - Results View

    @ViewBuilder
    private var resultsView: some View {
        if let lastSearchCollection = libraryManager.activeLibrary?.lastSearchCollection {
            UnifiedPublicationListWrapper(
                source: .lastSearch(lastSearchCollection),
                selectedPublication: selectedPublicationBinding,
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
        if let publication = displayedPublication,
           !publication.isDeleted,
           publication.managedObjectContext != nil,
           let libID = libraryManager.activeLibrary?.id,
           let detail = DetailView(
               publication: publication,
               libraryID: libID,
               selectedTab: $selectedDetailTab
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
}
