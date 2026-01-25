//
//  ShareExtensionHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation
import OSLog

/// Handles processing of shared items from the share extension.
///
/// This class extracts the common share extension handling logic used by both
/// macOS and iOS apps, avoiding code duplication.
@MainActor
public final class ShareExtensionHandler {

    // MARK: - Dependencies

    private let libraryManager: LibraryManager
    private let sourceManager: SourceManager
    private let repository: PublicationRepository

    // MARK: - Initialization

    public init(
        libraryManager: LibraryManager,
        sourceManager: SourceManager,
        repository: PublicationRepository = PublicationRepository()
    ) {
        self.libraryManager = libraryManager
        self.sourceManager = sourceManager
        self.repository = repository
    }

    // MARK: - Darwin Notification Observer

    /// Set up Darwin notification observer for cross-process notifications from the share extension.
    ///
    /// Call this once on app startup. The Darwin notification from the extension will be
    /// converted to a local `NotificationCenter` notification that the app can observe.
    public static func setupDarwinNotificationObserver() {
        let darwinName = "com.imbib.sharedURLReceived" as CFString

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                // Convert Darwin notification to local NotificationCenter notification
                // This runs on an arbitrary thread, so dispatch to main
                DispatchQueue.main.async {
                    Logger.shareExtension.infoCapture("Received Darwin notification from share extension", category: "shareext")
                    NotificationCenter.default.post(name: ShareExtensionService.sharedURLReceivedNotification, object: nil)
                }
            },
            darwinName,
            nil,
            .deliverImmediately
        )

        Logger.shareExtension.infoCapture("Darwin notification observer registered for share extension", category: "shareext")
    }

    // MARK: - Public API

    /// Process all pending shared items from the share extension.
    ///
    /// Call this on app launch and when receiving the `sharedURLReceivedNotification`.
    public func handlePendingSharedItems() async {
        Logger.shareExtension.infoCapture("Checking for pending shared items...", category: "shareext")
        let pendingItems = ShareExtensionService.shared.getPendingItems()

        guard !pendingItems.isEmpty else {
            Logger.shareExtension.debugCapture("No pending items to process", category: "shareext")
            updateShareExtensionLibraries()
            return
        }

        Logger.shareExtension.infoCapture("Processing \(pendingItems.count) pending shared items", category: "shareext")

        for item in pendingItems {
            do {
                switch item.type {
                case .smartSearch:
                    try await createSmartSearchFromSharedItem(item)
                case .paper:
                    try await importPaperFromSharedItem(item)
                case .docsSelection:
                    try await importDocsSelectionFromSharedItem(item)
                }
                ShareExtensionService.shared.removeItem(item)
                Logger.shareExtension.infoCapture("Successfully processed shared item: \(item.type.rawValue)", category: "shareext")
            } catch {
                Logger.shareExtension.errorCapture("Failed to process shared item: \(error.localizedDescription)", category: "shareext")
                // Remove item to avoid infinite retry loops
                ShareExtensionService.shared.removeItem(item)
            }
        }

        updateShareExtensionLibraries()
    }

    /// Update the list of available libraries for the share extension UI.
    public func updateShareExtensionLibraries() {
        let activeLibraryID = libraryManager.activeLibrary?.id
        let libraryInfos = libraryManager.libraries
            .filter { !$0.isInbox }
            .map { library in
                SharedLibraryInfo(
                    id: library.id,
                    name: library.displayName,
                    isDefault: library.id == activeLibraryID
                )
            }

        ShareExtensionService.shared.updateAvailableLibraries(libraryInfos)
        Logger.shareExtension.debugCapture("Updated share extension with \(libraryInfos.count) libraries", category: "shareext")
    }

    // MARK: - Private Handlers

    /// Create a smart search from a shared item
    ///
    /// For search URLs, always creates the smart search in the Exploration library
    /// (not the user's active library) so it appears in the Exploration section.
    private func createSmartSearchFromSharedItem(_ item: ShareExtensionService.SharedItem) async throws {
        // Use the query from the shared item (extracted via JS preprocessing)
        // Fall back to parsing from URL if not available
        let query: String
        let sourceID: String

        if let itemQuery = item.query, !itemQuery.isEmpty {
            query = itemQuery
            sourceID = detectSourceID(from: item.url) ?? "ads"
        } else if let (parsedQuery, parsedSourceID) = parseQueryFromURL(item.url) {
            query = parsedQuery
            sourceID = parsedSourceID
        } else {
            throw ShareExtensionError.invalidURL
        }

        // Always use Exploration library for search URLs from share extension
        // This makes them appear in the Exploration section of the sidebar
        let targetLibrary = libraryManager.getOrCreateExplorationLibrary()

        // Create a truncated name from the query
        let truncatedQuery = String(query.prefix(40)) + (query.count > 40 ? "..." : "")
        let name = item.name ?? "Search: \(truncatedQuery)"

        // Create the smart search
        let smartSearch = SmartSearchRepository.shared.create(
            name: name,
            query: query,
            sourceIDs: [sourceID],
            library: targetLibrary,
            maxResults: 100
        )

        Logger.shareExtension.infoCapture("Created smart search '\(name)' in Exploration library", category: "shareext")

        // Auto-execute the search to populate results
        do {
            let provider = SmartSearchProvider(
                from: smartSearch,
                sourceManager: sourceManager,
                repository: repository
            )
            try await provider.refresh()
            SmartSearchRepository.shared.markExecuted(smartSearch)
            Logger.shareExtension.infoCapture("Auto-executed smart search '\(name)' successfully", category: "shareext")
        } catch {
            // Log but don't fail - the search was created, it can be refreshed later
            Logger.shareExtension.warningCapture("Auto-execute failed for '\(name)': \(error.localizedDescription)", category: "shareext")
        }

        // Notify sidebar to refresh and navigate to the new search
        NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
        NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
    }

    /// Import a paper from a shared item
    private func importPaperFromSharedItem(_ item: ShareExtensionService.SharedItem) async throws {
        // Try to extract paper identifier from URL (bibcode, arXiv ID, etc.)
        guard let (identifier, searchQuery, sourceID) = extractPaperIdentifier(from: item.url) else {
            throw ShareExtensionError.invalidURL
        }

        // Search for the paper using the appropriate source
        let options = SearchOptions(maxResults: 1, sortOrder: .relevance, sourceIDs: [sourceID])
        let results = try await sourceManager.search(query: searchQuery, options: options)

        guard let firstResult = results.first else {
            throw ShareExtensionError.paperNotFound
        }

        // Import to library or Inbox
        if let libraryID = item.libraryID,
           let library = libraryManager.find(id: libraryID) {
            // Import to specific library
            let publication = await repository.createFromSearchResult(firstResult, in: library)
            Logger.shareExtension.infoCapture("Imported paper \(identifier) to library \(library.displayName)", category: "shareext")
            _ = publication
        } else {
            // Import to Inbox
            let publication = await repository.createFromSearchResult(firstResult)
            InboxManager.shared.addToInbox(publication)
            Logger.shareExtension.infoCapture("Imported paper \(identifier) to Inbox", category: "shareext")
        }
    }

    /// Import papers from a docs() selection to Inbox
    private func importDocsSelectionFromSharedItem(_ item: ShareExtensionService.SharedItem) async throws {
        guard let query = item.query, !query.isEmpty else {
            Logger.shareExtension.errorCapture("docs() import failed: no query in shared item", category: "shareext")
            throw ShareExtensionError.invalidURL
        }

        Logger.shareExtension.infoCapture("Starting docs() import with query: \(query)", category: "shareext")

        let sourceID = detectSourceID(from: item.url) ?? "ads"

        // Query the source to get all papers in the selection
        let options = SearchOptions(maxResults: 200, sortOrder: .dateDescending, sourceIDs: [sourceID])

        do {
            Logger.shareExtension.debugCapture("Querying source for docs() selection...", category: "shareext")
            let results = try await sourceManager.search(query: query, options: options)
            Logger.shareExtension.infoCapture("Search returned \(results.count) results", category: "shareext")

            guard !results.isEmpty else {
                Logger.shareExtension.warningCapture("No papers found for docs() selection", category: "shareext")
                return
            }

            // Import all results to Inbox
            var successCount = 0

            for (index, result) in results.enumerated() {
                Logger.shareExtension.debugCapture("Importing \(index + 1)/\(results.count): \(result.title)", category: "shareext")
                let publication = await repository.createFromSearchResult(result)
                Logger.shareExtension.debugCapture("Created publication: \(publication.citeKey)", category: "shareext")
                InboxManager.shared.addToInbox(publication)
                successCount += 1
            }

            Logger.shareExtension.infoCapture("Successfully imported \(successCount) papers to Inbox", category: "shareext")
        } catch {
            Logger.shareExtension.errorCapture("Search failed: \(error.localizedDescription)", category: "shareext")
            throw error
        }
    }

    // MARK: - Source Detection

    /// Detect the source ID from a URL.
    ///
    /// Supports ADS, arXiv, and SciX URLs.
    private func detectSourceID(from url: URL) -> String? {
        if ADSURLParser.isADSURL(url) {
            return "ads"
        }
        if ArXivURLParser.isArXivURL(url) {
            return "arxiv"
        }
        if SciXURLParser.isSciXURL(url) {
            return "scix"
        }
        return nil
    }

    /// Parse a search query from a URL.
    ///
    /// Returns the query and detected source ID, or nil if not parseable.
    private func parseQueryFromURL(_ url: URL) -> (query: String, sourceID: String)? {
        if let parsed = ADSURLParser.parse(url) {
            switch parsed {
            case .search(let query, _):
                return (query, "ads")
            case .docsSelection(let query):
                return (query, "ads")
            case .paper:
                return nil
            }
        }
        if let parsed = ArXivURLParser.parse(url) {
            switch parsed {
            case .search(let query, _):
                return (query, "arxiv")
            case .categoryList(let category, _):
                // Category feeds become cat: queries
                return ("cat:\(category)", "arxiv")
            case .paper, .pdf:
                // Paper URLs are handled by extractArXivIDFromURL
                return nil
            }
        }
        if let parsed = SciXURLParser.parse(url) {
            switch parsed {
            case .search(let query, _):
                return (query, "scix")
            case .docsSelection(let query):
                return (query, "scix")
            case .paper:
                // Paper URLs are handled by extractPaperIdentifier
                return nil
            }
        }
        return nil
    }

    /// Extract a bibcode from a paper URL.
    private func extractBibcodeFromURL(_ url: URL) -> String? {
        if let parsed = ADSURLParser.parse(url), case .paper(let bibcode) = parsed {
            return bibcode
        }
        return nil
    }

    /// Extract an arXiv ID from a paper or PDF URL.
    private func extractArXivIDFromURL(_ url: URL) -> String? {
        guard let parsed = ArXivURLParser.parse(url) else {
            return nil
        }
        switch parsed {
        case .paper(let arxivID), .pdf(let arxivID):
            return arxivID
        case .search, .categoryList:
            return nil
        }
    }

    /// Extract a SciX bibcode from a paper URL.
    private func extractSciXBibcodeFromURL(_ url: URL) -> String? {
        if let parsed = SciXURLParser.parse(url), case .paper(let bibcode) = parsed {
            return bibcode
        }
        return nil
    }

    /// Extract a paper identifier from any supported URL.
    ///
    /// Returns the identifier and its type for searching.
    private func extractPaperIdentifier(from url: URL) -> (identifier: String, queryFormat: String, sourceID: String)? {
        // Check ADS (bibcode)
        if let bibcode = extractBibcodeFromURL(url) {
            return (bibcode, "bibcode:\(bibcode)", "ads")
        }
        // Check arXiv
        if let arxivID = extractArXivIDFromURL(url) {
            return (arxivID, arxivID, "arxiv")
        }
        // Check SciX (bibcode - same format as ADS)
        if let bibcode = extractSciXBibcodeFromURL(url) {
            return (bibcode, "bibcode:\(bibcode)", "scix")
        }
        return nil
    }
}
