//
//  ArXivFeedFormView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-15.
//

import SwiftUI
import CoreData
import OSLog

// MARK: - Search Form Mode

/// Determines how a search form creates smart searches.
///
/// The mode controls:
/// - Where the search is stored (which library)
/// - Whether it feeds to inbox
/// - Whether it auto-refreshes
public enum SearchFormMode: Equatable {
    /// Library smart search (from + button in library)
    /// - Stored in the specified library
    /// - Does NOT feed to inbox
    /// - Does NOT auto-refresh (manual only)
    case librarySmartSearch(CDLibrary)

    /// Inbox feed (from + button in Inbox section)
    /// - Stored in the Inbox library
    /// - Feeds to inbox (feedsToInbox = true)
    /// - Auto-refreshes on schedule
    case inboxFeed

    /// Exploration search (from Search section)
    /// - Stored in the Exploration library
    /// - Does NOT feed to inbox
    /// - Does NOT auto-refresh (one-off search)
    case explorationSearch

    /// Human-readable description for UI display
    public var displayDescription: String {
        switch self {
        case .librarySmartSearch(let library):
            return "Smart search in \(library.displayName)"
        case .inboxFeed:
            return "Feed to Inbox"
        case .explorationSearch:
            return "Search results"
        }
    }

    /// The action button text for this mode
    public var createButtonTitle: String {
        switch self {
        case .librarySmartSearch:
            return "Create Smart Search"
        case .inboxFeed:
            return "Create Feed"
        case .explorationSearch:
            return "Search"
        }
    }
}

#if os(macOS)

// MARK: - arXiv Feed Form View

/// Simplified form for creating arXiv category feeds.
///
/// Supports three modes:
/// - `.inboxFeed`: Creates a feed that auto-refreshes and populates the Inbox (default)
/// - `.librarySmartSearch(library)`: Creates a one-time smart search in a specific library
/// - `.explorationSearch`: Creates a one-time search in the Exploration library
public struct ArXivFeedFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Mode

    /// The mode determines where results are stored and whether auto-refresh is enabled
    public let mode: SearchFormMode

    // MARK: - Local State

    @State private var feedName: String = ""
    @State private var selectedCategories: Set<String> = []
    @State private var includeCrossListed: Bool = true
    @State private var expandedGroups: Set<String> = []
    @State private var isCreating: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    /// Maximum results to return (0 = use default, which is 500 for feeds)
    @State private var formMaxResults: Int = 0

    // MARK: - Edit Mode State

    @State private var editingFeed: CDSmartSearch?

    var isEditMode: Bool {
        editingFeed != nil
    }

    // MARK: - Initialization

    /// Create an arXiv feed form with the specified mode.
    /// - Parameter mode: The search form mode (defaults to `.explorationSearch` for backwards compatibility)
    public init(mode: SearchFormMode = .explorationSearch) {
        self.mode = mode
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        isEditMode ? "Edit arXiv Feed" : headerTitle,
                        systemImage: headerIcon
                    )
                    .font(.title2)
                    .fontWeight(.semibold)
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Feed Name Section
                feedNameSection

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
                        .disabled(selectedCategories.isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button {
                            createFeed()
                        } label: {
                            if isCreating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(mode.createButtonTitle)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedCategories.isEmpty || isCreating)
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
        .onReceive(NotificationCenter.default.publisher(for: .editArXivFeed)) { notification in
            if let feed = notification.object as? CDSmartSearch {
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

            TextField("Auto-generated from categories", text: $feedName)
                .textFieldStyle(.roundedBorder)

            Text("Leave blank to auto-generate from selected categories")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Categories Section

    @ViewBuilder
    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subject Categories")
                .font(.headline)

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

    private var autoGeneratedName: String {
        if selectedCategories.isEmpty {
            return ""
        }
        return selectedCategories.sorted().joined(separator: ", ")
    }

    private var effectiveFeedName: String {
        let trimmed = feedName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? autoGeneratedName : trimmed
    }

    private var headerTitle: String {
        switch mode {
        case .inboxFeed:
            return "Create arXiv Feed"
        case .librarySmartSearch:
            return "arXiv Category Search"
        case .explorationSearch:
            return "arXiv Category Search"
        }
    }

    private var headerIcon: String {
        switch mode {
        case .inboxFeed:
            return "antenna.radiowaves.left.and.right"
        case .librarySmartSearch, .explorationSearch:
            return "doc.text.magnifyingglass"
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .inboxFeed:
            return "Subscribe to categories for automatic Inbox updates"
        case .librarySmartSearch(let library):
            return "Search arXiv categories in \(library.displayName)"
        case .explorationSearch:
            return "Search papers by arXiv category"
        }
    }

    // MARK: - Actions

    private func createFeed() {
        guard !selectedCategories.isEmpty else { return }

        isCreating = true
        showError = false

        Task {
            do {
                // Build the query from categories
                let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(
                    searchTerms: [],  // No search terms for feed
                    categories: selectedCategories,
                    includeCrossListed: includeCrossListed,
                    dateFilter: .allDates,
                    sortBy: .submittedDateDesc
                )

                // Create the smart search using the appropriate factory method based on mode
                // Use formMaxResults if > 0, otherwise pass nil to use default
                let maxResultsParam: Int16? = formMaxResults > 0 ? Int16(formMaxResults) : nil
                let smartSearch: CDSmartSearch
                switch mode {
                case .inboxFeed:
                    smartSearch = SmartSearchRepository.shared.createInboxFeed(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        maxResults: maxResultsParam,
                        refreshIntervalSeconds: 3600
                    )

                case .librarySmartSearch(let library):
                    smartSearch = SmartSearchRepository.shared.createLibrarySmartSearch(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        library: library,
                        maxResults: maxResultsParam
                    )

                case .explorationSearch:
                    smartSearch = SmartSearchRepository.shared.createExplorationSearch(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        maxResults: maxResultsParam
                    )
                }

                Logger.viewModels.infoCapture(
                    "Created arXiv search '\(smartSearch.name)' with \(selectedCategories.count) categories (mode: \(mode.displayDescription))",
                    category: "feed"
                )

                // Execute initial fetch (only for inbox feeds)
                if case .inboxFeed = mode {
                    await executeInitialFetch(smartSearch)
                }

                // Notify sidebar to refresh
                await MainActor.run {
                    NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
                    NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
                }

                // Clear the form
                clearForm()

            } catch {
                Logger.viewModels.errorCapture("Failed to create search: \(error.localizedDescription)", category: "feed")
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

    private func executeInitialFetch(_ smartSearch: CDSmartSearch) async {
        // Use InboxCoordinator's PaperFetchService to execute the search and add to Inbox
        guard let fetchService = await InboxCoordinator.shared.paperFetchService else {
            Logger.viewModels.warningCapture(
                "InboxCoordinator not started, skipping initial feed fetch",
                category: "feed"
            )
            return
        }

        do {
            let fetchedCount = try await fetchService.fetchForInbox(smartSearch: smartSearch)
            Logger.viewModels.infoCapture(
                "Initial feed fetch complete: \(fetchedCount) papers added to Inbox",
                category: "feed"
            )
        } catch {
            Logger.viewModels.errorCapture(
                "Initial feed fetch failed: \(error.localizedDescription)",
                category: "feed"
            )
        }
    }

    private func saveToFeed() {
        guard let feed = editingFeed else { return }
        guard !selectedCategories.isEmpty else { return }

        // Build the query from categories
        let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(
            searchTerms: [],
            categories: selectedCategories,
            includeCrossListed: includeCrossListed,
            dateFilter: .allDates,
            sortBy: .submittedDateDesc
        )

        // Update the feed
        feed.name = effectiveFeedName
        feed.query = query
        feed.maxResults = Int16(formMaxResults)

        // Update the result collection name too
        feed.resultCollection?.name = effectiveFeedName

        // Save
        do {
            try PersistenceController.shared.viewContext.save()
            Logger.viewModels.infoCapture("Updated arXiv feed '\(feed.name)'", category: "feed")

            // Notify sidebar
            NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)

            // Exit edit mode
            exitEditMode()
        } catch {
            Logger.viewModels.errorCapture("Failed to save feed: \(error.localizedDescription)", category: "feed")
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func loadFeedForEditing(_ feed: CDSmartSearch) {
        editingFeed = feed
        feedName = feed.name

        // Parse the query to extract categories
        selectedCategories = parseCategoriesFromQuery(feed.query)

        // Default include cross-listed to true (we don't store this separately)
        includeCrossListed = !feed.query.contains("ANDNOT cross:")

        // Load maxResults from the feed
        formMaxResults = Int(feed.maxResults)

        Logger.viewModels.infoCapture(
            "Loaded feed '\(feed.name)' for editing with \(selectedCategories.count) categories",
            category: "feed"
        )
    }

    private func parseCategoriesFromQuery(_ query: String) -> Set<String> {
        var categories: Set<String> = []

        // Extract cat:xxx patterns from the query
        let pattern = #"cat:([^\s()]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))
            for match in matches {
                if let range = Range(match.range(at: 1), in: query) {
                    categories.insert(String(query[range]))
                }
            }
        }

        return categories
    }

    private func exitEditMode() {
        editingFeed = nil
        clearForm()
    }

    private func clearForm() {
        feedName = ""
        selectedCategories = []
        includeCrossListed = true
        showError = false
        errorMessage = ""
        formMaxResults = 0
    }
}

#elseif os(iOS)

// MARK: - iOS arXiv Feed Form View

/// iOS form for creating arXiv category feeds
///
/// Supports three modes:
/// - `.inboxFeed`: Creates a feed that auto-refreshes and populates the Inbox (default)
/// - `.librarySmartSearch(library)`: Creates a one-time smart search in a specific library
/// - `.explorationSearch`: Creates a one-time search in the Exploration library
public struct ArXivFeedFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Mode

    /// The mode determines where results are stored and whether auto-refresh is enabled
    public let mode: SearchFormMode

    // MARK: - Local State

    @State private var feedName: String = ""
    @State private var selectedCategories: Set<String> = []
    @State private var includeCrossListed: Bool = true
    @State private var expandedGroups: Set<String> = []
    @State private var isCreating: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    /// Maximum results to return (0 = use default, which is 500 for feeds)
    @State private var formMaxResults: Int = 0

    // MARK: - Edit Mode State

    @State private var editingFeed: CDSmartSearch?

    var isEditMode: Bool {
        editingFeed != nil
    }

    // MARK: - Initialization

    /// Create an arXiv feed form with the specified mode.
    /// - Parameter mode: The search form mode (defaults to `.explorationSearch` for backwards compatibility)
    public init(mode: SearchFormMode = .explorationSearch) {
        self.mode = mode
    }

    // MARK: - Body

    public var body: some View {
        Form {
            // Feed Name Section
            Section {
                TextField("Auto-generated from categories", text: $feedName)
            } header: {
                Text("Feed Name")
            } footer: {
                Text("Leave blank to auto-generate from selected categories")
            }

            // Categories Section
            Section("Subject Categories") {
                IOSArXivCategoryPickerView(
                    selectedCategories: $selectedCategories,
                    expandedGroups: $expandedGroups
                )

                if !selectedCategories.isEmpty {
                    Text("\(selectedCategories.count) categories selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .disabled(selectedCategories.isEmpty)
                } else {
                    Button {
                        createFeed()
                    } label: {
                        HStack {
                            Spacer()
                            if isCreating {
                                ProgressView()
                            } else {
                                Text(mode.createButtonTitle)
                            }
                            Spacer()
                        }
                    }
                    .disabled(selectedCategories.isEmpty || isCreating)
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
        .navigationTitle(isEditMode ? "Edit Feed" : navigationTitle)
        .onReceive(NotificationCenter.default.publisher(for: .editArXivFeed)) { notification in
            if let feed = notification.object as? CDSmartSearch {
                loadFeedForEditing(feed)
            }
        }
    }

    // MARK: - Computed Properties

    private var autoGeneratedName: String {
        if selectedCategories.isEmpty {
            return ""
        }
        return selectedCategories.sorted().joined(separator: ", ")
    }

    private var effectiveFeedName: String {
        let trimmed = feedName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? autoGeneratedName : trimmed
    }

    private var navigationTitle: String {
        switch mode {
        case .inboxFeed:
            return "arXiv Feed"
        case .librarySmartSearch, .explorationSearch:
            return "arXiv Search"
        }
    }

    // MARK: - Actions

    private func createFeed() {
        guard !selectedCategories.isEmpty else { return }

        isCreating = true
        showError = false

        Task {
            do {
                let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(
                    searchTerms: [],
                    categories: selectedCategories,
                    includeCrossListed: includeCrossListed,
                    dateFilter: .allDates,
                    sortBy: .submittedDateDesc
                )

                // Create the smart search using the appropriate factory method based on mode
                // Use formMaxResults if > 0, otherwise pass nil to use default
                let maxResultsParam: Int16? = formMaxResults > 0 ? Int16(formMaxResults) : nil
                let smartSearch: CDSmartSearch
                switch mode {
                case .inboxFeed:
                    smartSearch = SmartSearchRepository.shared.createInboxFeed(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        maxResults: maxResultsParam,
                        refreshIntervalSeconds: 3600
                    )

                case .librarySmartSearch(let library):
                    smartSearch = SmartSearchRepository.shared.createLibrarySmartSearch(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        library: library,
                        maxResults: maxResultsParam
                    )

                case .explorationSearch:
                    smartSearch = SmartSearchRepository.shared.createExplorationSearch(
                        name: effectiveFeedName,
                        query: query,
                        sourceIDs: ["arxiv"],
                        maxResults: maxResultsParam
                    )
                }

                Logger.viewModels.infoCapture(
                    "Created arXiv search '\(smartSearch.name)' with \(selectedCategories.count) categories (mode: \(mode.displayDescription))",
                    category: "feed"
                )

                // Execute initial fetch (only for inbox feeds)
                if case .inboxFeed = mode {
                    await executeInitialFetch(smartSearch)
                }

                await MainActor.run {
                    NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
                    NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
                }

                clearForm()

            } catch {
                Logger.viewModels.errorCapture("Failed to create search: \(error.localizedDescription)", category: "feed")
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

    private func executeInitialFetch(_ smartSearch: CDSmartSearch) async {
        guard let fetchService = await InboxCoordinator.shared.paperFetchService else {
            Logger.viewModels.warningCapture(
                "InboxCoordinator not started, skipping initial feed fetch",
                category: "feed"
            )
            return
        }

        do {
            let fetchedCount = try await fetchService.fetchForInbox(smartSearch: smartSearch)
            Logger.viewModels.infoCapture(
                "Initial feed fetch complete: \(fetchedCount) papers added to Inbox",
                category: "feed"
            )
        } catch {
            Logger.viewModels.errorCapture(
                "Initial feed fetch failed: \(error.localizedDescription)",
                category: "feed"
            )
        }
    }

    private func saveToFeed() {
        guard let feed = editingFeed else { return }
        guard !selectedCategories.isEmpty else { return }

        let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(
            searchTerms: [],
            categories: selectedCategories,
            includeCrossListed: includeCrossListed,
            dateFilter: .allDates,
            sortBy: .submittedDateDesc
        )

        feed.name = effectiveFeedName
        feed.query = query
        feed.maxResults = Int16(formMaxResults)
        feed.resultCollection?.name = effectiveFeedName

        do {
            try PersistenceController.shared.viewContext.save()
            Logger.viewModels.infoCapture("Updated arXiv feed '\(feed.name)'", category: "feed")
            NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
            exitEditMode()
        } catch {
            Logger.viewModels.errorCapture("Failed to save feed: \(error.localizedDescription)", category: "feed")
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func loadFeedForEditing(_ feed: CDSmartSearch) {
        editingFeed = feed
        feedName = feed.name
        selectedCategories = parseCategoriesFromQuery(feed.query)
        includeCrossListed = !feed.query.contains("ANDNOT cross:")
        formMaxResults = Int(feed.maxResults)

        Logger.viewModels.infoCapture(
            "Loaded feed '\(feed.name)' for editing with \(selectedCategories.count) categories",
            category: "feed"
        )
    }

    private func parseCategoriesFromQuery(_ query: String) -> Set<String> {
        var categories: Set<String> = []

        let pattern = #"cat:([^\s()]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))
            for match in matches {
                if let range = Range(match.range(at: 1), in: query) {
                    categories.insert(String(query[range]))
                }
            }
        }

        return categories
    }

    private func exitEditMode() {
        editingFeed = nil
        clearForm()
    }

    private func clearForm() {
        feedName = ""
        selectedCategories = []
        includeCrossListed = true
        showError = false
        errorMessage = ""
        formMaxResults = 0
    }
}

#endif  // os(macOS/iOS)

// MARK: - Feed Creation Error

enum FeedCreationError: LocalizedError {
    case noLibrary

    var errorDescription: String? {
        switch self {
        case .noLibrary:
            return "No library available. Please create a library first."
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when a feed should be edited (object is CDSmartSearch)
    static let editArXivFeed = Notification.Name("editArXivFeed")
}
