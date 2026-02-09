//
//  ArXivFeedFormView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-15.
//

import SwiftUI
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
    case librarySmartSearch(UUID, String)  // (libraryID, libraryName)

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
        case .librarySmartSearch(_, let name):
            return "Smart search in \(name)"
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
/// - `.librarySmartSearch(id, name)`: Creates a one-time smart search in a specific library
/// - `.explorationSearch`: Creates a one-time search in the Exploration library
public struct ArXivFeedFormView: View {

    // MARK: - Environment

    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager

    // MARK: - Mode

    public let mode: SearchFormMode

    // MARK: - Local State

    @State private var feedName: String = ""
    @State private var selectedCategories: Set<String> = []
    @State private var includeCrossListed: Bool = true
    @State private var expandedGroups: Set<String> = []
    @State private var isCreating: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var formMaxResults: Int = 0

    // MARK: - Edit Mode State

    @State private var editingFeedID: UUID?
    @State private var editingFeedName: String = ""

    var isEditMode: Bool { editingFeedID != nil }

    // MARK: - Initialization

    public init(mode: SearchFormMode = .explorationSearch) {
        self.mode = mode
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(isEditMode ? "Edit arXiv Feed" : headerTitle, systemImage: headerIcon)
                        .font(.title2).fontWeight(.semibold)
                    Text(headerSubtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                feedNameSection
                categoriesSection

                Toggle("Include cross-listed papers", isOn: $includeCrossListed)
                    .toggleStyle(.checkbox).font(.subheadline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Max Results").font(.headline)
                    HStack {
                        TextField("default", value: $formMaxResults, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("(0 = use default: 500 for feeds)").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider().padding(.vertical, 8)

                if isEditMode {
                    HStack {
                        Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                        Text("Editing: \(editingFeedName)").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { exitEditMode() }.buttonStyle(.plain).foregroundStyle(.red)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(Color.orange.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Button("Clear All") { clearForm() }.buttonStyle(.bordered)
                    Spacer()
                    if isEditMode {
                        Button("Save") { saveToFeed() }
                            .buttonStyle(.borderedProminent).disabled(selectedCategories.isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                    } else {
                        if let url = buildArXivWebURL() {
                            Button { openInBrowser(url) } label: { Label("Browser", systemImage: "safari") }
                                .buttonStyle(.bordered).help("Preview this category on arXiv website")
                        }
                        Button { createFeed() } label: {
                            if isCreating { ProgressView().controlSize(.small) }
                            else { Text(mode.createButtonTitle) }
                        }
                        .buttonStyle(.borderedProminent).disabled(selectedCategories.isEmpty || isCreating)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }

                if showError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(errorMessage).font(.subheadline).foregroundStyle(.red)
                    }
                    .padding().background(Color.red.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .editArXivFeed)) { notification in
            if let feedID = notification.object as? UUID { loadFeedForEditing(feedID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prefillArxivCategory)) { notification in
            if let categoryQuery = notification.userInfo?["category"] as? String { prefillCategory(from: categoryQuery) }
        }
    }

    @ViewBuilder private var feedNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feed Name").font(.headline)
            TextField("Auto-generated from categories", text: $feedName).textFieldStyle(.roundedBorder)
            Text("Leave blank to auto-generate from selected categories").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subject Categories").font(.headline)
            ArXivCategoryPickerView(selectedCategories: $selectedCategories, expandedGroups: $expandedGroups)
            if !selectedCategories.isEmpty {
                HStack {
                    Text("\(selectedCategories.count) selected:").font(.caption).foregroundStyle(.secondary)
                    Text(selectedCategories.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private var autoGeneratedName: String { selectedCategories.isEmpty ? "" : selectedCategories.sorted().joined(separator: ", ") }
    private var effectiveFeedName: String { let t = feedName.trimmingCharacters(in: .whitespaces); return t.isEmpty ? autoGeneratedName : t }

    private var headerTitle: String {
        switch mode { case .inboxFeed: return "Create arXiv Feed"; default: return "arXiv Category Search" }
    }
    private var headerIcon: String {
        switch mode { case .inboxFeed: return "antenna.radiowaves.left.and.right"; default: return "doc.text.magnifyingglass" }
    }
    private var headerSubtitle: String {
        switch mode {
        case .inboxFeed: return "Subscribe to categories for automatic Inbox updates"
        case .librarySmartSearch(_, let name): return "Search arXiv categories in \(name)"
        case .explorationSearch: return "Search papers by arXiv category"
        }
    }

    // MARK: - Actions

    private func createFeed() {
        guard !selectedCategories.isEmpty else { return }
        isCreating = true; showError = false
        Task {
            do {
                let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(searchTerms: [], categories: selectedCategories, includeCrossListed: includeCrossListed, dateFilter: .allDates, sortBy: .submittedDateDesc)
                let maxResultsParam: Int16? = formMaxResults > 0 ? Int16(formMaxResults) : nil
                let smartSearch: SmartSearch?
                switch mode {
                case .inboxFeed:
                    smartSearch = RustStoreAdapter.shared.createInboxFeed(name: effectiveFeedName, query: query, sourceIDs: ["arxiv"], maxResults: maxResultsParam, refreshIntervalSeconds: 3600)
                case .librarySmartSearch(let libraryID, _):
                    smartSearch = RustStoreAdapter.shared.createLibrarySmartSearch(name: effectiveFeedName, query: query, sourceIDs: ["arxiv"], libraryID: libraryID, maxResults: maxResultsParam)
                case .explorationSearch:
                    smartSearch = RustStoreAdapter.shared.createExplorationSearch(name: effectiveFeedName, query: query, sourceIDs: ["arxiv"], maxResults: maxResultsParam)
                }
                guard let smartSearch else { Logger.viewModels.warningCapture("Failed to create smart search", category: "feed"); return }
                Logger.viewModels.infoCapture("Created arXiv search '\(smartSearch.name)' with \(selectedCategories.count) categories (mode: \(mode.displayDescription))", category: "feed")
                if case .inboxFeed = mode { await executeInitialFetch(smartSearch) }
                await MainActor.run {
                    NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
                    NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
                }
                clearForm()
            } catch {
                Logger.viewModels.errorCapture("Failed to create search: \(error.localizedDescription)", category: "feed")
                await MainActor.run { errorMessage = error.localizedDescription; showError = true }
            }
            await MainActor.run { isCreating = false }
        }
    }

    private func executeInitialFetch(_ smartSearch: SmartSearch) async {
        guard let fetchService = await InboxCoordinator.shared.paperFetchService else {
            Logger.viewModels.warningCapture("InboxCoordinator not started, skipping initial feed fetch", category: "feed"); return
        }
        do {
            let fetchedCount = try await fetchService.fetchForInbox(smartSearchID: smartSearch.id)
            Logger.viewModels.infoCapture("Initial feed fetch complete: \(fetchedCount) papers added to Inbox", category: "feed")
        } catch {
            Logger.viewModels.errorCapture("Initial feed fetch failed: \(error.localizedDescription)", category: "feed")
        }
    }

    private func saveToFeed() {
        guard let feedID = editingFeedID, !selectedCategories.isEmpty else { return }
        let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(searchTerms: [], categories: selectedCategories, includeCrossListed: includeCrossListed, dateFilter: .allDates, sortBy: .submittedDateDesc)
        RustStoreAdapter.shared.updateSmartSearch(feedID, name: effectiveFeedName, query: query, maxResults: Int16(formMaxResults))
        Logger.viewModels.infoCapture("Updated arXiv feed '\(effectiveFeedName)'", category: "feed")
        NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
        exitEditMode()
    }

    private func loadFeedForEditing(_ feedID: UUID) {
        guard let feed = RustStoreAdapter.shared.smartSearch(by: feedID) else { return }
        editingFeedID = feed.id; editingFeedName = feed.name; feedName = feed.name
        selectedCategories = parseCategoriesFromQuery(feed.query)
        includeCrossListed = !feed.query.contains("ANDNOT cross:")
        formMaxResults = Int(feed.maxResults)
        Logger.viewModels.infoCapture("Loaded feed '\(feed.name)' for editing with \(selectedCategories.count) categories", category: "feed")
    }

    private func parseCategoriesFromQuery(_ query: String) -> Set<String> {
        var categories: Set<String> = []
        let pattern = #"cat:([^\s()]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))
            for match in matches { if let range = Range(match.range(at: 1), in: query) { categories.insert(String(query[range])) } }
        }
        return categories
    }

    private func exitEditMode() { editingFeedID = nil; editingFeedName = ""; clearForm() }
    private func clearForm() { feedName = ""; selectedCategories = []; includeCrossListed = true; showError = false; errorMessage = ""; formMaxResults = 0 }

    private func prefillCategory(from query: String) {
        let category = query.hasPrefix("cat:") ? String(query.dropFirst(4)) : query
        selectedCategories = [category]
        if let group = ArXivCategories.groups.first(where: { $0.categories.contains { $0.id == category } }) { expandedGroups.insert(group.id) }
        feedName = "arXiv \(category)"
    }

    private func buildArXivWebURL() -> URL? {
        guard !selectedCategories.isEmpty, let category = selectedCategories.sorted().first else { return nil }
        return URL(string: "https://arxiv.org/list/\(category)/recent")
    }

    private func openInBrowser(_ url: URL) { NSWorkspace.shared.open(url) }
}

#elseif os(iOS)

// MARK: - iOS arXiv Feed Form View

public struct ArXivFeedFormView: View {
    @Environment(SearchViewModel.self) private var searchViewModel
    @Environment(LibraryManager.self) private var libraryManager
    public let mode: SearchFormMode

    @State private var feedName: String = ""
    @State private var selectedCategories: Set<String> = []
    @State private var includeCrossListed: Bool = true
    @State private var expandedGroups: Set<String> = []
    @State private var isCreating: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var formMaxResults: Int = 0
    @State private var editingFeedID: UUID?
    @State private var editingFeedName: String = ""

    var isEditMode: Bool { editingFeedID != nil }

    public init(mode: SearchFormMode = .explorationSearch) { self.mode = mode }

    public var body: some View {
        Form {
            Section { TextField("Auto-generated from categories", text: $feedName) } header: { Text("Feed Name") } footer: { Text("Leave blank to auto-generate from selected categories") }
            Section("Subject Categories") {
                IOSArXivCategoryPickerView(selectedCategories: $selectedCategories, expandedGroups: $expandedGroups)
                if !selectedCategories.isEmpty { Text("\(selectedCategories.count) categories selected").font(.caption).foregroundStyle(.secondary) }
            }
            Section { Toggle("Include cross-listed papers", isOn: $includeCrossListed) }
            Section { HStack { Text("Max Results"); Spacer(); TextField("default", value: $formMaxResults, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80) } } footer: { Text("0 = use default (500 for feeds)") }
            if isEditMode {
                Section { HStack { Image(systemName: "pencil.circle.fill").foregroundStyle(.orange); Text("Editing: \(editingFeedName)").foregroundStyle(.secondary); Spacer(); Button("Cancel") { exitEditMode() }.foregroundStyle(.red) } }
            }
            Section {
                if isEditMode {
                    Button("Save") { saveToFeed() }.frame(maxWidth: .infinity).disabled(selectedCategories.isEmpty)
                } else {
                    Button { createFeed() } label: { HStack { Spacer(); if isCreating { ProgressView() } else { Text(mode.createButtonTitle) }; Spacer() } }.disabled(selectedCategories.isEmpty || isCreating)
                }
                Button("Clear All", role: .destructive) { clearForm() }.frame(maxWidth: .infinity)
            }
            if showError { Section { HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(errorMessage).foregroundStyle(.red) } } }
        }
        .navigationTitle(isEditMode ? "Edit Feed" : (mode == .inboxFeed ? "arXiv Feed" : "arXiv Search"))
        .onReceive(NotificationCenter.default.publisher(for: .editArXivFeed)) { notification in if let feedID = notification.object as? UUID { loadFeedForEditing(feedID) } }
        .onReceive(NotificationCenter.default.publisher(for: .prefillArxivCategory)) { notification in if let categoryQuery = notification.userInfo?["category"] as? String { prefillCategory(from: categoryQuery) } }
    }

    private var autoGeneratedName: String { selectedCategories.isEmpty ? "" : selectedCategories.sorted().joined(separator: ", ") }
    private var effectiveFeedName: String { let t = feedName.trimmingCharacters(in: .whitespaces); return t.isEmpty ? autoGeneratedName : t }

    private func createFeed() {
        guard !selectedCategories.isEmpty else { return }
        isCreating = true; showError = false
        Task {
            do {
                let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(searchTerms: [], categories: selectedCategories, includeCrossListed: includeCrossListed, dateFilter: .allDates, sortBy: .submittedDateDesc)
                let maxResultsParam: Int16? = formMaxResults > 0 ? Int16(formMaxResults) : nil
                let smartSearch: SmartSearch?
                switch mode {
                case .inboxFeed:
                    smartSearch = RustStoreAdapter.shared.createInboxFeed(name: effectiveFeedName, query: query, sourceIDs: ["arxiv"], maxResults: maxResultsParam, refreshIntervalSeconds: 3600)
                case .librarySmartSearch(let libraryID, _):
                    smartSearch = RustStoreAdapter.shared.createLibrarySmartSearch(name: effectiveFeedName, query: query, sourceIDs: ["arxiv"], libraryID: libraryID, maxResults: maxResultsParam)
                case .explorationSearch:
                    smartSearch = RustStoreAdapter.shared.createExplorationSearch(name: effectiveFeedName, query: query, sourceIDs: ["arxiv"], maxResults: maxResultsParam)
                }
                guard let smartSearch else { Logger.viewModels.warningCapture("Failed to create smart search", category: "feed"); return }
                Logger.viewModels.infoCapture("Created arXiv search '\(smartSearch.name)' with \(selectedCategories.count) categories", category: "feed")
                if case .inboxFeed = mode { await executeInitialFetch(smartSearch) }
                await MainActor.run { NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil); NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id) }
                clearForm()
            } catch {
                Logger.viewModels.errorCapture("Failed to create search: \(error.localizedDescription)", category: "feed")
                await MainActor.run { errorMessage = error.localizedDescription; showError = true }
            }
            await MainActor.run { isCreating = false }
        }
    }

    private func executeInitialFetch(_ smartSearch: SmartSearch) async {
        guard let fetchService = await InboxCoordinator.shared.paperFetchService else { return }
        do { let c = try await fetchService.fetchForInbox(smartSearchID: smartSearch.id); Logger.viewModels.infoCapture("Initial feed fetch: \(c) papers", category: "feed") } catch { Logger.viewModels.errorCapture("Initial feed fetch failed: \(error.localizedDescription)", category: "feed") }
    }

    private func saveToFeed() {
        guard let feedID = editingFeedID, !selectedCategories.isEmpty else { return }
        let query = SearchFormQueryBuilder.buildArXivAdvancedQuery(searchTerms: [], categories: selectedCategories, includeCrossListed: includeCrossListed, dateFilter: .allDates, sortBy: .submittedDateDesc)
        RustStoreAdapter.shared.updateSmartSearch(feedID, name: effectiveFeedName, query: query, maxResults: Int16(formMaxResults))
        Logger.viewModels.infoCapture("Updated arXiv feed '\(effectiveFeedName)'", category: "feed")
        NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
        exitEditMode()
    }

    private func loadFeedForEditing(_ feedID: UUID) {
        guard let feed = RustStoreAdapter.shared.smartSearch(by: feedID) else { return }
        editingFeedID = feed.id; editingFeedName = feed.name; feedName = feed.name
        selectedCategories = parseCategoriesFromQuery(feed.query)
        includeCrossListed = !feed.query.contains("ANDNOT cross:"); formMaxResults = Int(feed.maxResults)
    }

    private func parseCategoriesFromQuery(_ query: String) -> Set<String> {
        var categories: Set<String> = []
        let pattern = #"cat:([^\s()]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))
            for match in matches { if let range = Range(match.range(at: 1), in: query) { categories.insert(String(query[range])) } }
        }
        return categories
    }

    private func exitEditMode() { editingFeedID = nil; editingFeedName = ""; clearForm() }
    private func clearForm() { feedName = ""; selectedCategories = []; includeCrossListed = true; showError = false; errorMessage = ""; formMaxResults = 0 }

    private func prefillCategory(from query: String) {
        let category = query.hasPrefix("cat:") ? String(query.dropFirst(4)) : query
        selectedCategories = [category]
        if let group = ArXivCategories.groups.first(where: { $0.categories.contains { $0.id == category } }) { expandedGroups.insert(group.id) }
        feedName = "arXiv \(category)"
    }
}

#endif

// MARK: - Feed Creation Error

enum FeedCreationError: LocalizedError {
    case noLibrary
    var errorDescription: String? { "No library available. Please create a library first." }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when a feed should be edited (object is UUID)
    static let editArXivFeed = Notification.Name("editArXivFeed")
}
