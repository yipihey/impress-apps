//
//  ADSPaperSearchView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import SwiftUI

#if os(macOS)

/// Identifier lookup form for finding specific papers by bibcode, DOI, or arXiv ID
public struct ADSPaperSearchView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(LibraryViewModel.self) private var libraryViewModel

    // MARK: - Bindings

    @Binding var selectedPublication: CDPublication?

    // MARK: - Form State

    @State private var bibcode: String = ""
    @State private var doi: String = ""
    @State private var arxivID: String = ""

    // MARK: - Initialization

    public init(selectedPublication: Binding<CDPublication?>) {
        self._selectedPublication = selectedPublication
    }

    // MARK: - State for Layout

    @State private var isFormExpanded: Bool = true

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        VStack(spacing: 0) {
            // Collapsible form section
            DisclosureGroup(isExpanded: $isFormExpanded) {
                formContent
            } label: {
                HStack {
                    Label("Paper Lookup", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    if !isFormEmpty {
                        Text("ID entered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()

            Divider()

            // Results section
            resultsContent
        }
    }

    // MARK: - Form Content

    @ViewBuilder
    private var formContent: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find a specific paper by its identifier")
                        .font(.headline)
                    Text("Enter any of the identifiers below to locate a paper.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bibcode")
                        .font(.headline)
                    TextField("e.g., 2019ApJ...886L...1V", text: $bibcode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("ADS bibliographic code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DOI")
                        .font(.headline)
                    TextField("e.g., 10.1086/345794", text: $doi)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Digital Object Identifier")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("arXiv ID")
                        .font(.headline)
                    TextField("e.g., 1108.0669 or astro-ph/0702089", text: $arxivID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("arXiv preprint identifier (new or old format)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Action buttons
            Section {
                HStack {
                    Button("Clear") {
                        clearForm()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Find Paper") {
                        performSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFormEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Results Content

    @ViewBuilder
    private var resultsContent: some View {
        @Bindable var viewModel = searchViewModel

        if viewModel.isSearching {
            ProgressView("Searching...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.publications.isEmpty && viewModel.query.isEmpty {
            ContentUnavailableView {
                Label("ADS Paper Lookup", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Enter a bibcode, DOI, or arXiv ID to find a specific paper.")
            }
        } else if viewModel.publications.isEmpty {
            ContentUnavailableView {
                Label("Paper Not Found", systemImage: "questionmark.circle")
            } description: {
                Text("No paper found with the given identifier. Check for typos.")
            }
        } else {
            PublicationListView(
                publications: viewModel.publications,
                selection: $viewModel.selectedPublicationIDs,
                selectedPublication: $selectedPublication,
                library: libraryManager.activeLibrary,
                allLibraries: libraryManager.libraries,
                showImportButton: false,
                showSortMenu: false,  // Usually just one result
                emptyStateMessage: "No Paper Found",
                emptyStateDescription: "Enter a bibcode, DOI, or arXiv ID.",
                listID: libraryManager.activeLibrary?.lastSearchCollection.map { .lastSearch($0.id) },
                filterScope: .constant(.current),
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
                onOpenPDF: { _ in }
            )
        }
    }

    // MARK: - Computed Properties

    private var isFormEmpty: Bool {
        SearchFormQueryBuilder.isPaperFormEmpty(
            bibcode: bibcode,
            doi: doi,
            arxivID: arxivID
        )
    }

    // MARK: - Actions

    private func performSearch() {
        let query = SearchFormQueryBuilder.buildPaperQuery(
            bibcode: bibcode,
            doi: doi,
            arxivID: arxivID
        )

        searchViewModel.query = query
        // Paper form uses ADS as the primary source (best for identifier lookup)
        searchViewModel.selectedSourceIDs = ["ads"]

        Task {
            await searchViewModel.search()
        }
    }

    private func clearForm() {
        bibcode = ""
        doi = ""
        arxivID = ""
    }
}

// MARK: - ADS Paper Search Form View (Detail Pane)

/// Form-only view for the detail pane (right side)
/// Results are shown in the middle pane via SearchResultsListView
public struct ADSPaperSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Label("ADS Paper Lookup", systemImage: "doc.text.magnifyingglass")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Find a specific paper by its identifier")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Bibcode
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bibcode")
                        .font(.headline)
                    TextField("e.g., 2019ApJ...886L...1V", text: $viewModel.paperFormState.bibcode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("ADS bibliographic code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // DOI
                VStack(alignment: .leading, spacing: 4) {
                    Text("DOI")
                        .font(.headline)
                    TextField("e.g., 10.1086/345794", text: $viewModel.paperFormState.doi)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Digital Object Identifier")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // arXiv ID
                VStack(alignment: .leading, spacing: 4) {
                    Text("arXiv ID")
                        .font(.headline)
                    TextField("e.g., 1108.0669 or astro-ph/0702089", text: $viewModel.paperFormState.arxivID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("arXiv preprint identifier (new or old format)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Max Results
                VStack(alignment: .leading, spacing: 8) {
                    Text("Max Results")
                        .font(.headline)

                    HStack {
                        TextField("default", value: $viewModel.paperFormState.maxResults, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("(0 = use default)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                    .padding(.vertical, 8)

                // Action buttons
                HStack {
                    Button("Clear") {
                        clearForm()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Find Paper") {
                        performSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFormEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            searchViewModel.setLibraryManager(libraryManager)
        }
    }

    // MARK: - Computed Properties

    private var isFormEmpty: Bool {
        searchViewModel.paperFormState.isEmpty
    }

    // MARK: - Actions

    private func performSearch() {
        let state = searchViewModel.paperFormState
        let query = SearchFormQueryBuilder.buildPaperQuery(
            bibcode: state.bibcode,
            doi: state.doi,
            arxivID: state.arxivID
        )

        searchViewModel.query = query
        searchViewModel.selectedSourceIDs = ["ads"]

        Task {
            await searchViewModel.search()
        }
    }

    private func clearForm() {
        searchViewModel.paperFormState.clear()
    }
}

#elseif os(iOS)

// MARK: - iOS ADS Paper Search Form View

/// Form-only view for iOS - Find papers by bibcode, DOI, or arXiv ID
public struct ADSPaperSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        Form {
            // Bibcode Section
            Section {
                TextField("e.g., 2019ApJ...886L...1V", text: $viewModel.paperFormState.bibcode)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("Bibcode")
            } footer: {
                Text("ADS bibliographic code")
            }

            // DOI Section
            Section {
                TextField("e.g., 10.1086/345794", text: $viewModel.paperFormState.doi)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("DOI")
            } footer: {
                Text("Digital Object Identifier")
            }

            // arXiv ID Section
            Section {
                TextField("e.g., 1108.0669 or astro-ph/0702089", text: $viewModel.paperFormState.arxivID)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("arXiv ID")
            } footer: {
                Text("arXiv preprint identifier (new or old format)")
            }

            // Max Results
            Section {
                HStack {
                    Text("Max Results")
                    Spacer()
                    TextField("default", value: $viewModel.paperFormState.maxResults, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } footer: {
                Text("0 = use default from settings")
            }

            // Action Buttons Section
            Section {
                Button {
                    performSearch()
                } label: {
                    HStack {
                        Spacer()
                        Text("Find Paper")
                        Spacer()
                    }
                }
                .disabled(isFormEmpty)

                Button("Clear", role: .destructive) {
                    searchViewModel.paperFormState.clear()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Paper Lookup")
        .task {
            searchViewModel.setLibraryManager(libraryManager)
        }
    }

    // MARK: - Computed Properties

    private var isFormEmpty: Bool {
        searchViewModel.paperFormState.isEmpty
    }

    // MARK: - Actions

    private func performSearch() {
        let state = searchViewModel.paperFormState
        let query = SearchFormQueryBuilder.buildPaperQuery(
            bibcode: state.bibcode,
            doi: state.doi,
            arxivID: state.arxivID
        )

        searchViewModel.query = query
        searchViewModel.selectedSourceIDs = ["ads"]

        Task {
            await searchViewModel.search()
        }
    }

}

#endif  // os(macOS/iOS)
