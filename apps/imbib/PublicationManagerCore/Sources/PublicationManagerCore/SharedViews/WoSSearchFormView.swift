//
//  WoSSearchFormView.swift
//  PublicationManagerCore
//
//  Search form for Web of Science with query assistance.
//  Supports WoS advanced query syntax.
//

import SwiftUI

#if os(macOS)

/// Search form for Web of Science queries (macOS)
public struct WoSSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Local State

    @State private var availableSources: [SourceMetadata] = []
    @State private var queryAssistanceViewModel = QueryAssistanceViewModel()
    @FocusState private var isSearchFocused: Bool

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Label("Web of Science", systemImage: "globe.americas")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Search peer-reviewed research with WoS query syntax")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Search field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Query")
                        .font(.headline)

                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("e.g., AU=Einstein AND PY=1905-1910", text: $viewModel.modernFormState.searchText)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .onSubmit {
                                performSearch()
                            }
                            .onChange(of: viewModel.modernFormState.searchText) { _, newValue in
                                queryAssistanceViewModel.updateQuery(newValue)
                            }
                            .accessibilityIdentifier(AccessibilityID.Search.WoS.queryField)

                        // Compact preview indicator
                        CompactQueryAssistanceView(viewModel: queryAssistanceViewModel)

                        if !viewModel.modernFormState.searchText.isEmpty {
                            Button {
                                viewModel.modernFormState.clear()
                                queryAssistanceViewModel.clear()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                    // Query assistance feedback
                    QueryAssistanceView(viewModel: queryAssistanceViewModel, showPreview: false)
                }

                // Source selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sources")
                        .font(.headline)

                    SourceSelectionGrid(availableSources: availableSources)
                }

                // Max Results
                VStack(alignment: .leading, spacing: 8) {
                    Text("Max Results")
                        .font(.headline)

                    HStack {
                        TextField("default", value: $viewModel.modernFormState.maxResults, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("(0 = use default, max 100 per request)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Query syntax help
                VStack(alignment: .leading, spacing: 8) {
                    Text("WoS Query Syntax")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        syntaxHelpRow("TS=quantum computing", "Topic (title, abstract, keywords)")
                        syntaxHelpRow("TI=\"neural network\"", "Title only")
                        syntaxHelpRow("AU=Einstein, Albert", "Author name")
                        syntaxHelpRow("AI=0000-0001-2345-6789", "Author ORCID")
                        syntaxHelpRow("PY=2020-2024", "Publication year range")
                        syntaxHelpRow("DO=10.1038/nature", "DOI")
                        syntaxHelpRow("SO=Nature", "Journal/Source name")
                        syntaxHelpRow("OG=MIT", "Organization")
                        syntaxHelpRow("FO=NSF", "Funding agency")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Operators
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operators")
                            .font(.caption.bold())
                            .padding(.bottom, 2)
                        syntaxHelpRow("AND, OR, NOT", "Boolean (must be uppercase)")
                        syntaxHelpRow("NEAR/5", "Proximity within n words")
                        syntaxHelpRow("\"exact phrase\"", "Phrase search")
                        syntaxHelpRow("comput*", "Wildcard (right truncation)")
                        syntaxHelpRow("wom?n", "Single character wildcard")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Divider()
                    .padding(.vertical, 8)

                // Edit mode header
                if searchViewModel.isEditMode, let smartSearch = searchViewModel.editingSmartSearch {
                    HStack {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Editing: \(smartSearch.name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            searchViewModel.exitEditMode()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Action buttons
                HStack {
                    Button("Clear") {
                        clearForm()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if searchViewModel.isEditMode {
                        Button("Save") {
                            searchViewModel.saveToSmartSearch()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFormEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button("Search") {
                            performSearch()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFormEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier(AccessibilityID.Search.searchButton)
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            searchViewModel.setLibraryManager(libraryManager)
            availableSources = await searchViewModel.availableSources
            // Initialize query assistance for WoS
            queryAssistanceViewModel.setSource(.wos)
            await QueryAssistanceService.shared.register(WoSQueryAssistant())
        }
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func syntaxHelpRow(_ syntax: String, _ description: String) -> some View {
        HStack(alignment: .top) {
            Text(syntax)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 180, alignment: .leading)
            Text("—")
            Text(description)
        }
    }

    // MARK: - Computed Properties

    private var isFormEmpty: Bool {
        searchViewModel.modernFormState.isEmpty
    }

    // MARK: - Actions

    private func performSearch() {
        guard !isFormEmpty else { return }
        searchViewModel.query = searchViewModel.modernFormState.searchText
        Task {
            await searchViewModel.search()
        }
    }

    private func clearForm() {
        searchViewModel.modernFormState.clear()
        searchViewModel.clearSourceSelection()
    }
}

#elseif os(iOS)

/// Search form for Web of Science queries (iOS)
public struct WoSSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Local State

    @State private var availableSources: [SourceMetadata] = []
    @State private var queryAssistanceViewModel = QueryAssistanceViewModel()
    @FocusState private var isSearchFocused: Bool

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        Form {
            // Search field section
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("e.g., AU=Einstein AND PY=1905", text: $viewModel.modernFormState.searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            performSearch()
                        }
                        .onChange(of: viewModel.modernFormState.searchText) { _, newValue in
                            queryAssistanceViewModel.updateQuery(newValue)
                        }

                    CompactQueryAssistanceView(viewModel: queryAssistanceViewModel)

                    if !viewModel.modernFormState.searchText.isEmpty {
                        Button {
                            viewModel.modernFormState.clear()
                            queryAssistanceViewModel.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !queryAssistanceViewModel.isEmpty {
                    QueryAssistanceView(viewModel: queryAssistanceViewModel, showPreview: false, maxIssues: 2)
                }
            } header: {
                Text("Search Query")
            } footer: {
                Text("WoS advanced query syntax with field codes")
            }

            // Source selection
            Section("Sources") {
                IOSSourceSelectionGrid(availableSources: availableSources)
            }

            // Max Results
            Section {
                HStack {
                    Text("Max Results")
                    Spacer()
                    TextField("default", value: $viewModel.modernFormState.maxResults, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } footer: {
                Text("0 = use default (max 100 per request)")
            }

            // Query syntax help
            Section("WoS Query Syntax") {
                VStack(alignment: .leading, spacing: 6) {
                    syntaxHelpRow("TS=topic", "Topic search")
                    syntaxHelpRow("TI=\"title\"", "Title only")
                    syntaxHelpRow("AU=Author", "Author name")
                    syntaxHelpRow("PY=2020-2024", "Year range")
                    syntaxHelpRow("DO=10.1038/...", "DOI")
                    syntaxHelpRow("SO=Nature", "Journal")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Operators")
                        .font(.caption.bold())
                    syntaxHelpRow("AND OR NOT", "Boolean (uppercase)")
                    syntaxHelpRow("NEAR/5", "Proximity")
                    syntaxHelpRow("comput*", "Wildcard")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Edit mode indicator
            if searchViewModel.isEditMode, let smartSearch = searchViewModel.editingSmartSearch {
                Section {
                    HStack {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Editing: \(smartSearch.name)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            searchViewModel.exitEditMode()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }

            // Action buttons
            Section {
                if searchViewModel.isEditMode {
                    Button("Save") {
                        searchViewModel.saveToSmartSearch()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isFormEmpty)
                } else {
                    Button {
                        performSearch()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Search")
                            Spacer()
                        }
                    }
                    .disabled(isFormEmpty)
                }

                Button("Clear", role: .destructive) {
                    clearForm()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Web of Science")
        .task {
            searchViewModel.setLibraryManager(libraryManager)
            availableSources = await searchViewModel.availableSources
            queryAssistanceViewModel.setSource(.wos)
            await QueryAssistanceService.shared.register(WoSQueryAssistant())
        }
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func syntaxHelpRow(_ syntax: String, _ description: String) -> some View {
        HStack(alignment: .top) {
            Text(syntax)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Text("—")
            Text(description)
        }
    }

    // MARK: - Computed Properties

    private var isFormEmpty: Bool {
        searchViewModel.modernFormState.isEmpty
    }

    // MARK: - Actions

    private func performSearch() {
        guard !isFormEmpty else { return }
        searchViewModel.query = searchViewModel.modernFormState.searchText
        Task {
            await searchViewModel.search()
        }
    }

    private func clearForm() {
        searchViewModel.modernFormState.clear()
        searchViewModel.clearSourceSelection()
    }
}

#endif  // os(iOS/macOS)
