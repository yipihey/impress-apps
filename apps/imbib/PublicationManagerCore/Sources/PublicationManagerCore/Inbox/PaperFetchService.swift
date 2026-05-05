//
//  PaperFetchService.swift
//  PublicationManagerCore
//
//  Unified pipeline for fetching papers from any source and routing to feed collections.
//

import Foundation
import ImpressStoreKit
import OSLog

// MARK: - Paper Fetch Service

/// Unified pipeline for fetching papers from any source and routing to feed collections.
///
/// This service provides a single entry point for all paper fetching:
/// - Smart searches with `feedsToInbox: true` (legacy inbox path)
/// - Smart searches with `autoRefreshEnabled` (generalized feed path)
/// - Ad-hoc searches via "Send to Inbox" action
///
/// The pipeline:
/// 1. Execute search query (via SourceManager)
/// 2. Apply mute filters (via MuteService)
/// 3. Deduplicate against permanent libraries (excluding Dismissed/Exploration)
/// 4. Route new papers to target collection (inbox or per-feed save target)
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
    ///
    /// Routes through `BackgroundOperationQueue` with dedupe key
    /// `"feed-refresh-<id>"` — the same key that `FeedScheduler` uses
    /// for scheduled refreshes. A manual refresh that arrives while a
    /// scheduled refresh of the same feed is already in flight is
    /// dropped and returns 0 (the scheduled refresh will still publish
    /// results). Priority is `.userInitiated` so the refresh bypasses
    /// the 90s startup grace.
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

        // Group feeds need special handling — route through GroupFeedRefreshService.
        // GroupFeedRefreshService already queues internally, so we don't
        // wrap it again here (a second queue op would just dedup-drop).
        if data.query.hasPrefix("GROUP_FEED|") {
            Logger.inbox.infoCapture(
                "Routing group feed '\(data.name)' through GroupFeedRefreshService",
                category: "inbox"
            )
            let groupService = GroupFeedRefreshService.shared
            return try await groupService.refreshGroupFeedByID(smartSearchID)
        }

        // Non-group manual refresh: wrap in the shared operation queue
        // so it deduplicates against any scheduled refresh of the same
        // feed. Same dedupe key that `FeedScheduler` uses.
        let feedID = smartSearchID
        let feedName = data.name
        let feedQuery = data.query
        let feedMaxResults = data.maxResults
        let feedSources = data.sources
        let result: AwaitResult<Int> = try await BackgroundOperationQueue.shared.submitAndAwait(
            kind: .network,
            priority: .userInitiated,
            dedupeKey: "feed-refresh-\(feedID.uuidString)",
            label: "ManualInboxFetch[\(feedName)]"
        ) { _ in
            try await self.performInboxFetch(
                feedID: feedID,
                feedName: feedName,
                query: feedQuery,
                maxResults: feedMaxResults,
                sources: feedSources
            )
        }

        switch result {
        case .completed(let count):
            return count
        case .deduped:
            Logger.inbox.infoCapture(
                "Manual refresh of '\(feedName)' deduped — a refresh of this feed is already in flight",
                category: "inbox"
            )
            return 0
        case .refusedStartupGrace:
            // Shouldn't happen — user-initiated bypasses grace — but
            // fall through cleanly if it ever does.
            return 0
        }
    }

    /// Actual inbox-fetch body, invoked from inside the queue operation.
    private func performInboxFetch(
        feedID: UUID,
        feedName: String,
        query: String,
        maxResults: Int,
        sources: [String]
    ) async throws -> Int {
        Logger.inbox.infoCapture(
            "Fetching for Inbox: '\(feedName)' query: \(query)",
            category: "inbox"
        )

        _isLoading = true
        defer { _isLoading = false }

        let options = SearchOptions(
            maxResults: maxResults,
            sourceIDs: sources.isEmpty ? nil : sources
        )

        let results = try await sourceManager.search(query: query, options: options)
        Logger.inbox.debugCapture("Search returned \(results.count) results", category: "fetch")

        let newCount = await processResultsForInbox(results, feedID: feedID)

        lastFetchDate = Date()
        lastFetchCount = newCount

        Logger.inbox.infoCapture(
            "Inbox fetch complete: \(newCount) new papers from '\(feedName)'",
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

    // MARK: - Generalized Feed Fetch

    /// Fetch papers for any auto-refresh smart search collection.
    ///
    /// This is the generalized entry point used by `FeedScheduler`. It reads the
    /// smart search configuration and routes papers appropriately:
    /// - If `feedsToInbox` is set, papers go to the Inbox (legacy path)
    /// - Otherwise, papers are imported and the smart search's `saveTargetID` or
    ///   parent library is used as the import target
    @discardableResult
    public func fetchForFeed(smartSearchID: UUID) async throws -> Int {
        let searchData = await withStore { store -> (query: String, name: String, feedsToInbox: Bool, autoRefreshEnabled: Bool, maxResults: Int, sources: [String], saveTargetID: UUID?, libraryID: UUID?)? in
            guard let ss = store.getSmartSearch(id: smartSearchID) else { return nil }
            return (ss.query, ss.name, ss.feedsToInbox, ss.autoRefreshEnabled, ss.maxResults, ss.sourceIDs, ss.saveTargetID, ss.libraryID)
        }

        guard let data = searchData else { return 0 }

        // For feedsToInbox feeds, use the existing inbox path
        if data.feedsToInbox {
            return try await fetchForInbox(smartSearchID: smartSearchID)
        }

        // For other auto-refresh feeds, use the generalized path
        guard data.autoRefreshEnabled else {
            Logger.inbox.warningCapture(
                "Smart search '\(data.name)' is not auto-refresh enabled",
                category: "feed"
            )
            return 0
        }

        // Group feeds need special handling — route through GroupFeedRefreshService
        if data.query.hasPrefix("GROUP_FEED|") {
            Logger.inbox.infoCapture(
                "Routing group feed '\(data.name)' through GroupFeedRefreshService",
                category: "feed"
            )
            let groupService = GroupFeedRefreshService.shared
            let count = try await groupService.refreshGroupFeedByID(smartSearchID)
            await MainActor.run {
                RustStoreAdapter.shared.updateIntField(id: smartSearchID, field: "last_executed", value: Int64(Date().timeIntervalSince1970 * 1000))
                RustStoreAdapter.shared.updateIntField(id: smartSearchID, field: "last_fetch_count", value: Int64(count))
            }
            return count
        }

        Logger.inbox.infoCapture(
            "Fetching for feed: '\(data.name)' query: \(data.query)",
            category: "feed"
        )

        _isLoading = true
        defer { _isLoading = false }

        let options = SearchOptions(
            maxResults: data.maxResults,
            sourceIDs: data.sources.isEmpty ? nil : data.sources
        )

        let results = try await sourceManager.search(query: data.query, options: options)
        Logger.inbox.debugCapture("Search returned \(results.count) results for feed '\(data.name)'", category: "feed")

        // Determine target library: saveTargetID > libraryID > default library
        let targetLibraryID = data.saveTargetID ?? data.libraryID

        let newCount = await processResultsForFeed(results, targetLibraryID: targetLibraryID, feedID: smartSearchID)

        lastFetchDate = Date()
        lastFetchCount = newCount

        // Update last_executed timestamp on the smart search
        await MainActor.run {
            RustStoreAdapter.shared.updateIntField(id: smartSearchID, field: "last_executed", value: Int64(Date().timeIntervalSince1970 * 1000))
            RustStoreAdapter.shared.updateIntField(id: smartSearchID, field: "last_fetch_count", value: Int64(newCount))
        }

        Logger.inbox.infoCapture(
            "Feed fetch complete: \(newCount) new papers from '\(data.name)'",
            category: "feed"
        )

        return newCount
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

    /// Process search results for a generalized feed collection.
    ///
    /// Similar to `processResultsForInbox` but routes to the specified target library
    /// instead of the Inbox. Uses MuteService directly for filtering.
    private func processResultsForFeed(_ results: [SearchResult], targetLibraryID: UUID?, feedID: UUID? = nil) async -> Int {
        guard !results.isEmpty else { return 0 }

        // Filter results in a single MainActor hop — avoids N mutex
        // acquisitions that would starve the main thread.
        let filterResult: (filtered: [SearchResult], muted: Int, dismissed: Int) = await MainActor.run {
            let muteService = MuteService.shared
            let inboxManager = InboxManager.shared
            var filtered: [SearchResult] = []
            var muted = 0
            var dismissed = 0
            for result in results {
                if muteService.shouldFilter(result: result) {
                    muted += 1
                    continue
                }
                if inboxManager.wasDismissed(result: result) {
                    dismissed += 1
                    continue
                }
                filtered.append(result)
            }
            return (filtered, muted, dismissed)
        }
        let filteredResults = filterResult.filtered
        let mutedCount = filterResult.muted
        let dismissedCount = filterResult.dismissed

        Logger.inbox.debugCapture(
            "Feed filter: \(filteredResults.count) of \(results.count) remain (muted: \(mutedCount), dismissed: \(dismissedCount))",
            category: "feed"
        )

        // Load identifier cache for O(1) deduplication
        let identifierCache = IdentifierCache()
        await identifierCache.loadFromDatabase()

        // Determine import library
        let importLibraryId = await withStore { store -> UUID? in
            if let target = targetLibraryID {
                return target
            }
            return store.getDefaultLibrary()?.id ?? store.listLibraries().first?.id
        }

        guard let libraryId = importLibraryId else {
            Logger.inbox.errorCapture("No library available for feed import", category: "feed")
            return 0
        }

        var newPaperIDs: [UUID] = []

        for result in filteredResults {
            let exists = await identifierCache.exists(result)
            if exists { continue }

            let bibtex = result.toBibTeX()
            let importedIDs = await withStore { $0.importBibTeX(bibtex, libraryId: libraryId) }
            newPaperIDs.append(contentsOf: importedIDs)
            await identifierCache.addFromResult(result)
        }

        Logger.inbox.debugCapture("Created \(newPaperIDs.count) new papers for feed", category: "feed")

        // Mark new papers as unread and link to the feed for unread count tracking
        if !newPaperIDs.isEmpty {
            await MainActor.run {
                RustStoreAdapter.shared.setRead(ids: newPaperIDs, read: false)
                if let feedID {
                    RustStoreAdapter.shared.addToCollection(publicationIds: newPaperIDs, collectionId: feedID)
                }
            }
        }

        return newPaperIDs.count
    }

    /// Process search results through the Inbox pipeline.
    private func processResultsForInbox(_ results: [SearchResult], feedID: UUID? = nil) async -> Int {
        guard !results.isEmpty else { return 0 }

        // Filter results in a single MainActor hop — avoids N mutex
        // acquisitions that would starve the main thread when the SQLite
        // lock is contended.
        let filterResult: (filtered: [SearchResult], muted: Int, dismissed: Int) = await MainActor.run {
            let inboxManager = InboxManager.shared
            var filtered: [SearchResult] = []
            var muted = 0
            var dismissed = 0
            for result in results {
                if inboxManager.shouldFilter(result: result) {
                    muted += 1
                    continue
                }
                if inboxManager.wasDismissed(result: result) {
                    dismissed += 1
                    continue
                }
                filtered.append(result)
            }
            return (filtered, muted, dismissed)
        }
        let filteredResults = filterResult.filtered
        let mutedCount = filterResult.muted
        let dismissedCount = filterResult.dismissed

        Logger.inbox.debugCapture(
            "After filters: \(filteredResults.count) of \(results.count) papers remain (muted: \(mutedCount), dismissed: \(dismissedCount))",
            category: "fetch"
        )

        // Batch-resolve existing publications by all identifiers in one query
        let allDois = filteredResults.compactMap { $0.doi?.lowercased() }
        let allArxivIds = filteredResults.compactMap { $0.arxivID.map(IdentifierExtractor.normalizeArXivID) }
        let allBibcodes = filteredResults.compactMap { $0.bibcode?.uppercased() }

        let store = await MainActor.run { RustStoreAdapter.shared }
        let existingPubs = store.findByIdentifiersBatchBackground(
            dois: allDois,
            arxivIds: allArxivIds,
            bibcodes: allBibcodes
        )

        // Build lookup maps
        var doiMap: [String: UUID] = [:]
        var arxivMap: [String: UUID] = [:]
        var bibcodeMap: [String: UUID] = [:]
        for pub in existingPubs {
            if let doi = pub.doi?.lowercased(), !doi.isEmpty { doiMap[doi] = pub.id }
            if let arxiv = pub.arxivID, !arxiv.isEmpty {
                arxivMap[IdentifierExtractor.normalizeArXivID(arxiv)] = pub.id
            }
            if let bc = pub.bibcode?.uppercased(), !bc.isEmpty { bibcodeMap[bc] = pub.id }
        }

        // Get default library for import
        let defaultLibraryId = await withStore { store -> UUID? in
            store.getDefaultLibrary()?.id ?? store.listLibraries().first?.id
        }

        guard let libraryId = defaultLibraryId else {
            Logger.inbox.errorCapture("No library available for import", category: "fetch")
            return 0
        }

        // Sort results into: existing papers (to link to feed) vs new papers (to import)
        var existingPaperIDs: [UUID] = []
        var newPaperIDs: [UUID] = []

        for result in filteredResults {
            // Check existing by each identifier
            var existingID: UUID?
            if let doi = result.doi?.lowercased(), let id = doiMap[doi] {
                existingID = id
            } else if let arxiv = result.arxivID {
                let normalized = IdentifierExtractor.normalizeArXivID(arxiv)
                if let id = arxivMap[normalized] { existingID = id }
            } else if let bc = result.bibcode?.uppercased(), let id = bibcodeMap[bc] {
                existingID = id
            }

            if let id = existingID {
                existingPaperIDs.append(id)
                continue
            }

            // Create new publication via RustStoreAdapter
            let bibtex = result.toBibTeX()
            let importedIDs = await withStore { $0.importBibTeX(bibtex, libraryId: libraryId) }
            newPaperIDs.append(contentsOf: importedIDs)

            // Add to maps so duplicates within this batch are caught
            if let doi = result.doi?.lowercased(), let first = importedIDs.first {
                doiMap[doi] = first
            }
            if let arxiv = result.arxivID, let first = importedIDs.first {
                arxivMap[IdentifierExtractor.normalizeArXivID(arxiv)] = first
            }
            if let bc = result.bibcode?.uppercased(), let first = importedIDs.first {
                bibcodeMap[bc] = first
            }
        }

        Logger.inbox.debugCapture(
            "Inbox fetch: \(newPaperIDs.count) new, \(existingPaperIDs.count) existing (will link to feed)",
            category: "fetch"
        )

        // Add all new papers to Inbox and link to the feed
        if !newPaperIDs.isEmpty {
            await MainActor.run {
                _ = InboxManager.shared.addToInboxBatch(newPaperIDs)
            }
        }

        // Link existing + new papers to the feed's smart search collection.
        // Existing papers are linked but NOT added to the Inbox library again.
        if let feedID {
            let allPaperIDs = existingPaperIDs + newPaperIDs
            if !allPaperIDs.isEmpty {
                await MainActor.run {
                    RustStoreAdapter.shared.addToCollection(publicationIds: allPaperIDs, collectionId: feedID)
                }
            }
        }

        return newPaperIDs.count + existingPaperIDs.count
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
