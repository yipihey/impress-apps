//
//  PaperFetchService.swift
//  PublicationManagerCore
//
//  Unified pipeline for fetching papers from any source and routing to Inbox.
//

import Foundation
import OSLog

// MARK: - Paper Fetch Service

/// Unified pipeline for fetching papers from any source and routing to Inbox.
///
/// This service provides a single entry point for all paper fetching that feeds the Inbox:
/// - Smart searches with `feedsToInbox: true`
/// - Ad-hoc searches via "Send to Inbox" action
///
/// The pipeline:
/// 1. Execute search query (via SourceManager)
/// 2. Apply mute filters (via InboxManager)
/// 3. Deduplicate against ALL libraries
/// 4. Route new papers to Inbox
public actor PaperFetchService {

    // MARK: - Dependencies

    private let sourceManager: SourceManager

    // MARK: - Store Access

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - State

    private var _isLoading = false
    private var lastFetchDate: Date?
    private var lastFetchCount: Int = 0

    // MARK: - Initialization

    public init(
        sourceManager: SourceManager
    ) {
        self.sourceManager = sourceManager
    }

    // MARK: - State Access

    public var isLoading: Bool { _isLoading }

    public var lastFetch: (date: Date, count: Int)? {
        guard let date = lastFetchDate else { return nil }
        return (date, lastFetchCount)
    }

    // MARK: - Fetch for Inbox

    /// Fetch papers from a smart search and add them to the Inbox.
    @discardableResult
    public func fetchForInbox(smartSearchID: UUID) async throws -> Int {
        let searchData = await withStore { store -> (query: String, name: String, feedsToInbox: Bool, maxResults: Int, sources: [String])? in
            guard let ss = store.getSmartSearch(id: smartSearchID) else { return nil }
            return (ss.query, ss.name, ss.feedsToInbox, ss.maxResults, ss.sourceIDs)
        }

        guard let data = searchData else { return 0 }

        guard data.feedsToInbox else {
            Logger.inbox.warningCapture(
                "Smart search '\(data.name)' does not feed to Inbox",
                category: "inbox"
            )
            return 0
        }

        Logger.inbox.infoCapture(
            "Fetching for Inbox: '\(data.name)' query: \(data.query)",
            category: "inbox"
        )

        _isLoading = true
        defer { _isLoading = false }

        let options = SearchOptions(
            maxResults: data.maxResults,
            sourceIDs: data.sources.isEmpty ? nil : data.sources
        )

        let results = try await sourceManager.search(query: data.query, options: options)
        Logger.inbox.debugCapture("Search returned \(results.count) results", category: "fetch")

        let newCount = await processResultsForInbox(results)

        lastFetchDate = Date()
        lastFetchCount = newCount

        Logger.inbox.infoCapture(
            "Inbox fetch complete: \(newCount) new papers from '\(data.name)'",
            category: "inbox"
        )

        return newCount
    }

    /// Fetch papers from an ad-hoc search and add them to the Inbox.
    @discardableResult
    public func fetchForInbox(
        query: String,
        sourceIDs: [String]? = nil,
        maxResults: Int = 50
    ) async throws -> Int {
        Logger.inbox.infoCapture("Ad-hoc Inbox fetch: '\(query)'", category: "fetch")

        _isLoading = true
        defer { _isLoading = false }

        let options = SearchOptions(maxResults: maxResults, sourceIDs: sourceIDs)
        let results = try await sourceManager.search(query: query, options: options)

        let newCount = await processResultsForInbox(results)

        lastFetchDate = Date()
        lastFetchCount = newCount

        Logger.inbox.infoCapture(
            "Ad-hoc Inbox fetch complete: \(newCount) new papers",
            category: "inbox"
        )

        return newCount
    }

    /// Send specific search results to the Inbox.
    @discardableResult
    public func sendToInbox(results: [SearchResult]) async -> Int {
        Logger.inbox.infoCapture("Sending \(results.count) results to Inbox", category: "fetch")
        return await processResultsForInbox(results)
    }

    // MARK: - Refresh All Inbox Feeds

    /// Refresh all smart searches that feed to the Inbox.
    @discardableResult
    public func refreshAllInboxFeeds() async throws -> Int {
        Logger.inbox.infoCapture("Refreshing all Inbox feeds", category: "fetch")

        _isLoading = true
        defer { _isLoading = false }

        let inboxFeeds = await withStore { store -> [SmartSearch] in
            store.listSmartSearches().filter { $0.feedsToInbox }
        }

        Logger.inbox.debugCapture("Found \(inboxFeeds.count) Inbox feeds to refresh", category: "fetch")

        var totalNew = 0
        for feed in inboxFeeds {
            do {
                let count = try await fetchForInbox(smartSearchID: feed.id)
                totalNew += count
            } catch {
                Logger.inbox.errorCapture(
                    "Failed to refresh feed '\(feed.name)': \(error)",
                    category: "inbox"
                )
            }
        }

        Logger.inbox.infoCapture("Inbox refresh complete: \(totalNew) total new papers", category: "fetch")
        return totalNew
    }

    // MARK: - Pipeline

    /// Process search results through the Inbox pipeline.
    private func processResultsForInbox(_ results: [SearchResult]) async -> Int {
        guard !results.isEmpty else { return 0 }

        let inboxManager = await MainActor.run { InboxManager.shared }

        // Filter results
        var filteredResults: [SearchResult] = []
        var mutedCount = 0
        var dismissedCount = 0

        for result in results {
            let shouldFilter = await MainActor.run {
                inboxManager.shouldFilter(result: result)
            }

            if shouldFilter {
                Logger.inbox.debugCapture("Filtered out muted paper: \(result.title)", category: "fetch")
                mutedCount += 1
                continue
            }

            let wasDismissed = await MainActor.run {
                inboxManager.wasDismissed(result: result)
            }

            if wasDismissed {
                Logger.inbox.debugCapture("Skipping previously dismissed paper: \(result.title)", category: "fetch")
                dismissedCount += 1
                continue
            }

            filteredResults.append(result)
        }

        Logger.inbox.debugCapture(
            "After filters: \(filteredResults.count) of \(results.count) papers remain (muted: \(mutedCount), dismissed: \(dismissedCount))",
            category: "fetch"
        )

        // Load identifier cache for O(1) deduplication
        let identifierCache = IdentifierCache()
        await identifierCache.loadFromDatabase()

        // Deduplicate against ALL libraries using O(1) hash lookups
        var newPaperIDs: [UUID] = []

        // Get default library for import
        let defaultLibraryId = await withStore { store -> UUID? in
            store.getDefaultLibrary()?.id ?? store.listLibraries().first?.id
        }

        guard let libraryId = defaultLibraryId else {
            Logger.inbox.errorCapture("No library available for import", category: "fetch")
            return 0
        }

        for result in filteredResults {
            let exists = await identifierCache.exists(result)
            if exists {
                Logger.inbox.debugCapture("Paper already exists: \(result.title)", category: "fetch")
                continue
            }

            // Create new publication via RustStoreAdapter
            let bibtex = result.toBibTeX()
            let importedIDs = await withStore { $0.importBibTeX(bibtex, libraryId: libraryId) }
            newPaperIDs.append(contentsOf: importedIDs)

            // Update cache to prevent duplicates within this batch
            await identifierCache.addFromResult(result)
        }

        Logger.inbox.debugCapture("Created \(newPaperIDs.count) new papers for Inbox", category: "fetch")

        // Add all new papers to Inbox
        if !newPaperIDs.isEmpty {
            await MainActor.run {
                _ = inboxManager.addToInboxBatch(newPaperIDs)
            }
        }

        return newPaperIDs.count
    }
}

// MARK: - Fetch Status

/// Status of a paper fetch operation.
public enum FetchStatus: Sendable {
    case idle
    case loading
    case completed(count: Int, date: Date)
    case failed(Error)
}
