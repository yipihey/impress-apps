//
//  GroupArXivFeedFormView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-15.
//

import SwiftUI
import OSLog

#if os(macOS)

// MARK: - Group arXiv Feed Form View

/// Form for creating group arXiv feeds that monitor multiple authors.
///
/// This form allows users to specify multiple author names (comma or newline separated)
/// and selected arXiv categories. Searches for each author are staggered 20 seconds apart
/// to avoid rate limiting.
///
/// Group feeds are always inbox feeds with auto-refresh enabled.
public struct GroupArXivFeedFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Mode

    /// The mode determines where results are stored. Group feeds always use inbox mode.
    public let mode: SearchFormMode

    /// When set, the form loads this feed's data on appear (edit mode).
    public let editingFeedID: UUID?

    // MARK: - Local State

    @State private var feedName: String = ""
    @State private var authorsText: String = ""
    @State private var selectedCategories: Set<String> = []
    @State private var includeCrossListed: Bool = true
    @State private var expandedGroups: Set<String> = []
    @State private var isCreating: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    /// Maximum results to return (0 = use default, which is 500 for feeds)
    @State private var formMaxResults: Int = 0
    @State private var saveTargetID: UUID?

    // MARK: - Edit Mode State

    @State private var editingFeed: SmartSearch?

    var isEditMode: Bool {
        editingFeed != nil
    }

    // MARK: - Initialization

    /// Create a group arXiv feed form. Group feeds always feed to inbox.
    /// - Parameters:
    ///   - mode: The search form mode (defaults to `.inboxFeed`)
    ///   - editingFeedID: If set, loads this feed's data into the form on appear.
    public init(mode: SearchFormMode = .inboxFeed, editingFeedID: UUID? = nil) {
        self.mode = mode
        self.editingFeedID = editingFeedID
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        isEditMode ? "Edit Group Feed" : "Create Group arXiv Feed",
                        systemImage: "person.3.fill"
                    )
                    .font(.title2)
                    .fontWeight(.semibold)
                    Text("Monitor multiple authors in selected arXiv categories")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Feed Name Section
                feedNameSection

                // Save target picker
                FeedSaveTargetPicker(saveTargetID: $saveTargetID)

                // Authors Section
                authorsSection

                // Categories Section
                categoriesSection

                // Cross-listing toggle
                Toggle("Include cross-listed papers", isOn: $includeCrossListed)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)

                // Max Results
                VStack(alignment: .leading, spacing: 8) {
                    Text("Max Results")
                        .font(.headline)

                    HStack {
                        TextField("default", value: $formMaxResults, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("(0 = use default: 500 for feeds)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                    .padding(.vertical, 8)

                // Edit mode header
                if let feed = editingFeed {
                    HStack {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Editing: \(feed.name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            exitEditMode()
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
                    Button("Clear All") {
                        clearForm()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if isEditMode {
                        Button("Save") {
                            saveToFeed()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isFormValid)
                        .keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button {
                            createFeed()
                        } label: {
                            if isCreating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Create Feed")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isFormValid || isCreating)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }

                // Error message
                if showError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            if let feedID = editingFeedID,
               editingFeed == nil,
               let feed = RustStoreAdapter.shared.getSmartSearch(id: feedID) {
                loadFeedForEditing(feed)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editGroupArXivFeed)) { notification in
            if let feed = notification.object as? SmartSearch {
                loadFeedForEditing(feed)
            }
        }
    }

    // MARK: - Feed Name Section

    @ViewBuilder
    private var feedNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feed Name")
                .font(.headline)

            TextField("Friends", text: $feedName)
                .textFieldStyle(.roundedBorder)

            Text("Leave blank to use \"Friends\" as the default name")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Authors Section

    @ViewBuilder
    private var authorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authors")
                .font(.headline)

            TextEditor(text: $authorsText)
                .font(.body)
                .frame(minHeight: 100, maxHeight: 150)
                .border(Color.gray.opacity(0.3), width: 1)
                .clipShape(.rect(cornerRadius: 4))

            Text("One author per line (Last, First) or comma-separated on a single line")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !parsedAuthors.isEmpty {
                HStack {
                    Text("\(parsedAuthors.count) authors:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(parsedAuthors.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Categories Section

    @ViewBuilder
    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Subject Categories")
                    .font(.headline)
                Text("(required)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ArXivCategoryPickerView(
                selectedCategories: $selectedCategories,
                expandedGroups: $expandedGroups
            )

            if !selectedCategories.isEmpty {
                HStack {
                    Text("\(selectedCategories.count) selected:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedCategories.sorted().joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Computed Properties

    /// Parse authors from the text input (comma or newline separated)
    /// If input contains newlines, split by newlines only (preserves "Last, First" format)
    /// If no newlines, split by commas (for single-line comma-separated input)
    private var parsedAuthors: [String] {
        let trimmed = authorsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // If there are newlines, split by newlines only (preserves "Last, First" format)
        if trimmed.contains("\n") {
            return trimmed
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            // No newlines - split by commas for single-line input like "Author1, Author2"
            return trimmed
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    private var effectiveFeedName: String {
        let trimmed = feedName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Friends" : trimmed
    }

    private var isFormValid: Bool {
        !parsedAuthors.isEmpty && !selectedCategories.isEmpty
    }

    // MARK: - Actions

    private func createFeed() {
        guard isFormValid else { return }

        isCreating = true
        showError = false

        Task {
            do {
                // Build the group feed query string
                let query = buildGroupFeedQuery()

                // Use formMaxResults if > 0, otherwise pass nil to use default
                let maxResultsParam: Int? = formMaxResults > 0 ? formMaxResults : nil
                let smartSearch: SmartSearch?

                if case .libraryFeed(let libraryID, _) = mode {
                    smartSearch = RustStoreAdapter.shared.createLibraryFeed(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        libraryID: libraryID,
                        maxResults: maxResultsParam.map { Int16($0) },
                        refreshIntervalSeconds: 86400,
                        saveTargetID: saveTargetID
                    )
                } else {
                    // Create the smart search using the inbox feed factory method
                    // Group feeds are always inbox feeds with auto-refresh
                    smartSearch = SmartSearchRepository.shared.createInboxFeed(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        maxResults: maxResultsParam,
                        refreshIntervalSeconds: 86400,  // 24 hours (daily refresh)
                        isGroupFeed: true
                    )
                }

                guard let smartSearch else {
                    throw NSError(domain: "GroupFeed", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create feed"])
                }

                Logger.viewModels.infoCapture(
                    "Created group arXiv feed '\(smartSearch.name)' with \(parsedAuthors.count) authors and \(selectedCategories.count) categories",
                    category: "feed"
                )

                // Execute initial fetch (will use staggered searches)
                await executeInitialFetch(smartSearch)

                // Notify sidebar to refresh
                await MainActor.run {
                    NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
                    NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
                }

                // Clear the form
                clearForm()

            } catch {
                Logger.viewModels.errorCapture("Failed to create group feed: \(error.localizedDescription)", category: "feed")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }

            await MainActor.run {
                isCreating = false
            }
        }
    }

    private func executeInitialFetch(_ smartSearch: SmartSearch) async {
        // Use GroupFeedRefreshService for staggered searches
        do {
            let fetchedCount = try await GroupFeedRefreshService.shared.refreshGroupFeedByID(smartSearch.id)
            Logger.viewModels.infoCapture(
                "Initial group feed fetch complete: \(fetchedCount) papers added to Inbox",
                category: "feed"
            )
        } catch {
            Logger.viewModels.errorCapture(
                "Initial group feed fetch failed: \(error.localizedDescription)",
                category: "feed"
            )
        }
    }

    private func saveToFeed() {
        guard let feed = editingFeed else { return }
        guard isFormValid else { return }

        // Build the group feed query
        let query = buildGroupFeedQuery()

        // Update the feed via RustStoreAdapter
        RustStoreAdapter.shared.updateSmartSearch(feed.id, name: effectiveFeedName, query: query, maxResults: Int16(formMaxResults))
        Logger.viewModels.infoCapture("Updated group arXiv feed '\(effectiveFeedName)'", category: "feed")

        // Notify sidebar
        NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)

        // Exit edit mode
        exitEditMode()
    }

    private func loadFeedForEditing(_ feed: SmartSearch) {
        editingFeed = feed
        feedName = feed.name

        Logger.viewModels.infoCapture(
            "Loading group feed '\(feed.name)' raw query: \(feed.query)",
            category: "feed"
        )

        // Parse the query to extract authors and categories
        let (authors, categories) = parseGroupFeedQuery(feed.query)
        authorsText = authors.joined(separator: "\n")
        selectedCategories = categories

        // Default include cross-listed to true
        includeCrossListed = !feed.query.contains("crosslist:false")

        // Load maxResults from the feed
        formMaxResults = feed.maxResults

        Logger.viewModels.infoCapture(
            "Loaded group feed '\(feed.name)' for editing with \(authors.count) authors (\(authorsText.prefix(100))...) and \(categories.count) categories",
            category: "feed"
        )
    }

    /// Build the query string for a group feed.
    /// Uses `;` as the author separator (not `,`) because author names
    /// themselves may contain ", " (e.g. "Lastname, Firstname").
    private func buildGroupFeedQuery() -> String {
        // Format: GROUP_FEED|authors:Author1;Author2;Author3|categories:cat1,cat2|crosslist:true
        let authorsString = parsedAuthors.joined(separator: ";")
        let categoriesString = selectedCategories.sorted().joined(separator: ",")
        let crosslistString = includeCrossListed ? "true" : "false"
        return "GROUP_FEED|authors:\(authorsString)|categories:\(categoriesString)|crosslist:\(crosslistString)"
    }

    /// Parse a group feed query string to extract authors and categories.
    /// Supports current format (`authors:`, `categories:`, `crosslist:`) and
    /// legacy format (`au:`, `cat:` with `;` or ambiguous `,` author separators).
    private func parseGroupFeedQuery(_ query: String) -> ([String], Set<String>) {
        var authors: [String] = []
        var categories: Set<String> = []

        guard query.hasPrefix("GROUP_FEED|") else {
            return (authors, categories)
        }

        let parts = query.dropFirst("GROUP_FEED|".count)
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts {
            if let raw = Self.stripPrefix(part, prefixes: ["authors:", "au:"]) {
                authors = Self.splitAuthorList(raw)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if let raw = Self.stripPrefix(part, prefixes: ["categories:", "cat:"]) {
                categories = Set(
                    raw.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                )
            }
        }

        return (authors, categories)
    }

    private static func stripPrefix(_ s: String, prefixes: [String]) -> String? {
        for p in prefixes where s.hasPrefix(p) {
            return String(s.dropFirst(p.count))
        }
        return nil
    }

    /// Split an author list string, preserving full "Lastname, Firstname" names.
    /// ";" always separates authors. A bare "," only separates authors when NOT
    /// followed by whitespace (", " is treated as part of a name).
    private static func splitAuthorList(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == ";" {
                result.append(current)
                current = ""
                i += 1
                continue
            }
            if c == "," {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if let n = next, n.isWhitespace {
                    current.append(c)
                    i += 1
                } else {
                    result.append(current)
                    current = ""
                    i += 1
                }
                continue
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func exitEditMode() {
        editingFeed = nil
        clearForm()
    }

    private func clearForm() {
        feedName = ""
        authorsText = ""
        selectedCategories = []
        includeCrossListed = true
        showError = false
        errorMessage = ""
        formMaxResults = 0
    }
}

#elseif os(iOS)

// MARK: - iOS Group arXiv Feed Form View

/// iOS form for creating group arXiv feeds that monitor multiple authors.
/// Group feeds are always inbox feeds with auto-refresh enabled.
public struct GroupArXivFeedFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Mode

    /// The mode determines where results are stored. Group feeds always use inbox mode.
    public let mode: SearchFormMode

    // MARK: - Local State

    @State private var feedName: String = ""
    @State private var authorsText: String = ""
    @State private var selectedCategories: Set<String> = []
    @State private var includeCrossListed: Bool = true
    @State private var expandedGroups: Set<String> = []
    @State private var isCreating: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    /// Maximum results to return (0 = use default, which is 500 for feeds)
    @State private var formMaxResults: Int = 0
    @State private var saveTargetID: UUID?

    // MARK: - Edit Mode State

    @State private var editingFeed: SmartSearch?

    var isEditMode: Bool {
        editingFeed != nil
    }

    // MARK: - Initialization

    /// Create a group arXiv feed form. Group feeds always feed to inbox.
    /// - Parameter mode: The search form mode (defaults to `.inboxFeed`)
    public init(mode: SearchFormMode = .inboxFeed) {
        self.mode = mode
    }

    // MARK: - Body

    public var body: some View {
        Form {
            // Feed Name Section
            Section {
                TextField("Friends", text: $feedName)
            } header: {
                Text("Feed Name")
            } footer: {
                Text("Leave blank to use \"Friends\" as the default name")
            }

            // Authors Section
            Section {
                TextEditor(text: $authorsText)
                    .frame(minHeight: 100)
            } header: {
                Text("Authors")
            } footer: {
                VStack(alignment: .leading) {
                    Text("One author per line (Last, First) or comma-separated on a single line")
                    if !parsedAuthors.isEmpty {
                        Text("\(parsedAuthors.count) authors entered")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Categories Section (required)
            Section {
                IOSArXivCategoryPickerView(
                    selectedCategories: $selectedCategories,
                    expandedGroups: $expandedGroups
                )

                if !selectedCategories.isEmpty {
                    Text("\(selectedCategories.count) categories selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Subject Categories")
                    Text("(required)")
                        .foregroundStyle(.red)
                }
            }

            // Options Section
            Section {
                Toggle("Include cross-listed papers", isOn: $includeCrossListed)
            }

            // Max Results
            Section {
                HStack {
                    Text("Max Results")
                    Spacer()
                    TextField("default", value: $formMaxResults, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } footer: {
                Text("0 = use default (500 for feeds)")
            }

            // Edit mode indicator
            if let feed = editingFeed {
                Section {
                    HStack {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Editing: \(feed.name)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            exitEditMode()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }

            // Action Buttons
            Section {
                if isEditMode {
                    Button("Save") {
                        saveToFeed()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!isFormValid)
                } else {
                    Button {
                        createFeed()
                    } label: {
                        HStack {
                            Spacer()
                            if isCreating {
                                ProgressView()
                            } else {
                                Text("Create Feed")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!isFormValid || isCreating)
                }

                Button("Clear All", role: .destructive) {
                    clearForm()
                }
                .frame(maxWidth: .infinity)
            }

            // Error message
            if showError {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(isEditMode ? "Edit Group Feed" : "Group Feed")
        .onReceive(NotificationCenter.default.publisher(for: .editGroupArXivFeed)) { notification in
            if let feed = notification.object as? SmartSearch {
                loadFeedForEditing(feed)
            }
        }
    }

    // MARK: - Computed Properties

    /// Parse authors from the text input (comma or newline separated)
    /// If input contains newlines, split by newlines only (preserves "Last, First" format)
    /// If no newlines, split by commas (for single-line comma-separated input)
    private var parsedAuthors: [String] {
        let trimmed = authorsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // If there are newlines, split by newlines only (preserves "Last, First" format)
        if trimmed.contains("\n") {
            return trimmed
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            // No newlines - split by commas for single-line input like "Author1, Author2"
            return trimmed
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    private var effectiveFeedName: String {
        let trimmed = feedName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Friends" : trimmed
    }

    private var isFormValid: Bool {
        !parsedAuthors.isEmpty && !selectedCategories.isEmpty
    }

    // MARK: - Actions

    private func createFeed() {
        guard isFormValid else { return }

        isCreating = true
        showError = false

        Task {
            do {
                let query = buildGroupFeedQuery()

                let maxResultsParam: Int? = formMaxResults > 0 ? formMaxResults : nil
                let smartSearch: SmartSearch?

                if case .libraryFeed(let libraryID, _) = mode {
                    smartSearch = RustStoreAdapter.shared.createLibraryFeed(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        libraryID: libraryID,
                        maxResults: maxResultsParam.map { Int16($0) },
                        refreshIntervalSeconds: 86400,
                        saveTargetID: saveTargetID
                    )
                } else {
                    // Create the smart search using the inbox feed factory method
                    // Group feeds are always inbox feeds with auto-refresh
                    smartSearch = SmartSearchRepository.shared.createInboxFeed(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        maxResults: maxResultsParam,
                        refreshIntervalSeconds: 86400,  // 24 hours (daily refresh)
                        isGroupFeed: true
                    )
                }

                guard let smartSearch else {
                    throw NSError(domain: "GroupFeed", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create feed"])
                }

                Logger.viewModels.infoCapture(
                    "Created group arXiv feed '\(smartSearch.name)' with \(parsedAuthors.count) authors and \(selectedCategories.count) categories",
                    category: "feed"
                )

                await executeInitialFetch(smartSearch)

                await MainActor.run {
                    NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
                    NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
                }

                clearForm()

            } catch {
                Logger.viewModels.errorCapture("Failed to create group feed: \(error.localizedDescription)", category: "feed")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }

            await MainActor.run {
                isCreating = false
            }
        }
    }

    private func executeInitialFetch(_ smartSearch: SmartSearch) async {
        do {
            let fetchedCount = try await GroupFeedRefreshService.shared.refreshGroupFeedByID(smartSearch.id)
            Logger.viewModels.infoCapture(
                "Initial group feed fetch complete: \(fetchedCount) papers added to Inbox",
                category: "feed"
            )
        } catch {
            Logger.viewModels.errorCapture(
                "Initial group feed fetch failed: \(error.localizedDescription)",
                category: "feed"
            )
        }
    }

    private func saveToFeed() {
        guard let feed = editingFeed else { return }
        guard isFormValid else { return }

        let query = buildGroupFeedQuery()

        // Update the feed via RustStoreAdapter
        RustStoreAdapter.shared.updateSmartSearch(feed.id, name: effectiveFeedName, query: query, maxResults: Int16(formMaxResults))
        Logger.viewModels.infoCapture("Updated group arXiv feed '\(effectiveFeedName)'", category: "feed")

        // Notify sidebar
        NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)

        // Exit edit mode
        exitEditMode()
    }

    private func loadFeedForEditing(_ feed: SmartSearch) {
        editingFeed = feed
        feedName = feed.name

        let (authors, categories) = parseGroupFeedQuery(feed.query)
        authorsText = authors.joined(separator: "\n")
        selectedCategories = categories

        includeCrossListed = !feed.query.contains("crosslist:false")
        formMaxResults = feed.maxResults

        Logger.viewModels.infoCapture(
            "Loaded group feed '\(feed.name)' for editing with \(authors.count) authors and \(categories.count) categories",
            category: "feed"
        )
    }

    private func buildGroupFeedQuery() -> String {
        // Use ";" between authors to avoid ambiguity with "," inside names.
        let authorsString = parsedAuthors.joined(separator: ";")
        let categoriesString = selectedCategories.sorted().joined(separator: ",")
        let crosslistString = includeCrossListed ? "true" : "false"
        return "GROUP_FEED|authors:\(authorsString)|categories:\(categoriesString)|crosslist:\(crosslistString)"
    }

    private func parseGroupFeedQuery(_ query: String) -> ([String], Set<String>) {
        var authors: [String] = []
        var categories: Set<String> = []

        guard query.hasPrefix("GROUP_FEED|") else {
            return (authors, categories)
        }

        let parts = query.dropFirst("GROUP_FEED|".count)
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts {
            if let raw = Self.stripPrefix(part, prefixes: ["authors:", "au:"]) {
                authors = Self.splitAuthorList(raw)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if let raw = Self.stripPrefix(part, prefixes: ["categories:", "cat:"]) {
                categories = Set(
                    raw.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                )
            }
        }

        return (authors, categories)
    }

    private static func stripPrefix(_ s: String, prefixes: [String]) -> String? {
        for p in prefixes where s.hasPrefix(p) {
            return String(s.dropFirst(p.count))
        }
        return nil
    }

    private static func splitAuthorList(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == ";" {
                result.append(current)
                current = ""
                i += 1
                continue
            }
            if c == "," {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if let n = next, n.isWhitespace {
                    current.append(c)
                    i += 1
                } else {
                    result.append(current)
                    current = ""
                    i += 1
                }
                continue
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func exitEditMode() {
        editingFeed = nil
        clearForm()
    }

    private func clearForm() {
        feedName = ""
        authorsText = ""
        selectedCategories = []
        includeCrossListed = true
        showError = false
        errorMessage = ""
        formMaxResults = 0
    }
}

#endif  // os(macOS/iOS)

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when a group feed should be edited (object is SmartSearch)
    static let editGroupArXivFeed = Notification.Name("editGroupArXivFeed")
}
