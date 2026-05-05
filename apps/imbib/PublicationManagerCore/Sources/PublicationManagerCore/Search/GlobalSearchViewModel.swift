//
//  GlobalSearchViewModel.swift
//  PublicationManagerCore
//
//  ViewModel for global search combining fulltext and semantic search.
//

import Foundation
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

    /// The current sort order for results
    public var sortOrder: GlobalSearchSortOrder = .relevance

    /// Whether to sort ascending (true) or descending (false)
    public var sortAscending: Bool = false

    /// The effective context for search - now just returns the selected scope
    public var effectiveContext: SearchContext {
        selectedScope
    }

    // MARK: - Private Properties

    private var searchTask: Task<Void, Never>?
    private let debounceDelay: Duration = .milliseconds(200)

    /// Pre-built library membership: library UUID → set of publication UUIDs.
    /// Includes papers linked via HasParent edges AND papers in collections belonging to the library.
    /// Built once per search in `mergeResults`, consumed by `applyContextFilter`.
    private var libraryMembership: [UUID: Set<UUID>] = [:]

    /// Pre-built collection membership: collection UUID → set of publication UUIDs.
    private var collectionMembership: [UUID: Set<UUID>] = [:]

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

            // Run fulltext, semantic, and chunk searches in parallel
            async let ftsTask = performFulltextSearch()
            async let semanticTask = performSemanticSearch()
            async let chunkTask = performChunkSearch()

            let (ftsResults, semanticResults, chunkResults) = await (ftsTask, semanticTask, chunkTask)

            guard !Task.isCancelled else { return }

            // Merge and deduplicate results
            let merged = mergeResults(fts: ftsResults, semantic: semanticResults, chunks: chunkResults)

            results = merged
            isSearching = false

            logger.debug("Global search for '\(self.query)' returned \(merged.count) results (FTS: \(ftsResults.count), Semantic: \(semanticResults.count), Chunks: \(chunkResults.count))")
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
            logInfo("FTS unavailable for query '\(query)'", category: "search")
            return []
        }
        let results = await FullTextSearchService.shared.search(query: query, limit: 100) ?? []
        logInfo("FTS '\(query)' → \(results.count) hits", category: "search")
        return results
    }

    /// Perform semantic search using embeddings.
    private func performSemanticSearch() async -> [SimilarityResult] {
        // Lazy-build the embedding index on first Cmd+K use (deferred from startup)
        await EmbeddingService.shared.ensureIndexReady()
        let hasIndex = await EmbeddingService.shared.hasIndex
        guard hasIndex else {
            logger.debug("Semantic search unavailable (embedding index not built)")
            return []
        }
        let results = await EmbeddingService.shared.searchByText(query, topK: 100)
        logger.debug("Semantic search returned \(results.count) results")
        return results
    }

    // MARK: - Chunk Search

    /// Best chunk match per publication from chunk-level search.
    private struct ChunkPassageResult {
        let publicationId: UUID
        let chunkText: String
        let pageNumber: Int?
        let similarity: Float
    }

    /// Perform chunk-level content search using the in-memory HNSW index.
    private func performChunkSearch() async -> [ChunkPassageResult] {
        await ChunkSearchService.shared.ensureLoaded()
        guard await ChunkSearchService.shared.hasChunks else { return [] }

        let queryEmbedding = await EmbeddingService.shared.embedText(query)
        guard !queryEmbedding.isEmpty else { return [] }

        let hits = await ChunkSearchService.shared.search(queryEmbedding: queryEmbedding, topK: 20)

        // Group by publication — keep best (highest similarity) chunk per publication
        var bestByPub: [UUID: (ChunkSimilarityResult, StoredChunk)] = [:]
        for hit in hits where hit.similarity > 0.35 {
            // Look up chunk text + publicationId (startup-loaded chunks have empty pubId in HNSW)
            guard let chunk = await ChunkSearchService.shared.getChunk(chunkId: hit.chunkId),
                  let pubId = UUID(uuidString: chunk.publicationId) else { continue }
            if let existing = bestByPub[pubId], existing.0.similarity >= hit.similarity { continue }
            bestByPub[pubId] = (hit, chunk)
        }

        let chunkResults = bestByPub.map { (pubId, pair) in
            ChunkPassageResult(
                publicationId: pubId,
                chunkText: pair.1.text,
                pageNumber: pair.1.pageNumber.map { Int($0) },
                similarity: pair.0.similarity
            )
        }

        logger.debug("Chunk search returned \(chunkResults.count) publication-level results from \(hits.count) chunk hits")
        return chunkResults
    }

    /// Merge fulltext, semantic, and chunk results, deduplicating by publication ID.
    ///
    /// - Parameters:
    ///   - fts: Fulltext search results
    ///   - semantic: Semantic similarity results
    ///   - chunks: Chunk-level passage results
    /// - Returns: Merged and sorted global search results
    private func mergeResults(
        fts: [FullTextSearchResult],
        semantic: [SimilarityResult],
        chunks: [ChunkPassageResult]
    ) -> [GlobalSearchResult] {
        let store = RustStoreAdapter.shared

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

        var chunkMap: [UUID: ChunkPassageResult] = [:]
        for result in chunks {
            chunkMap[result.publicationId] = result
        }

        // Collect all unique publication IDs from all three sources
        var allIDs = Set(ftsMap.keys)
        allIDs.formUnion(semanticMap.keys)
        allIDs.formUnion(chunkMap.keys)

        // Pre-build library membership maps ONCE for all results.
        // Papers can belong to a library via HasParent edges (direct import)
        // OR via Contains edges from collections within the library.
        let allLibraries = store.listLibraries()
        var pubToLibraryNames: [UUID: [String]] = [:]
        var libMembership: [UUID: Set<UUID>] = [:]
        var collMembership: [UUID: Set<UUID>] = [:]

        for library in allLibraries {
            // Direct library members (HasParent edges)
            let directMembers = store.queryPublications(parentId: library.id, sort: "dateAdded", ascending: false)
            var memberIDs = Set(directMembers.map(\.id))
            for member in directMembers {
                pubToLibraryNames[member.id, default: []].append(library.name)
            }

            // Collection members (Contains edges) — papers in collections belonging to this library
            let collections = store.listCollections(libraryId: library.id)
            for collection in collections {
                let collMembers = store.listCollectionMembers(collectionId: collection.id)
                let collMemberIDs = Set(collMembers.map(\.id))
                collMembership[collection.id] = collMemberIDs
                for member in collMembers where !memberIDs.contains(member.id) {
                    memberIDs.insert(member.id)
                    pubToLibraryNames[member.id, default: []].append(library.name)
                }
            }

            libMembership[library.id] = memberIDs
        }
        libraryMembership = libMembership
        collectionMembership = collMembership

        // Build merged results
        var merged: [GlobalSearchResult] = []

        for id in allIDs {
            let ftsResult = ftsMap[id]
            let semanticResult = semanticMap[id]
            let chunkResult = chunkMap[id]

            // Fetch metadata — library names come from pre-built map
            let metadata = fetchFullPublicationMetadata(id: id, libraryNames: pubToLibraryNames[id]?.sorted() ?? [])

            // Skip results where publication no longer exists or has no meaningful metadata
            // This can happen if the search index is stale or publication was deleted
            if metadata.title.isEmpty && metadata.citeKey.isEmpty && metadata.authors.isEmpty {
                logger.debug("Skipping search result for ID \(id) - no metadata found (publication may have been deleted)")
                continue
            }

            // Determine match type
            // Chunk results use .full unless combined with FTS/semantic
            let matchType: GlobalSearchMatchType
            if ftsResult != nil && semanticResult != nil {
                matchType = .both
            } else if ftsResult != nil {
                matchType = .fulltext
            } else if chunkResult != nil && semanticResult == nil && ftsResult == nil {
                matchType = .full
            } else {
                matchType = .semantic
            }

            // Calculate combined score with field-priority boosting.
            // FTS (direct text) results should always rank above semantic-only results.
            // Within FTS, prioritize by field: Author > Title > Abstract > full text.
            // Chunk results score 0–60, above semantic-only but below FTS.
            var score: Float = 0
            if let fts = ftsResult {
                // Base FTS score ensures FTS results always outrank semantic-only
                score += 100.0 + fts.score

                // Field-priority boost: check which fields contain the query
                let q = query.lowercased()
                if metadata.authors.lowercased().contains(q) {
                    score += 40  // Author match — highest priority
                }
                if metadata.title.lowercased().contains(q) {
                    score += 30  // Title match
                }
                if let citeKey = metadata.citeKey.lowercased() as String?,
                   citeKey.contains(q) {
                    score += 25  // Cite key match
                }
            }
            if let sem = semanticResult {
                // Semantic results get similarity (0–1 range), always below FTS base of 100
                score += sem.similarity
            }
            if let chunk = chunkResult {
                // Chunk results: 0–60 range, above semantic-only, below FTS
                score += chunk.similarity * 60
            }

            // Snippet: prefer FTS snippet (highlighted), then chunk passage text
            let snippet: String?
            if let ftsSnippet = ftsResult?.snippet, !ftsSnippet.isEmpty {
                snippet = ftsSnippet
            } else if let chunk = chunkResult {
                let text = chunk.chunkText
                let truncated = text.count > 150 ? String(text.prefix(150)) + "…" : text
                if let page = chunk.pageNumber {
                    snippet = "\(truncated) (p. \(page + 1))"
                } else {
                    snippet = truncated
                }
            } else {
                snippet = nil
            }

            let pageNumber = chunkResult?.pageNumber

            let result = GlobalSearchResult(
                id: id,
                citeKey: metadata.citeKey,
                title: metadata.title,
                authors: metadata.authors,
                year: metadata.year,
                snippet: snippet,
                matchType: matchType,
                score: score,
                libraryNames: metadata.libraryNames,
                dateAdded: metadata.dateAdded,
                dateModified: metadata.dateModified,
                citationCount: metadata.citationCount,
                isStarred: metadata.isStarred,
                pageNumber: pageNumber
            )

            merged.append(result)
        }

        // Apply context filtering
        let filtered = applyContextFilter(to: merged)

        // Apply sorting based on current sort order
        let sortedResults = applySorting(to: filtered)

        return sortedResults
    }

    /// Apply sorting to results based on current sort order and direction.
    private func applySorting(to results: [GlobalSearchResult]) -> [GlobalSearchResult] {
        var sorted = results

        sorted.sort { a, b in
            let comparison: ComparisonResult

            switch sortOrder {
            case .relevance:
                // Higher score = more relevant
                comparison = a.score < b.score ? .orderedAscending : (a.score > b.score ? .orderedDescending : .orderedSame)

            case .dateAdded:
                let dateA = a.dateAdded ?? .distantPast
                let dateB = b.dateAdded ?? .distantPast
                comparison = dateA.compare(dateB)

            case .dateModified:
                let dateA = a.dateModified ?? .distantPast
                let dateB = b.dateModified ?? .distantPast
                comparison = dateA.compare(dateB)

            case .title:
                comparison = a.title.localizedCaseInsensitiveCompare(b.title)

            case .year:
                let yearA = Int(a.year ?? "0") ?? 0
                let yearB = Int(b.year ?? "0") ?? 0
                comparison = yearA < yearB ? .orderedAscending : (yearA > yearB ? .orderedDescending : .orderedSame)

            case .citeKey:
                comparison = a.citeKey.localizedCaseInsensitiveCompare(b.citeKey)

            case .citationCount:
                comparison = a.citationCount < b.citationCount ? .orderedAscending : (a.citationCount > b.citationCount ? .orderedDescending : .orderedSame)

            case .starred:
                // Starred first (true > false)
                if a.isStarred == b.isStarred {
                    comparison = .orderedSame
                } else {
                    comparison = a.isStarred ? .orderedDescending : .orderedAscending
                }
            }

            // Apply sort direction
            if sortAscending {
                return comparison == .orderedAscending
            } else {
                return comparison == .orderedDescending
            }
        }

        return sorted
    }

    /// Re-sort results when sort order or direction changes without re-fetching.
    public func resortResults() {
        results = applySorting(to: results)
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

    /// Check if a publication is in the specified library (uses precomputed membership map).
    private func isInLibrary(_ publicationID: UUID, libraryID: UUID) -> Bool {
        libraryMembership[libraryID]?.contains(publicationID) ?? false
    }

    /// Check if a publication is in the specified collection (uses precomputed membership map).
    private func isInCollection(_ publicationID: UUID, collectionID: UUID) -> Bool {
        collectionMembership[collectionID]?.contains(publicationID) ?? false
    }

    /// Check if a publication matches the specified smart search.
    ///
    /// Smart search results are transient (produced by executing the search query)
    /// rather than stored in a persistent collection. We return `true` here so
    /// global search results are not discarded when scoped to a smart search.
    private func isInSmartSearch(_ publicationID: UUID, smartSearchID: UUID) -> Bool {
        // Smart searches in the Rust store don't have persistent result collections.
        // When scoped to a smart search, show all matching results.
        return true
    }

    /// Search for query in a publication's notes
    private func searchNotesForPublication(_ publicationID: UUID) -> GlobalSearchResult? {
        let store = RustStoreAdapter.shared
        guard let detail = store.getPublicationDetail(id: publicationID) else {
            return nil
        }

        // Notes are stored in the fields dictionary as "note" or "annote"
        let notes = detail.fields["annote"] ?? detail.fields["note"]

        // Check if notes contain the query
        if let notes = notes,
           !notes.isEmpty,
           notes.localizedCaseInsensitiveContains(query) {

            let title = detail.title
            let citeKey = detail.citeKey
            let authors = detail.authors.map(\.displayName).joined(separator: ", ")
            let year: String? = detail.year.map { String($0) }

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

    /// Metadata result from store fetch
    private struct PublicationMetadata {
        let title: String
        let citeKey: String
        let authors: String
        let year: String?
        let libraryNames: [String]
        let dateAdded: Date?
        let dateModified: Date?
        let citationCount: Int
        let isStarred: Bool
    }

    /// Fetch publication metadata from the store.
    private func fetchPublicationMetadata(id: UUID) -> (title: String, citeKey: String, authors: String, year: String?, libraryNames: [String]) {
        let metadata = fetchFullPublicationMetadata(id: id)
        return (metadata.title, metadata.citeKey, metadata.authors, metadata.year, metadata.libraryNames)
    }

    /// Fetch full publication metadata including sorting fields from the Rust store.
    private func fetchFullPublicationMetadata(id: UUID, libraryNames: [String] = []) -> PublicationMetadata {
        let store = RustStoreAdapter.shared

        guard let pub = store.getPublication(id: id) else {
            return PublicationMetadata(
                title: "", citeKey: "", authors: "", year: nil,
                libraryNames: [], dateAdded: nil, dateModified: nil,
                citationCount: 0, isStarred: false
            )
        }

        return PublicationMetadata(
            title: pub.title,
            citeKey: pub.citeKey,
            authors: pub.authorString,
            year: pub.year.map { String($0) },
            libraryNames: libraryNames,
            dateAdded: pub.dateAdded,
            dateModified: pub.dateModified,
            citationCount: pub.citationCount,
            isStarred: pub.isStarred
        )
    }
}

