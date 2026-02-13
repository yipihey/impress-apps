//
//  EmbeddingService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-21.
//

import Foundation
import OSLog
import NaturalLanguage

// Logger extension for recommendation subsystem
extension Logger {
    static let embeddingService = Logger(subsystem: "com.imbib", category: "EmbeddingService")
}

// MARK: - Embedding Service (ADR-020, ADR-022)

/// Actor that manages publication embeddings and similarity search.
///
/// Provides semantic similarity scoring for the recommendation engine using
/// the Rust ANN (Approximate Nearest Neighbor) index.
///
/// ## Architecture
/// - Embeddings are computed from publication metadata (title, abstract, authors)
/// - The ANN index stores embeddings for library publications
/// - Similarity search returns publications most similar to a given paper
///
/// ## Sync Strategy (ADR-022)
/// The index is generated locally on each device rather than synced via iCloud:
/// - HNSW graph cannot be serialized (library limitation)
/// - Hash-based embeddings are cheap (~2-5ms per publication)
/// - Full index rebuilds in ~2-5 seconds for typical libraries
/// - Deterministic: same metadata produces identical results across devices
///
/// ## Usage
/// ```swift
/// // Build index from library
/// await EmbeddingService.shared.buildIndex(from: libraryID)
///
/// // Find similar papers
/// let similar = await EmbeddingService.shared.findSimilar(to: publicationID)
///
/// // Get similarity score for a publication
/// let score = await EmbeddingService.shared.similarityScore(for: publicationID)
/// ```
public actor EmbeddingService {

    // MARK: - Singleton

    public static let shared = EmbeddingService()

    // MARK: - Properties

    private var annIndex: RustAnnIndex?
    private var isIndexBuilt = false
    private var indexedPublicationIDs: Set<String> = []
    private let embeddingDimension = 384  // Common dimension for sentence embeddings

    // Cache similarity scores to avoid repeated ANN queries
    private var similarityCache: [UUID: Double] = [:]
    private var cacheTimestamp: Date?
    private let cacheValiditySeconds: TimeInterval = 300  // 5 minutes

    // Reactive staleness tracking (ADR-022)
    private var isStale = false
    private var indexedLibraryIDs: [UUID] = []
    private var lastBuildDate: Date?
    private var observersSetUp = false

    // Guard against concurrent builds
    private var isBuilding = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Check if the embedding service is available.
    public var isAvailable: Bool {
        RustAnnIndexInfo.isAvailable
    }

    /// Check if the index has been built.
    public var hasIndex: Bool {
        isIndexBuilt
    }

    /// Whether a lazy index build has been requested but not yet completed.
    private var needsLazyBuild = false

    /// Mark that the index should be built lazily (on first Cmd+K press).
    /// Called at startup instead of eagerly building the index.
    public func setNeedsIndexBuild() {
        needsLazyBuild = true
    }

    /// Ensure the index is ready, building it if needed (lazy build on first use).
    /// Returns true if the index is available.
    @discardableResult
    public func ensureIndexReady() async -> Bool {
        if isIndexBuilt { return true }
        guard needsLazyBuild, isAvailable, !isBuilding else { return false }
        needsLazyBuild = false

        Logger.embeddingService.infoCapture("Lazy-building embedding index on first use...", category: "embedding")

        let libraries = await MainActor.run {
            RustStoreAdapter.shared.listLibraries().filter { lib in
                let name = lib.name.lowercased()
                return name != "dismissed" && name != "exploration"
            }
        }

        guard !libraries.isEmpty else { return false }
        let count = await buildIndex(from: libraries.map(\.id))
        Logger.embeddingService.infoCapture("Lazy-built embedding index with \(count) publications", category: "embedding")
        return count > 0
    }

    /// Get the number of indexed publications.
    public func indexedCount() async -> Int {
        await annIndex?.count() ?? 0
    }

    /// Build or rebuild the ANN index from a library.
    ///
    /// - Parameter libraryID: The library ID to index
    /// - Returns: Number of publications indexed
    @discardableResult
    public func buildIndex(from libraryID: UUID) async -> Int {
        return await buildIndex(from: [libraryID])
    }

    /// Build or rebuild the ANN index from multiple libraries.
    ///
    /// - Parameter libraryIDs: The library IDs to index
    /// - Returns: Number of publications indexed
    @discardableResult
    public func buildIndex(from libraryIDs: [UUID]) async -> Int {
        // Guard against concurrent builds
        guard !isBuilding else {
            Logger.embeddingService.debug("Skipping index build - already in progress")
            return 0
        }
        isBuilding = true
        defer { isBuilding = false }

        Logger.embeddingService.infoCapture("Building embedding index for \(libraryIDs.count) libraries", category: "embedding")

        // Initialize new index
        let index = RustAnnIndex()
        await index.initialize(
            maxConnections: 16,
            capacity: 10000,
            maxLayer: 16,
            efConstruction: 200
        )

        var indexedCount = 0
        var items: [(String, [Float])] = []

        for libraryID in libraryIDs {
            // Get publications from the Rust store
            let publications = await MainActor.run {
                RustStoreAdapter.shared.queryPublications(parentId: libraryID)
            }

            for pub in publications {
                // Extract embedding vector from publication metadata
                let pubID = pub.id.uuidString
                let vector = computeEmbeddingFromRowData(pub)

                items.append((pubID, vector))
                indexedPublicationIDs.insert(pubID)
                indexedCount += 1
            }
        }

        // Batch add to index
        if !items.isEmpty {
            await index.addBatch(items)
        }

        self.annIndex = index
        self.isIndexBuilt = true
        self.isStale = false
        self.lastBuildDate = Date()
        self.indexedLibraryIDs = libraryIDs
        self.invalidateCache()

        Logger.embeddingService.infoCapture("Built embedding index with \(indexedCount) publications from \(libraryIDs.count) libraries", category: "embedding")

        return indexedCount
    }

    /// Add a publication to the index by ID.
    ///
    /// Use this when a new publication is added to the library.
    public func addToIndex(_ publicationID: UUID) async {
        guard let index = annIndex else {
            Logger.embeddingService.warning("Cannot add to index: index not built")
            return
        }

        // Get publication detail from Rust store
        guard let pub = await MainActor.run(body: { RustStoreAdapter.shared.getPublicationDetail(id: publicationID) }) else {
            Logger.embeddingService.warning("Cannot add to index: publication not found")
            return
        }

        let pubID = publicationID.uuidString
        let vector = computeEmbeddingFromModel(pub)

        if await index.add(publicationId: pubID, embedding: vector) {
            indexedPublicationIDs.insert(pubID)
            invalidateCache()
        }
    }

    /// Find publications similar to the given publication.
    ///
    /// Automatically rebuilds the index if it has become stale due to
    /// library changes (reactive freshness - ADR-022).
    ///
    /// - Parameters:
    ///   - publicationID: The publication ID to find similar papers for
    ///   - topK: Maximum number of results to return
    /// - Returns: Array of similarity results
    public func findSimilar(to publicationID: UUID, topK: Int = 10) async -> [SimilarityResult] {
        // Ensure index is fresh before searching (reactive rebuild if stale)
        if isStale {
            await ensureFreshIndex()
        }

        guard let index = annIndex else {
            return []
        }

        // Get publication detail for embedding
        guard let pub = await MainActor.run(body: { RustStoreAdapter.shared.getPublicationDetail(id: publicationID) }) else {
            return []
        }

        let embedding = computeEmbeddingFromModel(pub)
        return await index.findSimilar(to: embedding, topK: topK)
    }

    /// Search for publications similar to a text query.
    ///
    /// Computes an embedding for the query text and finds similar publications.
    /// Useful for semantic search where you want to find papers conceptually
    /// related to a query rather than matching exact keywords.
    ///
    /// - Parameters:
    ///   - query: The text query to search for
    ///   - topK: Maximum number of results to return
    /// - Returns: Array of similarity results
    public func searchByText(_ query: String, topK: Int = 20) async -> [SimilarityResult] {
        // Ensure index is fresh before searching (reactive rebuild if stale)
        if isStale {
            await ensureFreshIndex()
        }

        guard let index = annIndex, isIndexBuilt else {
            return []
        }

        let embedding = computeTextEmbedding(query)
        return await index.findSimilar(to: embedding, topK: topK)
    }

    /// Get the similarity score for a publication against the library.
    ///
    /// This is the main entry point for the recommendation engine.
    /// Returns a normalized score in [0, 1] range.
    ///
    /// Automatically rebuilds the index if it has become stale due to
    /// library changes (reactive freshness - ADR-022).
    ///
    /// - Parameter publicationID: The publication ID to score
    /// - Returns: Similarity score (0 = no similarity, 1 = very similar)
    public func similarityScore(for publicationID: UUID) async -> Double {
        // Ensure index is fresh before scoring (reactive rebuild if stale)
        if isStale {
            await ensureFreshIndex()
        }

        // Check cache
        if let cached = cachedScore(for: publicationID) {
            return cached
        }

        // Find similar papers
        let results = await findSimilar(to: publicationID, topK: 5)

        // Compute aggregate score
        let similarities = results.map { $0.similarity }
        let score = FeatureExtractor.librarySimilarityScore(from: similarities)

        // Cache result
        cacheScore(score, for: publicationID)

        return score
    }

    /// Invalidate the similarity cache.
    ///
    /// Call this when the library changes significantly.
    public func invalidateCache() {
        similarityCache.removeAll()
        cacheTimestamp = nil
        // Note: Not logging here to avoid spam during batch operations
    }

    /// Clear the index and start fresh.
    public func clearIndex() async {
        await annIndex?.close()
        annIndex = nil
        isIndexBuilt = false
        indexedPublicationIDs.removeAll()
        invalidateCache()
        Logger.embeddingService.info("Embedding index cleared")
    }

    // MARK: - Group Recommendations

    /// Find publications similar to the collective content of a library.
    ///
    /// Computes a centroid embedding from all publications in the library,
    /// then searches a candidate set (e.g., inbox or exploration results)
    /// for papers most similar to that centroid. This provides "suggested
    /// for the group" recommendations based on the shared library's
    /// collective content rather than any individual's reading habits.
    ///
    /// - Parameters:
    ///   - libraryID: The library ID to compute the group profile from
    ///   - candidateIDs: Publication IDs to score against the group profile
    ///   - topK: Maximum number of recommendations
    /// - Returns: Array of candidate publication IDs sorted by relevance
    public func groupRecommendations(
        for libraryID: UUID,
        candidateIDs: [UUID],
        topK: Int = 10
    ) async -> [UUID] {
        guard isAvailable else { return [] }

        // Get all library publications and compute embeddings
        let libraryPubs = await MainActor.run {
            RustStoreAdapter.shared.queryPublications(parentId: libraryID)
        }

        let libraryEmbeddings: [[Float]] = libraryPubs.map { computeEmbeddingFromRowData($0) }

        guard !libraryEmbeddings.isEmpty else { return [] }

        // Average all embeddings to get group centroid
        var centroid = [Float](repeating: 0, count: embeddingDimension)
        for emb in libraryEmbeddings {
            for i in 0..<embeddingDimension {
                centroid[i] += emb[i]
            }
        }
        let count = Float(libraryEmbeddings.count)
        centroid = centroid.map { $0 / count }

        // Normalize centroid
        let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            centroid = centroid.map { $0 / norm }
        }

        // Score each candidate against the centroid
        var scored: [(UUID, Float)] = []
        for candidateID in candidateIDs {
            guard let pub = await MainActor.run(body: { RustStoreAdapter.shared.getPublicationDetail(id: candidateID) }) else {
                continue
            }

            let embedding = computeEmbeddingFromModel(pub)

            // Cosine similarity
            var dot: Float = 0
            for i in 0..<embeddingDimension {
                dot += centroid[i] * embedding[i]
            }
            scored.append((candidateID, dot))
        }

        // Sort by similarity descending and return top-K
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(topK).map(\.0))
    }

    // MARK: - Private Methods

    /// Compute an embedding vector from a PublicationRowData.
    nonisolated private func computeEmbeddingFromRowData(_ pub: PublicationRowData) -> [Float] {
        // Combine relevant text fields
        var text = pub.title + " "
        text += pub.authorString + " "
        if let venue = pub.venue {
            text += venue + " "
        }
        if let category = pub.primaryCategory {
            text += category
        }

        return computeTextEmbedding(text)
    }

    /// Compute an embedding vector from a PublicationModel.
    nonisolated private func computeEmbeddingFromModel(_ pub: PublicationModel) -> [Float] {
        // Combine relevant text fields
        var text = pub.title + " "
        if let abstract = pub.abstract {
            text += abstract + " "
        }
        // Add author names
        for author in pub.authors {
            text += author.familyName + " "
        }
        // Add keywords if available
        if let keywords = pub.fields["keywords"] {
            text += keywords
        }

        return computeTextEmbedding(text)
    }

    /// Compute a semantic embedding from text using Apple's NaturalLanguage framework.
    ///
    /// Uses word embeddings from NLEmbedding and aggregates them with IDF weighting
    /// to create sentence-level embeddings. This provides better semantic understanding
    /// than simple bag-of-words approaches.
    ///
    /// Falls back to hash-based embeddings for unsupported languages or missing words.
    nonisolated private func computeTextEmbedding(_ text: String) -> [Float] {
        var embedding = [Float](repeating: 0.0, count: embeddingDimension)

        // Tokenize using NaturalLanguage
        let tokenizer = NLTokenizer(unit: .word)
        let lowercasedText = text.lowercased()
        tokenizer.string = lowercasedText

        var tokens: [String] = []
        tokenizer.enumerateTokens(in: lowercasedText.startIndex..<lowercasedText.endIndex) { range, _ in
            let token = String(lowercasedText[range])
            if token.count >= 2 {
                tokens.append(token)
            }
            return true
        }

        guard !tokens.isEmpty else {
            return embedding
        }

        // Get word embeddings from Apple's NLEmbedding (English, 512-dim)
        guard let nlEmbedding = NLEmbedding.wordEmbedding(for: .english) else {
            // Fall back to hash-based if no embedding available
            return hashBasedEmbedding(tokens)
        }

        // Collect word embeddings with IDF-style weighting
        var wordVectors: [[Double]] = []
        var weights: [Double] = []
        var wordCounts: [String: Int] = [:]

        // Count word frequencies for IDF
        for token in tokens {
            wordCounts[token, default: 0] += 1
        }

        for token in tokens {
            if let vector = nlEmbedding.vector(for: token) {
                wordVectors.append(vector)
                // IDF-style weight: words appearing less often in this text matter more
                // Also weight by inverse document frequency if we had a corpus
                let tf = Double(wordCounts[token] ?? 1)
                let weight = 1.0 / log(tf + 1.0)
                weights.append(weight)
            }
        }

        // If no word embeddings found, fall back to hash-based
        if wordVectors.isEmpty {
            return hashBasedEmbedding(tokens)
        }

        // Weighted average of word embeddings
        let nlDimension = wordVectors[0].count  // Apple uses 512-dim
        var aggregated = [Double](repeating: 0.0, count: nlDimension)
        var totalWeight = 0.0

        for (vector, weight) in zip(wordVectors, weights) {
            for i in 0..<nlDimension {
                aggregated[i] += vector[i] * weight
            }
            totalWeight += weight
        }

        if totalWeight > 0 {
            aggregated = aggregated.map { $0 / totalWeight }
        }

        // Normalize to unit vector
        let norm = sqrt(aggregated.reduce(0.0) { $0 + $1 * $1 })
        if norm > 0 {
            aggregated = aggregated.map { $0 / norm }
        }

        // Resize to target dimension (384) using truncation or PCA-style projection
        // For simplicity, we'll use strided sampling to reduce from 512 to 384
        let stride = Double(nlDimension) / Double(embeddingDimension)
        for i in 0..<embeddingDimension {
            let sourceIdx = min(Int(Double(i) * stride), nlDimension - 1)
            embedding[i] = Float(aggregated[sourceIdx])
        }

        // Re-normalize after dimension reduction
        let finalNorm = sqrt(embedding.reduce(0.0) { $0 + $1 * $1 })
        if finalNorm > 0 {
            embedding = embedding.map { $0 / finalNorm }
        }

        return embedding
    }

    /// Hash-based fallback embedding for when word embeddings aren't available.
    nonisolated private func hashBasedEmbedding(_ tokens: [String]) -> [Float] {
        var embedding = [Float](repeating: 0.0, count: embeddingDimension)

        for word in tokens where word.count >= 3 {
            let hash1 = abs(word.hashValue)
            let hash2 = abs(word.hashValue &* 31)
            let hash3 = abs(word.hashValue &* 37)

            let idx1 = hash1 % embeddingDimension
            let idx2 = hash2 % embeddingDimension
            let idx3 = hash3 % embeddingDimension

            embedding[idx1] += 1.0
            embedding[idx2] += 0.5
            embedding[idx3] += 0.25
        }

        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            embedding = embedding.map { $0 / norm }
        }

        return embedding
    }

    /// Check if cache is valid and return cached score if available.
    private func cachedScore(for publicationID: UUID) -> Double? {
        guard let timestamp = cacheTimestamp,
              Date().timeIntervalSince(timestamp) < cacheValiditySeconds else {
            return nil
        }
        return similarityCache[publicationID]
    }

    /// Cache a similarity score.
    private func cacheScore(_ score: Double, for publicationID: UUID) {
        if cacheTimestamp == nil {
            cacheTimestamp = Date()
        }
        similarityCache[publicationID] = score
    }
}

// MARK: - Reactive Index Updates (ADR-022)

extension EmbeddingService {

    /// Set up notification observers for reactive index updates.
    ///
    /// Call this once on app startup. The service will then automatically:
    /// - Mark the index stale when data changes
    /// - Rebuild lazily before the next scoring operation
    public func setupChangeObservers() async {
        guard !observersSetUp else { return }
        observersSetUp = true

        await MainActor.run {
            NotificationCenter.default.addObserver(
                forName: .rustStoreDidMutate,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task {
                    await self?.markStale()
                }
            }
        }

        Logger.embeddingService.info("Embedding service change observers set up")
    }

    /// Mark the index as stale, requiring rebuild before next use.
    public func markStale() {
        isStale = true
        invalidateCache()
    }

    /// Check if the index is stale and needs rebuilding.
    public var needsRebuild: Bool {
        isStale
    }

    /// Ensure the index is fresh before scoring.
    ///
    /// If the index is stale, rebuilds from the previously indexed libraries.
    /// Call this before any scoring operation.
    ///
    /// - Returns: True if index is ready, false if no libraries to index from
    @discardableResult
    public func ensureFreshIndex() async -> Bool {
        guard isStale, !indexedLibraryIDs.isEmpty else {
            return isIndexBuilt
        }

        let libraryIDs = indexedLibraryIDs

        Logger.embeddingService.info("Rebuilding stale index from \(libraryIDs.count) libraries")
        await buildIndex(from: libraryIDs)
        return true
    }

}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the embedding index is rebuilt
    static let embeddingIndexDidRebuild = Notification.Name("embeddingIndexDidRebuild")

    /// Posted when the Rust store has been mutated (used by EmbeddingService for staleness tracking)
    static let rustStoreDidMutate = Notification.Name("rustStoreDidMutate")
}
