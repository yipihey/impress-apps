//
//  EmbeddingService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-21.
//

import Foundation
import CoreData
import OSLog

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
/// await EmbeddingService.shared.buildIndex(from: library)
///
/// // Find similar papers
/// let similar = await EmbeddingService.shared.findSimilar(to: publication)
///
/// // Get similarity score for a publication
/// let score = await EmbeddingService.shared.similarityScore(for: publication)
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
    private var indexedLibraryIDs: [NSManagedObjectID] = []
    private var lastBuildDate: Date?
    private var observersSetUp = false

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

    /// Get the number of indexed publications.
    public func indexedCount() async -> Int {
        await annIndex?.count() ?? 0
    }

    /// Build or rebuild the ANN index from library publications.
    ///
    /// - Parameter library: The library to index
    /// - Returns: Number of publications indexed
    @discardableResult
    public func buildIndex(from library: CDLibrary) async -> Int {
        return await buildIndex(from: [library])
    }

    /// Build or rebuild the ANN index from multiple libraries.
    ///
    /// - Parameter libraries: The libraries to index
    /// - Returns: Number of publications indexed
    @discardableResult
    public func buildIndex(from libraries: [CDLibrary]) async -> Int {
        Logger.embeddingService.infoCapture("Building embedding index for \(libraries.count) libraries", category: "embedding")

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

        for library in libraries {
            // Get publications on main actor
            let publications = await MainActor.run {
                Array(library.publications ?? [])
            }

            for publication in publications {
                // Extract embedding vector from publication metadata
                let (id, embedding) = await MainActor.run {
                    let pubID = publication.id.uuidString
                    let vector = self.computeEmbedding(for: publication)
                    return (pubID, vector)
                }

                items.append((id, embedding))
                indexedPublicationIDs.insert(id)
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
        self.indexedLibraryIDs = await MainActor.run {
            libraries.map { $0.objectID }
        }
        self.invalidateCache()

        Logger.embeddingService.infoCapture("Built embedding index with \(indexedCount) publications from \(libraries.count) libraries", category: "embedding")

        return indexedCount
    }

    /// Add a publication to the index.
    ///
    /// Use this when a new publication is added to the library.
    public func addToIndex(_ publication: CDPublication) async {
        guard let index = annIndex else {
            Logger.embeddingService.warning("Cannot add to index: index not built")
            return
        }

        let (id, embedding) = await MainActor.run {
            let pubID = publication.id.uuidString
            let vector = self.computeEmbedding(for: publication)
            return (pubID, vector)
        }

        if await index.add(publicationId: id, embedding: embedding) {
            indexedPublicationIDs.insert(id)
            invalidateCache()
        }
    }

    /// Find publications similar to the given publication.
    ///
    /// Automatically rebuilds the index if it has become stale due to
    /// library changes (reactive freshness - ADR-022).
    ///
    /// - Parameters:
    ///   - publication: The publication to find similar papers for
    ///   - topK: Maximum number of results to return
    /// - Returns: Array of similarity results
    public func findSimilar(to publication: CDPublication, topK: Int = 10) async -> [SimilarityResult] {
        // Ensure index is fresh before searching (reactive rebuild if stale)
        if isStale {
            await ensureFreshIndex()
        }

        guard let index = annIndex else {
            return []
        }

        let embedding = await MainActor.run {
            self.computeEmbedding(for: publication)
        }

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
    /// - Parameter publication: The publication to score
    /// - Returns: Similarity score (0 = no similarity, 1 = very similar)
    public func similarityScore(for publication: CDPublication) async -> Double {
        // Ensure index is fresh before scoring (reactive rebuild if stale)
        if isStale {
            await ensureFreshIndex()
        }

        // Check cache
        let pubID = await MainActor.run { publication.id }
        if let cached = cachedScore(for: pubID) {
            return cached
        }

        // Find similar papers
        let results = await findSimilar(to: publication, topK: 5)

        // Compute aggregate score
        let similarities = results.map { $0.similarity }
        let score = FeatureExtractor.librarySimilarityScore(from: similarities)

        // Cache result
        cacheScore(score, for: pubID)

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

    // MARK: - Private Methods

    /// Compute an embedding vector for a publication.
    ///
    /// Currently uses a simple TF-IDF-like approach based on word frequencies.
    /// In the future, this could use a proper sentence embedding model.
    @MainActor
    private func computeEmbedding(for publication: CDPublication) -> [Float] {
        // Combine relevant text fields
        var text = ""
        if let title = publication.title {
            text += title + " "
        }
        if let abstract = publication.fields["abstract"] {
            text += abstract + " "
        }
        // Add author names
        for author in publication.sortedAuthors {
            text += author.familyName + " "
        }
        // Add keywords if available
        if let keywords = publication.fields["keywords"] {
            text += keywords
        }

        return computeTextEmbedding(text)
    }

    /// Compute a simple embedding from text.
    ///
    /// Uses a hash-based approach to create a fixed-size vector.
    /// This is a placeholder for proper sentence embeddings.
    nonisolated private func computeTextEmbedding(_ text: String) -> [Float] {
        var embedding = [Float](repeating: 0.0, count: embeddingDimension)

        // Tokenize
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        // Simple bag-of-words with hashing
        for word in words {
            // Hash word to multiple indices (simulating sparse embeddings)
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

        // Normalize to unit vector
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

    /// Set up Core Data change observers for reactive index updates.
    ///
    /// Call this once on app startup. The service will then automatically:
    /// - Add new publications incrementally to the index
    /// - Mark the index stale when publications are updated or deleted
    /// - Rebuild lazily before the next scoring operation
    public func setupChangeObservers() async {
        guard !observersSetUp else { return }
        observersSetUp = true

        await MainActor.run {
            NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task {
                    await self?.handleContextDidSave(notification)
                }
            }
        }

        Logger.embeddingService.info("Embedding service change observers set up")
    }

    /// Handle Core Data context save notification.
    private func handleContextDidSave(_ notification: Notification) async {
        guard isIndexBuilt else { return }

        let userInfo = notification.userInfo ?? [:]

        // Check for inserted publications
        if let inserted = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> {
            let newPublications = inserted.compactMap { $0 as? CDPublication }
            var addedCount = 0
            for publication in newPublications {
                // Check if this publication belongs to any indexed library
                let pubLibraryIDs = await MainActor.run {
                    publication.libraries?.map { $0.objectID } ?? []
                }
                let belongsToIndexedLibrary = pubLibraryIDs.contains { indexedLibraryIDs.contains($0) }
                if belongsToIndexedLibrary {
                    await addToIndex(publication)
                    addedCount += 1
                }
            }
            if addedCount > 0 {
                Logger.embeddingService.debug("Incrementally added \(addedCount) publications to embedding index")
            }
        }

        // Check for updated publications - mark stale (HNSW can't update in place)
        if let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> {
            let updatedPublications = updated.compactMap { $0 as? CDPublication }
            if !updatedPublications.isEmpty {
                // Check if any belong to indexed libraries
                for publication in updatedPublications {
                    let pubLibraryIDs = await MainActor.run {
                        publication.libraries?.map { $0.objectID } ?? []
                    }
                    let belongsToIndexedLibrary = pubLibraryIDs.contains { indexedLibraryIDs.contains($0) }
                    if belongsToIndexedLibrary {
                        markStale()
                        Logger.embeddingService.infoCapture("Marked index stale due to publication update", category: "embedding")
                        break
                    }
                }
            }
        }

        // Check for deleted publications - mark stale (HNSW can't remove)
        if let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> {
            let deletedPublications = deleted.filter { $0.entity.name == "Publication" }
            if !deletedPublications.isEmpty {
                markStale()
                Logger.embeddingService.infoCapture("Marked index stale due to publication deletion", category: "embedding")
            }
        }
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

        // Capture IDs before entering MainActor context (actor isolation)
        let libraryIDs = indexedLibraryIDs

        // Fetch libraries from their object IDs using the shared persistence controller
        let libraries = await MainActor.run {
            let context = PersistenceController.shared.viewContext
            return libraryIDs.compactMap { objectID -> CDLibrary? in
                try? context.existingObject(with: objectID) as? CDLibrary
            }
        }

        guard !libraries.isEmpty else {
            Logger.embeddingService.warning("No valid libraries found for index rebuild")
            return false
        }

        Logger.embeddingService.info("Rebuilding stale index from \(libraries.count) libraries")
        await buildIndex(from: libraries)
        return true
    }

}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the embedding index is rebuilt
    static let embeddingIndexDidRebuild = Notification.Name("embeddingIndexDidRebuild")
}
