//
//  EmbeddingService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-21.
//

import Foundation
import OSLog
import NaturalLanguage
import ImpressEmbeddings
import ImbibRustCore

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

    /// Register the Apple contextual embedding provider if none is active.
    public func registerProviderIfNeeded() async {
        guard await EmbeddingProviderRegistry.shared.activeProvider == nil else { return }
        if #available(macOS 14, iOS 17, *) {
            await EmbeddingProviderRegistry.shared.register(AppleContextualEmbeddingProvider())
            Logger.embeddingService.infoCapture("Registered AppleContextualEmbeddingProvider", category: "embeddings")
        }
    }

    /// Ensure the index is ready, building it if needed (lazy build on first use).
    /// Returns true if the index is available.
    @discardableResult
    public func ensureIndexReady() async -> Bool {
        if isIndexBuilt { return true }
        guard needsLazyBuild, isAvailable, !isBuilding else { return false }
        needsLazyBuild = false

        // Register embedding provider before building the index
        await registerProviderIfNeeded()

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
                let pubID = pub.id.uuidString
                let vector = await computeEmbeddingFromRowData(pub)
                items.append((pubID, vector))
                indexedPublicationIDs.insert(pubID)
                indexedCount += 1
            }
        }

        // Batch add to index
        if !items.isEmpty {
            await index.addBatch(items)

            // Persist metadata embeddings to SQLite so they show in status/stats
            let embeddingStore = RustEmbeddingStoreSession()
            let opened = await embeddingStore.openDefault()
            if opened {
                let providerName = await EmbeddingProviderRegistry.shared.activeProvider?.id ?? "apple-nl"
                let now = ISO8601DateFormatter().string(from: Date())
                let storedVectors = items.map { (pubID, vector) in
                    StoredVector(
                        id: "pub-\(pubID)",
                        sourceId: pubID,
                        sourceType: "publication",
                        vector: vector,
                        model: providerName,
                        createdAt: now
                    )
                }
                let saved = await embeddingStore.saveVectors(storedVectors)
                Logger.embeddingService.infoCapture("Persisted \(saved) metadata vectors to embedding store (attempted \(storedVectors.count))", category: "embedding")
                await embeddingStore.close()
            } else {
                Logger.embeddingService.infoCapture("Failed to open embedding store for vector persistence", category: "embedding")
            }
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
        let vector = await computeEmbeddingFromModel(pub)

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

        let embedding = await computeEmbeddingFromModel(pub)
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

        let embedding = await embedText(query)
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

    /// Compute an embedding for arbitrary text.
    ///
    /// Uses the active `EmbeddingProviderRegistry` provider (contextual, 512-dim) if available,
    /// falling back to the sync word-embedding implementation (384-dim).
    public func embedText(_ text: String) async -> [Float] {
        if let provider = await EmbeddingProviderRegistry.shared.activeProvider {
            return (try? await provider.embed(text)) ?? []
        }
        return computeTextEmbedding(text)
    }

    /// Force a full rebuild of the embedding index from all libraries.
    public func forceRebuild() async {
        await clearIndex()
        needsLazyBuild = true
        await ensureIndexReady()
    }

    /// Find similar publications using chunk-level content embeddings when available.
    ///
    /// This provides deeper similarity based on full paper content rather than
    /// just metadata (title/abstract). Falls back to metadata-based similarity
    /// if the paper hasn't been chunk-indexed.
    ///
    /// - Parameters:
    ///   - publicationID: The publication ID to find similar papers for
    ///   - topK: Maximum number of results to return
    /// - Returns: Array of (publicationId, similarity) pairs
    public func findSimilarByContent(to publicationID: UUID, topK: Int = 10) async -> [SimilarityResult] {
        // Try chunk-level similarity first
        let store = RustEmbeddingStoreSession()
        let opened = await store.openDefault()
        guard opened else {
            // Fall back to metadata-based
            return await findSimilar(to: publicationID, topK: topK)
        }

        let chunks = await store.getChunks(publicationId: publicationID.uuidString)
        guard !chunks.isEmpty else {
            await store.close()
            Logger.embeddingService.debug("No chunks for \(publicationID.uuidString), falling back to metadata similarity")
            return await findSimilar(to: publicationID, topK: topK)
        }

        // Compute centroid embedding from all chunk embeddings for this paper
        let chunkVectors = await store.loadVectorsByType("chunk")
        await store.close()

        let myChunkIds = Set(chunks.map(\.id))
        let myVectors = chunkVectors.filter { myChunkIds.contains($0.sourceId) }.map(\.vector)

        guard !myVectors.isEmpty, let dim = myVectors.first?.count else {
            return await findSimilar(to: publicationID, topK: topK)
        }

        // Compute centroid of this paper's chunk embeddings
        var centroid = [Float](repeating: 0, count: dim)
        for vec in myVectors {
            for i in 0..<min(dim, vec.count) {
                centroid[i] += vec[i]
            }
        }
        let count = Float(myVectors.count)
        centroid = centroid.map { $0 / count }

        // Search the publication-level index with this centroid
        guard let index = annIndex, isIndexBuilt else {
            return []
        }

        var results = await index.findSimilar(to: centroid, topK: topK + 1)
        // Remove self from results
        results.removeAll { $0.publicationId == publicationID.uuidString }
        return Array(results.prefix(topK))
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

        var libraryEmbeddings: [[Float]] = []
        for pub in libraryPubs {
            libraryEmbeddings.append(await computeEmbeddingFromRowData(pub))
        }

        guard !libraryEmbeddings.isEmpty else { return [] }

        let dim = libraryEmbeddings[0].count
        guard dim > 0 else { return [] }

        // Average all embeddings to get group centroid
        var centroid = [Float](repeating: 0, count: dim)
        for emb in libraryEmbeddings {
            for i in 0..<min(dim, emb.count) {
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

            let embedding = await computeEmbeddingFromModel(pub)

            // Cosine similarity
            var dot: Float = 0
            for i in 0..<min(dim, embedding.count) {
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
    private func computeEmbeddingFromRowData(_ pub: PublicationRowData) async -> [Float] {
        var text = pub.title + " "
        text += pub.authorString + " "
        if let venue = pub.venue {
            text += venue + " "
        }
        if let category = pub.primaryCategory {
            text += category
        }
        return await embedText(text)
    }

    /// Compute an embedding vector from a PublicationModel.
    private func computeEmbeddingFromModel(_ pub: PublicationModel) async -> [Float] {
        var text = pub.title + " "
        if let abstract = pub.abstract {
            text += abstract + " "
        }
        for author in pub.authors {
            text += author.familyName + " "
        }
        if let keywords = pub.fields["keywords"] {
            text += keywords
        }
        return await embedText(text)
    }

    /// Compute a semantic embedding from text using Apple's NaturalLanguage framework.
    ///
    /// Uses word embeddings from NLEmbedding and aggregates them with IDF weighting
    /// to create sentence-level embeddings. This provides better semantic understanding
    /// than simple bag-of-words approaches.
    ///
    /// Falls back to hash-based embeddings for unsupported languages or missing words.
    nonisolated private func computeTextEmbedding(_ text: String) -> [Float] {
        let wordEmbeddingDimension = 384
        var embedding = [Float](repeating: 0.0, count: wordEmbeddingDimension)

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

        // Resize to target dimension (384) using strided sampling from 512
        let stride = Double(nlDimension) / Double(wordEmbeddingDimension)
        for i in 0..<wordEmbeddingDimension {
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
        let wordEmbeddingDimension = 384
        var embedding = [Float](repeating: 0.0, count: wordEmbeddingDimension)

        for word in tokens where word.count >= 3 {
            let hash1 = abs(word.hashValue)
            let hash2 = abs(word.hashValue &* 31)
            let hash3 = abs(word.hashValue &* 37)

            let idx1 = hash1 % wordEmbeddingDimension
            let idx2 = hash2 % wordEmbeddingDimension
            let idx3 = hash3 % wordEmbeddingDimension

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

// MARK: - Chunk Indexing (DocumentPipeline)

extension EmbeddingService {

    /// Process and chunk-index a publication's PDF.
    ///
    /// - Parameters:
    ///   - publicationId: The publication to process.
    ///   - libraryId: Optional library ID for PDF path resolution.
    /// - Returns: Number of chunks stored, or 0 on failure.
    @discardableResult
    public func indexChunksForPublication(_ publicationId: UUID, libraryId: UUID? = nil) async -> Int {
        // Resolve the linked PDF URL
        let pdfURL: URL? = await MainActor.run {
            let linkedFiles = RustStoreAdapter.shared.listLinkedFiles(publicationId: publicationId)
            guard let pdfFile = linkedFiles.first(where: { $0.isPDF && $0.isLocallyMaterialized }) else {
                return nil
            }
            return AttachmentManager.shared.resolveURL(for: pdfFile, in: libraryId)
        }

        guard let pdfURL else {
            Logger.embeddingService.debug("No local PDF for chunk indexing: \(publicationId)")
            return 0
        }

        // Get an embedding provider
        guard let provider = await EmbeddingProviderRegistry.shared.activeProvider else {
            Logger.embeddingService.warning("No active embedding provider for chunk indexing")
            return 0
        }

        do {
            let pipeline = DocumentPipeline(provider: provider)
            let docResult = try await pipeline.processDocument(publicationId: publicationId, pdfURL: pdfURL)

            guard !docResult.chunks.isEmpty else { return 0 }

            // Persist chunks and vectors to SQLite
            let store = RustEmbeddingStoreSession()
            guard await store.openDefault() else { return 0 }

            let storedChunks = docResult.chunks.map { chunk in
                StoredChunk(
                    id: "\(publicationId.uuidString)-chunk-\(chunk.chunkIndex)",
                    publicationId: publicationId.uuidString,
                    text: chunk.text,
                    pageNumber: chunk.pageNumber.map { UInt32($0) },
                    charOffset: UInt32(chunk.charOffset),
                    charLength: UInt32(chunk.charLength),
                    chunkIndex: UInt32(chunk.chunkIndex)
                )
            }
            await store.saveChunks(storedChunks)

            let storedVectors = zip(storedChunks, docResult.embeddings).map { chunk, emb in
                StoredVector(
                    id: chunk.id,
                    sourceId: chunk.id,
                    sourceType: "chunk",
                    vector: emb,
                    model: provider.id,
                    createdAt: ISO8601DateFormatter().string(from: Date())
                )
            }
            await store.saveVectors(storedVectors)
            await store.close()

            // Update the live in-memory index
            let indexItems = zip(storedChunks, docResult.embeddings).map { chunk, emb in
                ChunkIndexItem(chunkId: chunk.id, publicationId: publicationId.uuidString, embedding: emb)
            }
            await ChunkSearchService.shared.addChunks(indexItems)

            Logger.embeddingService.infoCapture(
                "Chunk-indexed \(docResult.chunks.count) chunks for \(publicationId)",
                category: "embeddings"
            )
            return docResult.chunks.count
        } catch {
            Logger.embeddingService.warning("Chunk indexing failed for \(publicationId): \(error)")
            return 0
        }
    }

    /// Check whether a publication already has chunks stored.
    public func isChunkIndexed(_ publicationId: UUID) async -> Bool {
        let store = RustEmbeddingStoreSession()
        guard await store.openDefault() else { return false }
        let chunks = await store.getChunks(publicationId: publicationId.uuidString)
        await store.close()
        return !chunks.isEmpty
    }

    /// Index PDFs for all publications that don't yet have chunk data.
    ///
    /// Called from the "Index Unprocessed Papers" button in Settings.
    /// Processes publications in batches, skipping those already chunk-indexed.
    public func indexChunksForUnprocessedPublications() async {
        Logger.embeddingService.infoCapture("Starting chunk indexing for unprocessed publications", category: "embeddings")

        let pubsWithLibrary: [(pub: PublicationRowData, libraryId: UUID)] = await MainActor.run {
            let store = RustStoreAdapter.shared
            let libraries = store.listLibraries()
            Logger.embeddingService.infoCapture("Found \(libraries.count) libraries for chunk indexing", category: "embeddings")
            var all: [(pub: PublicationRowData, libraryId: UUID)] = []
            var seenIds = Set<UUID>()
            for lib in libraries {
                let pubs = store.queryPublications(parentId: lib.id)
                Logger.embeddingService.infoCapture("Library '\(lib.name)': \(pubs.count) publications", category: "embeddings")
                for pub in pubs {
                    if seenIds.insert(pub.id).inserted {
                        all.append((pub: pub, libraryId: lib.id))
                    }
                }
            }
            return all
        }

        Logger.embeddingService.infoCapture("Total publications to check: \(pubsWithLibrary.count)", category: "embeddings")

        var processed = 0
        var skipped = 0
        var noPdf = 0

        for entry in pubsWithLibrary {
            guard !Task.isCancelled else { break }

            if await isChunkIndexed(entry.pub.id) {
                skipped += 1
                continue
            }

            let count = await indexChunksForPublication(entry.pub.id, libraryId: entry.libraryId)
            if count > 0 {
                processed += 1
            } else {
                noPdf += 1
            }
        }

        Logger.embeddingService.infoCapture(
            "Chunk indexing complete: \(processed) processed, \(skipped) already indexed, \(noPdf) no PDF",
            category: "embeddings"
        )
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the embedding index is rebuilt
    static let embeddingIndexDidRebuild = Notification.Name("embeddingIndexDidRebuild")

    /// Posted when the Rust store has been mutated (used by EmbeddingService for staleness tracking)
    static let rustStoreDidMutate = Notification.Name("rustStoreDidMutate")
}
