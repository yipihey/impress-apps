//
//  GlobalSearchViewModel.swift
//  PublicationManagerCore
//
//  ViewModel for global search combining fulltext and semantic search.
//

import Foundation
import CoreData
import OSLog

private let logger = Logger(subsystem: "com.imbib", category: "GlobalSearch")

// MARK: - Global Search ViewModel

/// ViewModel that orchestrates combined fulltext and semantic search.
///
/// This powers the command palette (Cmd+K) feature, providing:
/// - Parallel fulltext (Tantivy) and semantic (embedding) search
/// - Result merging with deduplication
/// - Match type detection (text, semantic, or both)
/// - Debounced search as user types
/// - Context-aware filtering by library, collection, or publication
@MainActor
@Observable
public final class GlobalSearchViewModel {

    // MARK: - Published State

    /// The current search query
    public var query: String = ""

    /// Combined search results from fulltext and semantic search
    public private(set) var results: [GlobalSearchResult] = []

    /// Whether a search is currently in progress
    public private(set) var isSearching: Bool = false

    /// The currently selected result index for keyboard navigation
    public var selectedIndex: Int = 0

    /// The selected search scope (always starts as global, user can narrow it)
    public var selectedScope: SearchContext = .global

    /// The effective context for search - now just returns the selected scope
    public var effectiveContext: SearchContext {
        selectedScope
    }

    // MARK: - Private Properties

    private var searchTask: Task<Void, Never>?
    private let debounceDelay: Duration = .milliseconds(200)

    // MARK: - Initialization

    public init() {}

    /// Initialize with a specific search scope.
    ///
    /// Note: The default scope is always global. This initializer allows setting
    /// a different initial scope if needed.
    public init(context: SearchContext) {
        self.selectedScope = context
    }

    // MARK: - Public API

    /// Execute a search with the current query.
    ///
    /// Runs fulltext and semantic searches in parallel, then merges results.
    /// The search is debounced to avoid excessive API calls while typing.
    public func search() {
        // Cancel any pending search
        searchTask?.cancel()

        // Clear results if query is empty
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        selectedIndex = 0

        searchTask = Task {
            // Debounce
            try? await Task.sleep(for: debounceDelay)
            guard !Task.isCancelled else { return }

            // Run both searches in parallel
            async let ftsTask = performFulltextSearch()
            async let semanticTask = performSemanticSearch()

            let (ftsResults, semanticResults) = await (ftsTask, semanticTask)

            guard !Task.isCancelled else { return }

            // Merge and deduplicate results
            let merged = mergeResults(fts: ftsResults, semantic: semanticResults)

            results = merged
            isSearching = false

            logger.debug("Global search for '\(self.query)' returned \(merged.count) results (FTS: \(ftsResults.count), Semantic: \(semanticResults.count))")
        }
    }

    /// Clear the search query and results.
    public func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        isSearching = false
        selectedIndex = 0
        // Note: Don't reset selectedScope - keep user's scope preference
    }

    /// Select a specific search scope.
    ///
    /// This replaces the old toggle/override pattern. Users can explicitly choose
    /// their scope from the scope picker dropdown.
    public func selectScope(_ scope: SearchContext) {
        selectedScope = scope
        // Re-run search with new scope if query exists
        if !query.isEmpty {
            search()
        }
    }

    /// Set up the view model for a new search session.
    ///
    /// Always defaults to global scope. The environment context is ignored - users
    /// explicitly choose their scope via the scope picker.
    public func setContext(_ context: SearchContext) {
        // Always default to global - the scope picker lets users narrow if desired
        // We keep this method for compatibility but ignore the context parameter
        selectedScope = .global
    }

    /// Move selection up in the results list.
    public func selectPrevious() {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
    }

    /// Move selection down in the results list.
    public func selectNext() {
        guard !results.isEmpty else { return }
        selectedIndex = min(results.count - 1, selectedIndex + 1)
    }

    /// Get the currently selected result.
    public var selectedResult: GlobalSearchResult? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    // MARK: - Private Methods

    /// Perform fulltext search using Tantivy.
    private func performFulltextSearch() async -> [FullTextSearchResult] {
        let isAvailable = await FullTextSearchService.shared.isAvailable
        guard isAvailable else {
            logger.debug("Fulltext search unavailable (service not initialized or index not ready)")
            return []
        }
        let results = await FullTextSearchService.shared.search(query: query, limit: 100) ?? []
        logger.debug("Fulltext search returned \(results.count) results")
        return results
    }

    /// Perform semantic search using embeddings.
    private func performSemanticSearch() async -> [SimilarityResult] {
        let hasIndex = await EmbeddingService.shared.hasIndex
        guard hasIndex else {
            logger.debug("Semantic search unavailable (embedding index not built)")
            return []
        }
        let results = await EmbeddingService.shared.searchByText(query, topK: 100)
        logger.debug("Semantic search returned \(results.count) results")
        return results
    }

    /// Merge fulltext and semantic results, deduplicating by publication ID.
    ///
    /// - Parameters:
    ///   - fts: Fulltext search results
    ///   - semantic: Semantic similarity results
    /// - Returns: Merged and sorted global search results
    private func mergeResults(
        fts: [FullTextSearchResult],
        semantic: [SimilarityResult]
    ) -> [GlobalSearchResult] {
        // Build lookup maps
        var ftsMap: [UUID: FullTextSearchResult] = [:]
        for result in fts {
            ftsMap[result.publicationId] = result
        }

        var semanticMap: [UUID: SimilarityResult] = [:]
        for result in semantic {
            if let uuid = UUID(uuidString: result.publicationId) {
                semanticMap[uuid] = result
            }
        }

        // Collect all unique publication IDs
        var allIDs = Set(ftsMap.keys)
        allIDs.formUnion(semanticMap.keys)

        // Build merged results
        var merged: [GlobalSearchResult] = []

        for id in allIDs {
            let ftsResult = ftsMap[id]
            let semanticResult = semanticMap[id]

            // Always fetch complete metadata from Core Data to ensure we have title, authors, etc.
            let (title, citeKey, authors, year, libraryNames) = fetchPublicationMetadata(id: id)

            // Skip results where publication no longer exists or has no meaningful metadata
            // This can happen if the search index is stale or publication was deleted
            if title.isEmpty && citeKey.isEmpty && authors.isEmpty {
                logger.debug("Skipping search result for ID \(id) - no metadata found (publication may have been deleted)")
                continue
            }

            // Determine match type
            let matchType: GlobalSearchMatchType
            if ftsResult != nil && semanticResult != nil {
                matchType = .both
            } else if ftsResult != nil {
                matchType = .fulltext
            } else {
                matchType = .semantic
            }

            // Calculate combined score
            // Weight fulltext higher since it's more precise
            var score: Float = 0
            if let fts = ftsResult {
                score += fts.score * 1.5  // FTS boost
            }
            if let sem = semanticResult {
                score += sem.similarity
            }

            // Get snippet from FTS if available
            let snippet = ftsResult?.snippet

            let result = GlobalSearchResult(
                id: id,
                citeKey: citeKey,
                title: title,
                authors: authors,
                year: year,
                snippet: snippet,
                matchType: matchType,
                score: score,
                libraryNames: libraryNames
            )

            merged.append(result)
        }

        // Apply context filtering
        let filtered = applyContextFilter(to: merged)

        // Sort by score descending
        var sortedResults = filtered
        sortedResults.sort { $0.score > $1.score }

        return sortedResults
    }

    /// Apply context-based filtering to search results
    private func applyContextFilter(to results: [GlobalSearchResult]) -> [GlobalSearchResult] {
        let context = effectiveContext

        switch context {
        case .global:
            // No filtering for global search
            return results

        case .library(let libraryID, _):
            // Filter to publications in this library
            return results.filter { isInLibrary($0.id, libraryID: libraryID) }

        case .collection(let collectionID, _):
            // Filter to publications in this collection
            return results.filter { isInCollection($0.id, collectionID: collectionID) }

        case .smartSearch(let smartSearchID, _):
            // Filter to publications matching this smart search
            return results.filter { isInSmartSearch($0.id, smartSearchID: smartSearchID) }

        case .publication(let publicationID, _):
            // Filter to only this publication (plus check notes)
            var filtered = results.filter { $0.id == publicationID }

            // Also check if the query matches the publication's notes
            if filtered.isEmpty {
                if let notesMatch = searchNotesForPublication(publicationID) {
                    filtered.append(notesMatch)
                }
            }

            return filtered

        case .pdf:
            // PDF search is handled separately via PDFSearchService
            // Return empty - the UI should redirect to in-PDF search
            return []
        }
    }

    // MARK: - Context Filter Helpers

    /// Check if a publication is in the specified library
    private func isInLibrary(_ publicationID: UUID, libraryID: UUID) -> Bool {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", publicationID as CVarArg)
        request.fetchLimit = 1

        guard let publication = try? context.fetch(request).first else {
            return false
        }

        // Check regular libraries
        if let libraries = publication.libraries {
            for library in libraries {
                if library.id == libraryID {
                    return true
                }
            }
        }

        // Check SciX libraries
        if let scixLibraries = publication.scixLibraries {
            for scixLibrary in scixLibraries {
                if scixLibrary.id == libraryID {
                    return true
                }
            }
        }

        return false
    }

    /// Check if a publication is in the specified collection
    private func isInCollection(_ publicationID: UUID, collectionID: UUID) -> Bool {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", publicationID as CVarArg)
        request.fetchLimit = 1

        guard let publication = try? context.fetch(request).first,
              let collections = publication.collections else {
            return false
        }

        return collections.contains { $0.id == collectionID }
    }

    /// Check if a publication matches the specified smart search
    private func isInSmartSearch(_ publicationID: UUID, smartSearchID: UUID) -> Bool {
        let context = PersistenceController.shared.viewContext

        // Fetch the smart search
        let ssRequest = NSFetchRequest<CDSmartSearch>(entityName: "SmartSearch")
        ssRequest.predicate = NSPredicate(format: "id == %@", smartSearchID as CVarArg)
        ssRequest.fetchLimit = 1

        guard let smartSearch = try? context.fetch(ssRequest).first,
              let publications = smartSearch.resultCollection?.publications else {
            return false
        }

        return publications.contains { $0.id == publicationID }
    }

    /// Search for query in a publication's notes
    private func searchNotesForPublication(_ publicationID: UUID) -> GlobalSearchResult? {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", publicationID as CVarArg)
        request.fetchLimit = 1

        guard let publication = try? context.fetch(request).first else {
            return nil
        }

        // Notes are stored in the BibTeX fields dictionary as "note" or "annote"
        let fields = publication.fields
        let notes = fields["annote"] ?? fields["note"]

        // Check if notes contain the query
        if let notes = notes,
           !notes.isEmpty,
           notes.localizedCaseInsensitiveContains(query) {

            let title = publication.title ?? ""
            let citeKey = publication.citeKey
            let authors = publication.authorString
            let year: String? = publication.year > 0 ? String(publication.year) : nil

            // Extract snippet from notes
            let snippet = extractSnippet(from: notes, query: query)

            return GlobalSearchResult(
                id: publicationID,
                citeKey: citeKey,
                title: title,
                authors: authors,
                year: year,
                snippet: snippet,
                matchType: .fulltext,
                score: 1.0,  // Default score for notes match
                libraryNames: ["in notes"]
            )
        }

        return nil
    }

    /// Extract a snippet around the query match in text
    private func extractSnippet(from text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else {
            return ""
        }

        // Get ~50 characters before and after
        let snippetStart = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let snippetEnd = text.index(range.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex

        var snippet = String(text[snippetStart..<snippetEnd])

        // Clean up whitespace
        snippet = snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)

        // Add ellipsis if truncated
        if snippetStart != text.startIndex {
            snippet = "..." + snippet
        }
        if snippetEnd != text.endIndex {
            snippet = snippet + "..."
        }

        return snippet
    }

    /// Fetch publication metadata from Core Data.
    private func fetchPublicationMetadata(id: UUID) -> (title: String, citeKey: String, authors: String, year: String?, libraryNames: [String]) {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1

        guard let publication = try? context.fetch(request).first else {
            return ("", "", "", nil, [])
        }

        let title = publication.title ?? ""
        let citeKey = publication.citeKey
        let authors = publication.authorString
        let year: String? = publication.year > 0 ? String(publication.year) : nil

        // Get library names (excluding system libraries)
        var libraryNames: [String] = publication.libraries?
            .filter { !$0.isSystemLibrary && $0.name.lowercased() != "dismissed" }
            .map { $0.displayName }
            .sorted() ?? []

        // Also include SciX library names
        let scixNames: [String] = publication.scixLibraries?
            .map { $0.name }
            .sorted() ?? []
        libraryNames.append(contentsOf: scixNames)

        return (title, citeKey, authors, year, libraryNames)
    }
}
