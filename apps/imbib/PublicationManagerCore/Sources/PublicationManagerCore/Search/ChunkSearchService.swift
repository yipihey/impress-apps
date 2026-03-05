//
//  ChunkSearchService.swift
//  PublicationManagerCore
//
//  Persistent in-memory chunk-level HNSW index for full-text passage search.
//  Loaded lazily from SQLite on first use, served from memory on subsequent searches.
//

import Foundation
import OSLog
import ImbibRustCore

private let logger = Logger(subsystem: "com.imbib", category: "ChunkSearch")

// MARK: - Chunk Search Service

/// Actor that maintains a persistent in-memory HNSW index of chunk embeddings.
///
/// Building an HNSW from scratch on every Cmd+K keypress would be too slow (~75MB
/// of vectors for a typical library). This service loads all chunk vectors from
/// SQLite once per app launch and serves subsequent searches from memory.
///
/// New chunks (from DocumentPipeline) are added incrementally via `addChunks(_:)`.
/// Call `reload()` after a "Re-index All" operation in Settings.
public actor ChunkSearchService {

    // MARK: - Singleton

    public static let shared = ChunkSearchService()
    private init() {}

    // MARK: - Properties

    private var index: RustChunkIndexSession?
    private var store: RustEmbeddingStoreSession?
    private var isLoaded = false
    private var isLoading = false

    // MARK: - Public API

    /// True when the in-memory index has been loaded and contains at least one chunk.
    public var hasChunks: Bool {
        isLoaded && (index != nil)
    }

    /// Ensure the in-memory HNSW is loaded from SQLite. Safe to call multiple times.
    public func ensureLoaded() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let embeddingStore = RustEmbeddingStoreSession()
        guard await embeddingStore.openDefault() else {
            logger.warning("ChunkSearchService: could not open embedding store")
            isLoaded = true
            return
        }

        let vectors = await embeddingStore.loadVectorsByType("chunk")
        guard !vectors.isEmpty else {
            logger.info("ChunkSearchService: no chunk vectors in store, skipping HNSW build")
            await embeddingStore.close()
            isLoaded = true
            return
        }

        // Build in-memory HNSW from stored vectors.
        // publicationId is set to empty string here — performChunkSearch always
        // resolves the real pub ID via getChunk(chunkId:) for chunk text + metadata.
        let idx = RustChunkIndexSession()
        await idx.initialize()

        let items = vectors.map { v in
            ChunkIndexItem(chunkId: v.sourceId, publicationId: "", embedding: v.vector)
        }
        await idx.addBatch(items)

        self.index = idx
        self.store = embeddingStore
        self.isLoaded = true

        logger.info("ChunkSearchService: loaded \(vectors.count) chunk vectors into HNSW")
    }

    /// Search for the top-K most similar chunks to a query embedding.
    ///
    /// - Parameters:
    ///   - queryEmbedding: The query vector.
    ///   - topK: Maximum number of chunk hits to return.
    /// - Returns: Results sorted by similarity descending.
    public func search(queryEmbedding: [Float], topK: Int) async -> [ChunkSimilarityResult] {
        guard let idx = index else { return [] }
        return await idx.search(query: queryEmbedding, topK: topK)
    }

    /// Fetch a chunk's text and metadata from SQLite by chunk ID.
    public func getChunk(chunkId: String) async -> StoredChunk? {
        guard let store = store else { return nil }
        return await store.getChunk(chunkId: chunkId)
    }

    /// Add newly processed chunks to the live in-memory index.
    ///
    /// Call this after `DocumentPipeline.processDocument()` to keep the search
    /// index current without requiring a full `reload()`.
    public func addChunks(_ items: [ChunkIndexItem]) async {
        guard let idx = index, isLoaded else {
            // Index not yet loaded — chunks will be picked up on next ensureLoaded()
            return
        }
        await idx.addBatch(items)
        logger.debug("ChunkSearchService: added \(items.count) chunks to live index")
    }

    /// Rebuild the in-memory index from scratch (call after "Re-index All" in Settings).
    public func reload() async {
        isLoaded = false
        isLoading = false
        if let idx = index { await idx.close() }
        if let st = store { await st.close() }
        index = nil
        store = nil
        await ensureLoaded()
    }
}
