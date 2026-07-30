//
//  GlobalSearchViewModel.swift
//  PublicationManagerCore
//
//  ViewModel for global search combining fulltext and semantic search.
//

import Foundation
import ImpressRustCore
import OSLog

private let logger = Logger(subsystem: "com.imbib", category: "GlobalSearch")

// MARK: - Global Search ViewModel

/// ViewModel that orchestrates combined fulltext and semantic search.
///
/// This powers the local find palette (Cmd+F) feature, providing:
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

            // Phased streaming: FTS is the fastest path (Tantivy, typically
            // < 100 ms). Publish FTS hits to the UI immediately, then merge
            // semantic + chunks as they catch up. Pre-regression behaviour
            // awaited all three in parallel, so a slow first-launch ANN
            // rebuild (5–25 s) blocked even fast FTS hits from showing.
            // Now the user sees something within a frame or two and the
            // slower paths refine the list.
            async let ftsTask = performFulltextSearch()
            async let semanticTask = performSemanticSearch()
            async let chunkTask = performChunkSearch()

            // Manuscripts search (GUI-meld ⌘F unification): a cheap
            // synchronous store scan over manuscript title/body, prepended so
            // authored drafts surface alongside publications.
            let manuscriptResults = performManuscriptSearch()

            // Phase 1 — FTS first.
            let ftsResults = await ftsTask
            guard !Task.isCancelled else { return }
            results = manuscriptResults + mergeResults(fts: ftsResults, semantic: [], chunks: [])

            // Phase 2 — semantic merges in.
            let semanticResults = await semanticTask
            guard !Task.isCancelled else { return }
            results = manuscriptResults + mergeResults(fts: ftsResults, semantic: semanticResults, chunks: [])

            // Phase 3 — chunks last.
            let chunkResults = await chunkTask
            guard !Task.isCancelled else { return }
            let merged = mergeResults(fts: ftsResults, semantic: semanticResults, chunks: chunkResults)
            results = manuscriptResults + merged
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
    /// The caller chooses the initial scope. Users can still broaden or narrow
    /// the scope explicitly from the picker after the palette opens.
    public func setContext(_ context: SearchContext) {
        selectedScope = context
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
    /// Search manuscript items by title/body (GUI-meld ⌘F unification). Synchronous
    /// store scan — cheap relative to FTS/embeddings, so it runs inline and its
    /// hits are prepended so authored drafts surface with publications.
    private func performManuscriptSearch() -> [GlobalSearchResult] {
        #if os(macOS)
        let rows = RustStoreAdapter.shared.searchManuscripts(query: query, limit: 20)
        return rows.compactMap { row in
            guard let manuscript = ManuscriptRowData(from: row) else { return nil }
            return GlobalSearchResult(
                id: manuscript.id,
                citeKey: "",
                title: manuscript.title,
                authors: manuscript.authorString,
                year: nil,
                snippet: manuscript.subtitleText,
                matchType: .manuscript,
                // Rank just above a mid FTS hit so exact-title drafts lead but
                // strong publication matches can still interleave.
                score: 0.9,
                libraryNames: [],
                dateAdded: manuscript.dateAdded,
                dateModified: manuscript.dateModified,
                citationCount: 0,
                isStarred: manuscript.isStarredState
            )
        }
        #else
        return []
        #endif
    }

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
        // Never block interactive search on the first-use index build. If the
        // index isn't ready, trigger a background build and skip semantic
        // results for THIS query — FTS hits are shown instantly and semantic
        // results join automatically on the next search once the index is
        // built. (Awaiting ensureIndexReady() here was the spinning-ball
        // regression: the 5–25s build froze the UI even though FTS had hits.)
        let hasIndex = await EmbeddingService.shared.hasIndex
        guard hasIndex else {
            await EmbeddingService.shared.startBackgroundIndexBuildIfNeeded()
            logger.debug("Semantic search skipped — embedding index building in background")
            return []
        }
        let results = await EmbeddingService.shared.searchByText(query, topK: 100)
        logInfo("Semantic '\(query)' → \(results.count) hits", category: "search")
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

        // Collect all unique publication IDs from all three sources.
        // Sorted, not a bare Set: the iteration order used to reach the output
        // whenever two results scored equally, so the same corpus could produce
        // two different orderings. Rust pins the tie-break on id, and feeding it
        // a deterministic candidate list keeps the whole path reproducible.
        var idSet = Set(ftsMap.keys)
        idSet.formUnion(semanticMap.keys)
        idSet.formUnion(chunkMap.keys)
        let allIDs = idSet.sorted { $0.uuidString < $1.uuidString }

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

        // Resolve metadata and shape the candidate set for the Rust ranker.
        //
        // The hybrid relevance formula (FTS base + author/title/cite-key field
        // boosts + scaled chunk similarity) is `impress_core::search_ops::
        // rank_hybrid_candidates`, reached through `rankHybridSearchResults`.
        // It used to be twenty lines of literal arithmetic right here, which
        // meant the definition of "relevant" was a view-model detail and could
        // not be tested without a populated store.
        var metadataByID: [UUID: PublicationMetadata] = [:]
        var candidates: [SharedHybridCandidate] = []

        for id in allIDs {
            // Fetch metadata — library names come from pre-built map
            let metadata = fetchFullPublicationMetadata(id: id, libraryNames: pubToLibraryNames[id]?.sorted() ?? [])

            // Skip results where publication no longer exists or has no meaningful metadata
            // This can happen if the search index is stale or publication was deleted
            if metadata.title.isEmpty && metadata.citeKey.isEmpty && metadata.authors.isEmpty {
                logger.debug("Skipping search result for ID \(id) - no metadata found (publication may have been deleted)")
                continue
            }

            metadataByID[id] = metadata
            candidates.append(
                SharedHybridCandidate(
                    // Lowercased because the Rust tie-break compares ids as
                    // strings; a mixed-case list would order inconsistently.
                    id: id.uuidString.lowercased(),
                    citeKey: metadata.citeKey,
                    title: metadata.title,
                    authors: metadata.authors,
                    ftsScore: ftsMap[id]?.score,
                    semanticSimilarity: semanticMap[id]?.similarity,
                    chunkSimilarity: chunkMap[id]?.similarity
                )
            )
        }

        // Build results in the order Rust ranked them.
        var merged: [GlobalSearchResult] = []
        for ranked in rankHybridSearchResults(query: query, candidates: candidates) {
            guard let id = UUID(uuidString: ranked.id),
                  let metadata = metadataByID[id] else { continue }
            let ftsResult = ftsMap[id]
            let chunkResult = chunkMap[id]

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

            merged.append(
                GlobalSearchResult(
                    id: id,
                    citeKey: metadata.citeKey,
                    title: metadata.title,
                    authors: metadata.authors,
                    year: metadata.year,
                    snippet: snippet,
                    matchType: .fromRankerName(ranked.matchType),
                    score: ranked.score,
                    libraryNames: metadata.libraryNames,
                    dateAdded: metadata.dateAdded,
                    dateModified: metadata.dateModified,
                    citationCount: metadata.citationCount,
                    isStarred: metadata.isStarred,
                    pageNumber: chunkResult?.pageNumber
                )
            )
        }

        // Apply context filtering — order-preserving, so the ranking survives.
        let filtered = applyContextFilter(to: merged)

        // Apply sorting based on current sort order
        let sortedResults = applySorting(to: filtered)

        return sortedResults
    }

    /// Apply sorting to results based on current sort order and direction.
    ///
    /// The `.relevance` branch reproduces the order Rust already produced
    /// (score descending, ties on id) rather than being a no-op, because this
    /// also runs from `resortResults()` over the *combined* list — manuscripts
    /// are prepended after ranking and have to be interleaved by score there.
    ///
    /// Every branch ends in the same id tie-break. `Array.sort` is not stable,
    /// so without it equal-keyed rows (same date, same year, same citation
    /// count — routine) were free to reshuffle between two sorts of the same
    /// data, which is visible as rows jumping when the user toggles direction
    /// twice.
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

            // Equal on the chosen key: fall back to the id so the order is
            // total and therefore reproducible.
            if comparison == .orderedSame {
                return a.id.uuidString < b.id.uuidString
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

// MARK: - Ranker Match Types

extension GlobalSearchMatchType {

    /// The match kind the Rust ranker reported.
    ///
    /// `impress_core::search_ops::match_type` deliberately spells its constants
    /// as this enum's raw values, so the mapping is identity. The `assertionFailure`
    /// is the point of the function: a new kind added on one side must not
    /// silently arrive as `.semantic` and mislabel every row in the palette.
    ///
    /// `.manuscript` is absent by design — manuscript hits come from a separate
    /// store scan, not from the hybrid ranker.
    static func fromRankerName(_ name: String) -> GlobalSearchMatchType {
        guard let kind = GlobalSearchMatchType(rawValue: name), kind != .manuscript else {
            assertionFailure("unknown match type from the Rust ranker: \(name)")
            return .semantic
        }
        return kind
    }
}
