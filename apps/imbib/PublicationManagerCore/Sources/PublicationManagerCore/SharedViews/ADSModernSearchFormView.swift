//
//  ADSModernSearchFormView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import SwiftUI

#if os(macOS)

/// Modern single-box search form for the detail pane (right side)
/// Results are shown in the middle pane via SearchResultsListView
public struct ADSModernSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Local State (not persisted)

    @State private var availableSources: [SourceMetadata] = []
    @State private var queryAssistanceViewModel = QueryAssistanceViewModel()
    @FocusState private var isSearchFocused: Bool

    // MARK: - Mode & Feed Properties

    public let mode: SearchFormMode
    public let editingFeedID: UUID?

    @State private var feedName: String = ""
    @State private var refreshPreset: RefreshIntervalPreset = .daily
    @State private var isCreating: Bool = false

    // MARK: - Initialization

    public init(mode: SearchFormMode = .explorationSearch, editingFeedID: UUID? = nil) {
        self.mode = mode
        self.editingFeedID = editingFeedID
    }

    // MARK: - Body

    public var body: some View {
        @Bindable var viewModel = searchViewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Label("ADS Modern Search", systemImage: "magnifyingglass")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Single search box with powerful query syntax")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Feed settings (shown when creating a feed)
                if mode == .inboxFeed {
                    feedSettingsSection
                }

                // Search field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Query")
                        .font(.headline)

                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("e.g., author:\"Einstein\" year:1905", text: $viewModel.modernFormState.searchText)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .onSubmit {
                                performSearch()
                            }
                            .onChange(of: viewModel.modernFormState.searchText) { _, newValue in
                                queryAssistanceViewModel.updateQuery(newValue)
                            }
                            .accessibilityIdentifier(AccessibilityID.Search.ADS.queryField)

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
                        Text("(0 = use default)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Query syntax help
                VStack(alignment: .leading, spacing: 8) {
                    Text("Query Syntax")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        syntaxHelpRow("author:\"Last, First\"", "Search by author name")
                        syntaxHelpRow("title:\"keywords\"", "Search in title")
                        syntaxHelpRow("abs:\"abstract words\"", "Search in abstract")
                        syntaxHelpRow("year:2020-2024", "Publication year range")
                        syntaxHelpRow("bibcode:2019ApJ...", "Search by bibcode")
                        syntaxHelpRow("doi:10.1086/...", "Search by DOI")
                        syntaxHelpRow("arXiv:1234.5678", "Search by arXiv ID")
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

                    if editingFeedID != nil {
                        Button("Save Feed") { saveFeed() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isFormEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                    } else if searchViewModel.isEditMode {
                        Button("Save") { searchViewModel.saveToSmartSearch() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isFormEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                    } else if mode == .inboxFeed {
                        Button {
                            createFeed()
                        } label: {
                            if isCreating { ProgressView().controlSize(.small) }
                            else { Text("Create Feed") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFormEmpty || isCreating)
                        .keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button("Search") { performSearch() }
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
            // Initialize query assistance for ADS
            queryAssistanceViewModel.setSource(.ads)
            await QueryAssistanceService.shared.register(ADSQueryAssistant())
        }
        .onAppear {
            isSearchFocused = true
            if let feedID = editingFeedID {
                loadFeedForEditing(feedID)
            }
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func syntaxHelpRow(_ syntax: String, _ description: String) -> some View {
        HStack(alignment: .top) {
            Text(syntax)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 160, alignment: .leading)
            Text("—")
            Text(description)
        }
    }

    @ViewBuilder
    private var feedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feed Settings")
                .font(.headline)

            TextField("Feed Name", text: $feedName)
                .textFieldStyle(.roundedBorder)

            Picker("Refresh Interval", selection: $refreshPreset) {
                ForEach(RefreshIntervalPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .frame(width: 200)
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

    private func createFeed() {
        guard !isFormEmpty else { return }
        isCreating = true

        let query = searchViewModel.modernFormState.searchText
        let sourceIDs = Array(searchViewModel.selectedSourceIDs)
        let name = feedName.isEmpty ? "ADS: \(query.prefix(40))" : feedName
        let maxResults: Int16? = searchViewModel.modernFormState.maxResults > 0 ? Int16(searchViewModel.modernFormState.maxResults) : nil

        Task {
            let feed = RustStoreAdapter.shared.createInboxFeed(
                name: name,
                query: query,
                sourceIDs: sourceIDs.isEmpty ? ["ads"] : sourceIDs,
                maxResults: maxResults,
                refreshIntervalSeconds: Int64(refreshPreset.rawValue)
            )
            if let feed {
                // Run initial fetch
                if let fetchService = await InboxCoordinator.shared.paperFetchService {
                    _ = try? await fetchService.fetchForInbox(smartSearchID: feed.id)
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
                    NotificationCenter.default.post(name: .navigateToSmartSearch, object: feed.id)
                    clearForm()
                }
            }
            await MainActor.run { isCreating = false }
        }
    }

    private func saveFeed() {
        guard let feedID = editingFeedID, !isFormEmpty else { return }
        let query = searchViewModel.modernFormState.searchText
        let sourceIDs = Array(searchViewModel.selectedSourceIDs)
        let name = feedName.isEmpty ? "ADS: \(query.prefix(40))" : feedName
        let maxResults: Int16 = searchViewModel.modernFormState.maxResults > 0 ? Int16(searchViewModel.modernFormState.maxResults) : 0

        RustStoreAdapter.shared.updateSmartSearch(feedID, name: name, query: query, maxResults: maxResults)

        // Update source IDs
        let sourceIdsJson: String? = sourceIDs.isEmpty ? nil : {
            if let data = try? JSONEncoder().encode(sourceIDs) {
                return String(data: data, encoding: .utf8)
            }
            return nil
        }()
        if let json = sourceIdsJson {
            RustStoreAdapter.shared.updateField(id: feedID, field: "source_ids_json", value: json)
        }

        // Update refresh interval
        RustStoreAdapter.shared.updateIntField(id: feedID, field: "refresh_interval_seconds", value: Int64(refreshPreset.rawValue))

        NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
    }

    private func loadFeedForEditing(_ feedID: UUID) {
        guard let feed = RustStoreAdapter.shared.getSmartSearch(id: feedID) else { return }
        feedName = feed.name
        searchViewModel.modernFormState.searchText = feed.query
        searchViewModel.modernFormState.maxResults = Int(feed.maxResults)

        // Load source IDs
        for sourceID in feed.sourceIDs {
            searchViewModel.selectedSourceIDs.insert(sourceID)
        }

        // Load refresh interval
        if let preset = RefreshIntervalPreset(rawValue: Int32(feed.refreshIntervalSeconds)) {
            refreshPreset = preset
        }
    }
}

// MARK: - Source Selection Grid

struct SourceSelectionGrid: View {

    @Environment(SearchViewModel.self) private var viewModel
    let availableSources: [SourceMetadata]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
            ForEach(availableSources, id: \.id) { source in
                SourceToggleChip(
                    source: source,
                    isSelected: viewModel.selectedSourceIDs.contains(source.id)
                ) {
                    viewModel.toggleSource(source.id)
                }
            }
        }

        HStack {
            Button("Select All") {
                Task {
                    await viewModel.selectAllSources()
                }
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button("Clear") {
                viewModel.clearSourceSelection()
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
    }
}

// MARK: - Source Toggle Chip

struct SourceToggleChip: View {
    let source: SourceMetadata
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: source.iconName)
                    .font(.caption)
                Text(source.name)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

#elseif os(iOS)

/// Modern single-box search form for iOS
/// Results are shown via navigation to search results
public struct ADSModernSearchFormView: View {

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
                    TextField("e.g., author:\"Einstein\" year:1905", text: $viewModel.modernFormState.searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            performSearch()
                        }
                        .onChange(of: viewModel.modernFormState.searchText) { _, newValue in
                            queryAssistanceViewModel.updateQuery(newValue)
                        }

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

                // Query assistance feedback (inline in form)
                if !queryAssistanceViewModel.isEmpty {
                    QueryAssistanceView(viewModel: queryAssistanceViewModel, showPreview: false, maxIssues: 2)
                }
            } header: {
                Text("Search Query")
            } footer: {
                Text("Single search box with powerful query syntax")
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
                Text("0 = use default from settings")
            }

            // Query syntax help
            Section("Query Syntax") {
                VStack(alignment: .leading, spacing: 6) {
                    syntaxHelpRow("author:\"Last, First\"", "Search by author")
                    syntaxHelpRow("title:\"keywords\"", "Search in title")
                    syntaxHelpRow("abs:\"words\"", "Search abstract")
                    syntaxHelpRow("year:2020-2024", "Year range")
                    syntaxHelpRow("bibcode:2019ApJ...", "By bibcode")
                    syntaxHelpRow("doi:10.1086/...", "By DOI")
                    syntaxHelpRow("arXiv:1234.5678", "By arXiv ID")
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
        .navigationTitle("ADS Modern")
        .task {
            searchViewModel.setLibraryManager(libraryManager)
            availableSources = await searchViewModel.availableSources
            // Initialize query assistance for ADS
            queryAssistanceViewModel.setSource(.ads)
            await QueryAssistanceService.shared.register(ADSQueryAssistant())
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
                .frame(width: 140, alignment: .leading)
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

// MARK: - iOS Source Selection Grid

struct IOSSourceSelectionGrid: View {
    @Environment(SearchViewModel.self) private var viewModel
    let availableSources: [SourceMetadata]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
            ForEach(availableSources, id: \.id) { source in
                IOSSourceToggleChip(
                    source: source,
                    isSelected: viewModel.selectedSourceIDs.contains(source.id)
                ) {
                    viewModel.toggleSource(source.id)
                }
            }
        }
        .padding(.vertical, 4)

        HStack {
            Button("Select All") {
                Task {
                    await viewModel.selectAllSources()
                }
            }
            .font(.caption)

            Spacer()

            Button("Clear") {
                viewModel.clearSourceSelection()
            }
            .font(.caption)
        }
    }
}

// MARK: - iOS Source Toggle Chip

struct IOSSourceToggleChip: View {
    let source: SourceMetadata
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: source.iconName)
                    .font(.caption2)
                Text(source.name)
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

#endif  // os(iOS/macOS)
