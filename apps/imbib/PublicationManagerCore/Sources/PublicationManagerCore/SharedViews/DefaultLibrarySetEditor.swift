//
//  DefaultLibrarySetEditor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-17.
//

import SwiftUI
import OSLog

#if os(macOS)

// MARK: - Default Library Set Editor

/// Editor view for modifying the default library set configuration.
///
/// This view is used by developers/testers to:
/// 1. View the current default library set
/// 2. Modify library names, inbox feeds, and collections
/// 3. Save changes directly to the configuration
///
/// Access methods:
/// - macOS: Settings > Advanced > hold Option > "Edit Default Library Set"
/// - macOS: Launch with `--edit-default-set` argument
/// - iOS: Settings > tap logo 5 times
public struct DefaultLibrarySetEditor: View {

    // MARK: - State

    @State private var libraries: [EditableLibrary] = []
    @State private var inboxFeeds: [EditableInboxFeed] = []
    @State private var selectedTab: EditorTab = .libraries
    @State private var selectedLibraryIndex: Int = 0
    @State private var selectedFeedIndex: Int = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingSavedToast = false
    @State private var hasUnsavedChanges = false
    @State private var queryAssistanceViewModel = QueryAssistanceViewModel()

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Types

    private enum EditorTab: String, CaseIterable {
        case libraries = "Libraries"
        case inboxFeeds = "Inbox Feeds"
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else {
                editorContent
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .task {
            await loadCurrentSet()
            // Register query assistants
            await QueryAssistanceService.shared.register(ADSQueryAssistant())
            await QueryAssistanceService.shared.register(ArXivQueryAssistant())
        }
        .onChange(of: selectedFeedIndex) { _, newIndex in
            // Update query assistance when switching feeds
            if newIndex < inboxFeeds.count {
                let feed = inboxFeeds[newIndex]
                updateQueryAssistance(query: feed.query, sources: feed.sourceIDs)
            } else {
                queryAssistanceViewModel.clear()
            }
        }
    }

    // MARK: - Query Assistance

    /// Update query assistance based on the selected sources
    private func updateQueryAssistance(query: String, sources: [String]) {
        // Determine the primary source for validation
        // Prefer arxiv if selected, otherwise use ads
        let source: QueryAssistanceSource
        if sources.contains("arxiv") {
            source = .arxiv
        } else if sources.contains("ads") {
            source = .ads
        } else {
            // No supported source selected, clear assistance
            queryAssistanceViewModel.clear()
            return
        }

        queryAssistanceViewModel.setSource(source)
        queryAssistanceViewModel.updateQuery(query)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default Library Set Editor")
                    .font(.headline)
                Text("Configure what new users see on first launch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showingSavedToast {
                Label("Saved!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Button("Save") {
                saveChanges()
            }
            .buttonStyle(.bordered)
            .disabled(!hasUnsavedChanges)

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .animation(.easeInOut, value: showingSavedToast)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading current configuration...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Error")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await loadCurrentSet() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor Content

    private var editorContent: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Section", selection: $selectedTab) {
                ForEach(EditorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Content based on selected tab
            switch selectedTab {
            case .libraries:
                librariesEditor
            case .inboxFeeds:
                inboxFeedsEditor
            }
        }
    }

    // MARK: - Libraries Editor

    private var librariesEditor: some View {
        HSplitView {
            // Library list (left sidebar)
            libraryList
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)

            // Selected library editor (right panel)
            if !libraries.isEmpty && selectedLibraryIndex < libraries.count {
                libraryEditor(for: $libraries[selectedLibraryIndex])
            } else {
                emptyLibrarySelection
            }
        }
    }

    // MARK: - Library List

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Libraries")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)

            List(selection: Binding(
                get: { selectedLibraryIndex },
                set: { selectedLibraryIndex = $0 }
            )) {
                ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                    HStack {
                        Image(systemName: library.isDefault ? "star.fill" : "folder")
                            .foregroundStyle(library.isDefault ? .yellow : .secondary)
                        Text(library.name)
                        Spacer()
                        Text("\(library.collections.count) collections")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(index)
                }
                .onMove(perform: moveLibraries)
                .onDelete(perform: deleteLibraries)
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button {
                    addLibrary()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add library")

                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: - Library Editor

    private func libraryEditor(for library: Binding<EditableLibrary>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Library name
                Section {
                    HStack {
                        TextField("Library Name", text: library.name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: library.wrappedValue.name) { _, _ in
                                hasUnsavedChanges = true
                            }

                        Toggle("Default", isOn: library.isDefault)
                            .toggleStyle(.checkbox)
                            .onChange(of: library.wrappedValue.isDefault) { _, newValue in
                                hasUnsavedChanges = true
                                if newValue {
                                    // Ensure only one library is default
                                    for i in libraries.indices where i != selectedLibraryIndex {
                                        libraries[i].isDefault = false
                                    }
                                }
                            }
                    }
                } header: {
                    Text("Library")
                        .font(.headline)
                }

                Divider()

                // Collections
                Section {
                    ForEach(library.collections.indices, id: \.self) { index in
                        collectionRow(library.collections[index], onDelete: {
                            library.wrappedValue.collections.remove(at: index)
                            hasUnsavedChanges = true
                        })
                    }

                    Button {
                        library.wrappedValue.collections.append(EditableCollection())
                        hasUnsavedChanges = true
                    } label: {
                        Label("Add Collection", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    HStack {
                        Text("Collections")
                            .font(.headline)
                        Spacer()
                        Text("\(library.collections.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Collection Row

    private func collectionRow(_ collection: Binding<EditableCollection>, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            TextField("Collection Name", text: collection.name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: collection.wrappedValue.name) { _, _ in
                    hasUnsavedChanges = true
                }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(6)
    }

    // MARK: - Empty Library Selection

    private var emptyLibrarySelection: some View {
        ContentUnavailableView {
            Label("No Library Selected", systemImage: "folder")
        } description: {
            Text("Select a library from the list or add a new one")
        }
    }

    // MARK: - Inbox Feeds Editor

    private var inboxFeedsEditor: some View {
        HSplitView {
            // Feed list (left sidebar)
            feedList
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)

            // Selected feed editor (right panel)
            if !inboxFeeds.isEmpty && selectedFeedIndex < inboxFeeds.count {
                feedEditor(for: $inboxFeeds[selectedFeedIndex])
            } else {
                emptyFeedSelection
            }
        }
    }

    // MARK: - Feed List

    private var feedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inbox Feeds")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)

            List(selection: Binding(
                get: { selectedFeedIndex },
                set: { selectedFeedIndex = $0 }
            )) {
                ForEach(Array(inboxFeeds.enumerated()), id: \.element.id) { index, feed in
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(feed.name)
                            Text(feed.sourceIDs.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(index)
                }
                .onMove(perform: moveFeeds)
                .onDelete(perform: deleteFeeds)
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button {
                    addFeed()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add inbox feed")

                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: - Feed Editor

    private func feedEditor(for feed: Binding<EditableInboxFeed>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Feed name
                Section {
                    TextField("Feed Name", text: feed.name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: feed.wrappedValue.name) { _, _ in
                            hasUnsavedChanges = true
                        }
                } header: {
                    Text("Name")
                        .font(.headline)
                }

                Divider()

                // Query
                Section {
                    HStack {
                        TextField("Search Query", text: feed.query)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: feed.wrappedValue.query) { _, newValue in
                                hasUnsavedChanges = true
                                updateQueryAssistance(query: newValue, sources: feed.wrappedValue.sourceIDs)
                            }

                        // Compact preview indicator
                        CompactQueryAssistanceView(viewModel: queryAssistanceViewModel)
                    }

                    // Query assistance feedback
                    if !queryAssistanceViewModel.isEmpty {
                        QueryAssistanceView(viewModel: queryAssistanceViewModel)
                    }

                    Text("Examples: cat:astro-ph.*, abs:exoplanet, author:\"Einstein\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Query")
                        .font(.headline)
                }

                Divider()

                // Sources
                Section {
                    HStack {
                        ForEach(["arxiv", "ads", "crossref"], id: \.self) { source in
                            Toggle(source, isOn: Binding(
                                get: { feed.wrappedValue.sourceIDs.contains(source) },
                                set: { isOn in
                                    if isOn {
                                        if !feed.wrappedValue.sourceIDs.contains(source) {
                                            feed.wrappedValue.sourceIDs.append(source)
                                        }
                                    } else {
                                        feed.wrappedValue.sourceIDs.removeAll { $0 == source }
                                    }
                                    hasUnsavedChanges = true
                                    // Update query assistance when sources change
                                    updateQueryAssistance(query: feed.wrappedValue.query, sources: feed.wrappedValue.sourceIDs)
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                } header: {
                    Text("Sources")
                        .font(.headline)
                }

                Divider()

                // Refresh interval
                Section {
                    Picker("Refresh Every", selection: feed.refreshIntervalSeconds) {
                        Text("1 hour").tag(3600)
                        Text("3 hours").tag(10800)
                        Text("6 hours").tag(21600)
                        Text("12 hours").tag(43200)
                        Text("24 hours").tag(86400)
                    }
                    .onChange(of: feed.wrappedValue.refreshIntervalSeconds) { _, _ in
                        hasUnsavedChanges = true
                    }
                } header: {
                    Text("Refresh Interval")
                        .font(.headline)
                }

                Divider()

                // Max results
                Section {
                    Stepper("Max Results: \(feed.wrappedValue.maxResults)", value: feed.maxResults, in: 10...500, step: 10)
                        .onChange(of: feed.wrappedValue.maxResults) { _, _ in
                            hasUnsavedChanges = true
                        }
                } header: {
                    Text("Results")
                        .font(.headline)
                }
            }
            .padding()
        }
    }

    // MARK: - Empty Feed Selection

    private var emptyFeedSelection: some View {
        ContentUnavailableView {
            Label("No Feed Selected", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Select an inbox feed from the list or add a new one")
        } actions: {
            Button("Add Feed") {
                addFeed()
            }
        }
    }

    // MARK: - Actions

    private func loadCurrentSet() async {
        isLoading = true
        errorMessage = nil

        do {
            // Load from JSON file (App Support or bundle), not Core Data
            let set = try await MainActor.run {
                try DefaultLibrarySetManager.shared.loadDefaultSetFromJSON()
            }
            libraries = set.libraries.map { EditableLibrary(from: $0) }
            inboxFeeds = (set.inboxFeeds ?? []).map { EditableInboxFeed(from: $0) }
            isLoading = false
            hasUnsavedChanges = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func addLibrary() {
        let newLibrary = EditableLibrary()
        newLibrary.name = "New Library"
        libraries.append(newLibrary)
        selectedLibraryIndex = libraries.count - 1
        hasUnsavedChanges = true
    }

    private func moveLibraries(from source: IndexSet, to destination: Int) {
        libraries.move(fromOffsets: source, toOffset: destination)
        hasUnsavedChanges = true
    }

    private func deleteLibraries(at offsets: IndexSet) {
        libraries.remove(atOffsets: offsets)
        if selectedLibraryIndex >= libraries.count {
            selectedLibraryIndex = max(0, libraries.count - 1)
        }
        hasUnsavedChanges = true
    }

    private func addFeed() {
        let newFeed = EditableInboxFeed()
        newFeed.name = "New Feed"
        newFeed.sourceIDs = ["arxiv"]
        newFeed.query = "cat:astro-ph.*"
        inboxFeeds.append(newFeed)
        selectedFeedIndex = inboxFeeds.count - 1
        hasUnsavedChanges = true
    }

    private func moveFeeds(from source: IndexSet, to destination: Int) {
        inboxFeeds.move(fromOffsets: source, toOffset: destination)
        hasUnsavedChanges = true
    }

    private func deleteFeeds(at offsets: IndexSet) {
        inboxFeeds.remove(atOffsets: offsets)
        if selectedFeedIndex >= inboxFeeds.count {
            selectedFeedIndex = max(0, inboxFeeds.count - 1)
        }
        hasUnsavedChanges = true
    }

    private func saveChanges() {
        let editedSet = buildDefaultLibrarySet()

        do {
            try DefaultLibrarySetManager.shared.saveToBundledJSON(editedSet)
            hasUnsavedChanges = false
            showingSavedToast = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                showingSavedToast = false
            }
        } catch {
            Logger.library.errorCapture("Failed to save: \(error.localizedDescription)", category: "onboarding")
        }
    }

    private func buildDefaultLibrarySet() -> DefaultLibrarySet {
        let defaultLibraries = libraries.map { editable in
            DefaultLibrary(
                name: editable.name,
                isDefault: editable.isDefault,
                smartSearches: nil,
                collections: editable.collections.isEmpty ? nil : editable.collections.map { c in
                    DefaultCollection(name: c.name)
                }
            )
        }

        let defaultFeeds = inboxFeeds.isEmpty ? nil : inboxFeeds.map { editable in
            DefaultInboxFeed(
                name: editable.name,
                query: editable.query,
                sourceIDs: editable.sourceIDs,
                refreshIntervalSeconds: editable.refreshIntervalSeconds,
                maxResults: editable.maxResults
            )
        }

        return DefaultLibrarySet(version: 1, libraries: defaultLibraries, inboxFeeds: defaultFeeds)
    }
}

// MARK: - Editable Models

/// Editable wrapper for DefaultLibrary
@Observable
private class EditableLibrary: Identifiable {
    let id = UUID()
    var name: String = ""
    var isDefault: Bool = false
    var collections: [EditableCollection] = []

    init() {}

    init(from defaultLibrary: DefaultLibrary) {
        self.name = defaultLibrary.name
        self.isDefault = defaultLibrary.isDefault
        self.collections = (defaultLibrary.collections ?? []).map { EditableCollection(from: $0) }
    }
}

/// Editable wrapper for DefaultCollection
@Observable
private class EditableCollection: Identifiable {
    let id = UUID()
    var name: String = "New Collection"

    init() {}

    init(from defaultCollection: DefaultCollection) {
        self.name = defaultCollection.name
    }
}

/// Editable wrapper for DefaultInboxFeed
@Observable
private class EditableInboxFeed: Identifiable {
    let id = UUID()
    var name: String = "New Feed"
    var query: String = ""
    var sourceIDs: [String] = []
    var refreshIntervalSeconds: Int = 21600
    var maxResults: Int = 100

    init() {}

    init(from defaultFeed: DefaultInboxFeed) {
        self.name = defaultFeed.name
        self.query = defaultFeed.query
        self.sourceIDs = defaultFeed.sourceIDs
        self.refreshIntervalSeconds = defaultFeed.refreshIntervalSeconds ?? 21600
        self.maxResults = defaultFeed.maxResults ?? 100
    }
}

// MARK: - Preview

#Preview {
    DefaultLibrarySetEditor()
}

#else

// iOS placeholder - this editor is macOS-only for now
public struct DefaultLibrarySetEditor: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "macOS Only",
            systemImage: "desktopcomputer",
            description: Text("The Default Library Set Editor is only available on macOS.")
        )
    }
}

#endif
