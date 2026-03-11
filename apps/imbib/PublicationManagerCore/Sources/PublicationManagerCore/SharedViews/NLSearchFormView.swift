//
//  NLSearchFormView.swift
//  PublicationManagerCore
//
//  A sidebar search form that uses Apple Foundation Models to translate
//  natural language into ADS/SciX queries. This is the search form variant
//  (appears in the search section alongside other forms like ADS Modern, Classic, etc.)
//

import SwiftUI
import OSLog

#if os(macOS)

// MARK: - NL Search Form View

/// Search form that accepts natural language and translates it to ADS queries
/// using the on-device Apple Foundation Models LLM.
///
/// This form appears in the Search section of the sidebar alongside other
/// search forms (ADS Modern, ADS Classic, Vague Memory, etc.).
public struct NLSearchFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(NLSearchService.self) private var nlService

    // MARK: - State

    @State private var inputText = ""
    @State private var generatedQuery = ""
    @State private var showQueryPreview = true

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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                Divider()

                // Feed settings (when creating a feed)
                if mode == .inboxFeed {
                    feedSettingsSection
                    Divider()
                }

                // Natural language input
                inputSection

                // Search options (source, max results, refereed)
                searchOptionsSection

                // Generated query preview
                if !generatedQuery.isEmpty {
                    queryPreviewSection
                }

                // Status
                statusSection

                Divider()

                // Action buttons
                actionButtons
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            searchViewModel.setLibraryManager(libraryManager)
        }
        .onAppear {
            if let feedID = editingFeedID {
                loadFeedForEditing(feedID)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Smart Search", systemImage: "sparkle.magnifyingglass")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Describe what you're looking for in plain language")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if NLSearchService.isAvailable {
                Label("Powered by on-device Apple Intelligence", systemImage: "apple.intelligence")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else {
                Label("Smart keyword search", systemImage: "text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Input Section

    @ViewBuilder
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What are you looking for?")
                .font(.headline)

            TextEditor(text: $inputText)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("e.g., \"papers about dark energy by Riess from the last 5 years\"")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            // Example suggestions
            VStack(alignment: .leading, spacing: 4) {
                Text("Examples:")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    exampleChip("dark energy surveys")
                    exampleChip("galaxy rotation curves 1970s")
                    exampleChip("JWST deep field refereed")
                }
            }
        }
    }

    @ViewBuilder
    private func exampleChip(_ text: String) -> some View {
        Button {
            inputText = text
        } label: {
            Text(text)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search Options

    @ViewBuilder
    private var searchOptionsSection: some View {
        @Bindable var service = nlService

        VStack(alignment: .leading, spacing: 8) {
            Text("Search Options")
                .font(.headline)

            // Source selection
            HStack(spacing: 8) {
                Text("Sources:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(["ads", "arxiv", "openalex"], id: \.self) { sourceID in
                    let label: String = switch sourceID {
                    case "ads": "ADS/SciX"
                    case "arxiv": "arXiv"
                    case "openalex": "OpenAlex"
                    default: sourceID
                    }
                    Toggle(label, isOn: Binding(
                        get: { service.selectedSourceIDs.contains(sourceID) },
                        set: { newVal in
                            if newVal {
                                service.selectedSourceIDs.insert(sourceID)
                            } else if service.selectedSourceIDs.count > 1 {
                                service.selectedSourceIDs.remove(sourceID)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 16) {
                // Max results
                HStack(spacing: 8) {
                    Text("Max Results:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $service.maxResults) {
                        Text("Default").tag(0)
                        Text("25").tag(25)
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("200").tag(200)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }

                // Refereed toggle
                Toggle("Refereed only", isOn: $service.refereedOnly)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Query Preview

    @ViewBuilder
    private var queryPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Generated ADS Query")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button {
                    showQueryPreview.toggle()
                } label: {
                    Image(systemName: showQueryPreview ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if !nlService.lastInterpretation.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text(nlService.lastInterpretation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showQueryPreview {
                HStack(spacing: 8) {
                    TextField("ADS Query", text: $generatedQuery)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { executeEditedQuery() }

                    if generatedQuery != nlService.lastGeneratedQuery {
                        Button("Run") {
                            executeEditedQuery()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        switch nlService.state {
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating to ADS query...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .translated(_, _, let estimatedCount):
            if let count = estimatedCount {
                HStack(spacing: 8) {
                    Image(systemName: "number.circle")
                        .foregroundStyle(.blue)
                    Text("~\(count) results available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching SciX/ADS...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .complete(_, let count):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(count) papers found")
                    .font(.callout)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button("Try Again") {
                        let text = inputText
                        Task { await nlService.translate(text) }
                    }
                    .controlSize(.small)

                    Button("Edit Query Manually") {
                        // Switch to ADS Modern form with user's text as seed
                        generatedQuery = inputText
                        showQueryPreview = true
                    }
                    .controlSize(.small)
                }
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            Button("Clear") {
                inputText = ""
                generatedQuery = ""
                nlService.reset()
            }
            .buttonStyle(.bordered)

            Spacer()

            if editingFeedID != nil {
                Button("Save Feed") { saveFeed() }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            } else if mode == .inboxFeed {
                Button { createFeed() } label: {
                    if isCreating { ProgressView().controlSize(.small) }
                    else { Text("Create Feed") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button {
                    translateAndSearch()
                } label: {
                    Label("Smart Search", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || nlService.state.isWorking)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: - Actions

    private func translateAndSearch() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let vm = searchViewModel
        let sourceIDs = nlService.selectedSourceIDs

        Task {
            guard let query = await nlService.translate(text) else { return }
            generatedQuery = query

            // Auto-execute the search
            nlService.markSearching()
            vm.query = query
            vm.selectedSourceIDs = sourceIDs
            vm.nlSearchMaxResults = nlService.maxResults
            vm.editFormType = .nlSearch

            await vm.search()
            await nlService.markComplete(resultCount: vm.lastSearchResultCount)
        }
    }

    private func executeEditedQuery() {
        let query = generatedQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let vm = searchViewModel
        let sourceIDs = nlService.selectedSourceIDs

        nlService.markSearching()
        vm.query = query
        vm.selectedSourceIDs = sourceIDs
        vm.nlSearchMaxResults = nlService.maxResults
        vm.editFormType = .nlSearch

        Task {
            await vm.search()
            await nlService.markComplete(resultCount: vm.lastSearchResultCount, executedQuery: query)
        }
    }

    // MARK: - Feed Management

    @ViewBuilder
    private var feedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feed Settings").font(.headline)
            TextField("Feed Name", text: $feedName).textFieldStyle(.roundedBorder)
            Picker("Refresh Interval", selection: $refreshPreset) {
                ForEach(RefreshIntervalPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .frame(width: 200)
        }
    }

    private func createFeed() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isCreating = true

        let sourceIDs = Array(nlService.selectedSourceIDs)
        let feedMaxResults = nlService.maxResults > 0 ? nlService.maxResults : 50

        Task {
            guard let query = await nlService.translate(text) else {
                isCreating = false
                return
            }

            let name = feedName.isEmpty ? "AI: \(text.prefix(40))" : feedName
            let feed = RustStoreAdapter.shared.createInboxFeed(
                name: name, query: query, sourceIDs: sourceIDs,
                maxResults: Int16(feedMaxResults),
                refreshIntervalSeconds: Int64(refreshPreset.rawValue)
            )
            if let feed {
                if let fetchService = await InboxCoordinator.shared.paperFetchService {
                    _ = try? await fetchService.fetchForInbox(smartSearchID: feed.id)
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
                    NotificationCenter.default.post(name: .navigateToSmartSearch, object: feed.id)
                }
            }
            await MainActor.run { isCreating = false }
        }
    }

    private func saveFeed() {
        guard let feedID = editingFeedID else { return }
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let feedMaxResults = nlService.maxResults > 0 ? nlService.maxResults : 50

        Task {
            // Use the edited query if available, otherwise translate
            let query: String
            if !generatedQuery.isEmpty {
                query = generatedQuery
            } else if let translated = await nlService.translate(text) {
                query = translated
            } else {
                return
            }
            let name = feedName.isEmpty ? "AI: \(text.prefix(40))" : feedName
            RustStoreAdapter.shared.updateSmartSearch(feedID, name: name, query: query, maxResults: Int16(feedMaxResults))
            RustStoreAdapter.shared.updateIntField(id: feedID, field: "refresh_interval_seconds", value: Int64(refreshPreset.rawValue))
            NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
        }
    }

    private func loadFeedForEditing(_ feedID: UUID) {
        guard let feed = RustStoreAdapter.shared.getSmartSearch(id: feedID) else { return }
        feedName = feed.name
        // Load the ADS query into the editable query field
        generatedQuery = feed.query
        // For NL-created feeds ("AI: description"), extract the original description as input hint
        if feed.name.hasPrefix("AI: ") {
            inputText = String(feed.name.dropFirst("AI: ".count))
        } else {
            inputText = feed.query
        }
        // Load source IDs
        if !feed.sourceIDs.isEmpty {
            nlService.selectedSourceIDs = Set(feed.sourceIDs)
        }
        // Load max results
        if feed.maxResults > 0 {
            nlService.maxResults = feed.maxResults
        }
        if let preset = RefreshIntervalPreset(rawValue: Int32(feed.refreshIntervalSeconds)) {
            refreshPreset = preset
        }
    }
}

#elseif os(iOS)

// MARK: - iOS NL Search Form

/// iOS version of the NL Search form
public struct NLSearchFormView: View {

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager
    @Environment(NLSearchService.self) private var nlService

    @State private var inputText = ""
    @State private var generatedQuery = ""

    public init(mode: SearchFormMode = .explorationSearch, editingFeedID: UUID? = nil) {}

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Describe what you're looking for in plain language")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if NLSearchService.isAvailable {
                        Label("Powered by on-device Apple Intelligence", systemImage: "apple.intelligence")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else {
                        Label("Smart keyword search", systemImage: "text.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("What are you looking for?") {
                TextEditor(text: $inputText)
                    .frame(minHeight: 100)
            }

            if !generatedQuery.isEmpty {
                Section("Generated ADS Query") {
                    Text(generatedQuery)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.blue)
                }
            }

            // Status
            switch nlService.state {
            case .thinking:
                Section {
                    HStack { ProgressView(); Text("Translating...") }
                }
            case .translated(_, _, let estimatedCount):
                if let count = estimatedCount {
                    Section {
                        Label("~\(count) results available", systemImage: "number.circle")
                            .foregroundStyle(.blue)
                    }
                }
            case .searching:
                Section {
                    HStack { ProgressView(); Text("Searching SciX/ADS...") }
                }
            case .complete(_, let count):
                Section {
                    Label("\(count) papers found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .error(let msg):
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            default:
                EmptyView()
            }

            Section {
                Button {
                    translateAndSearch()
                } label: {
                    HStack {
                        Spacer()
                        Label("Smart Search", systemImage: "sparkle.magnifyingglass")
                        Spacer()
                    }
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || nlService.state.isWorking)
            }
        }
        .navigationTitle("Smart Search")
        .task {
            searchViewModel.setLibraryManager(libraryManager)
        }
    }

    private func translateAndSearch() {
        let text = inputText
        let vm = searchViewModel
        let sourceIDs = nlService.selectedSourceIDs

        Task {
            guard let query = await nlService.translate(text) else { return }
            generatedQuery = query

            nlService.markSearching()
            vm.query = query
            vm.selectedSourceIDs = sourceIDs
            vm.editFormType = .nlSearch

            await vm.search()
            await nlService.markComplete(resultCount: vm.lastSearchResultCount)
        }
    }
}

#endif
