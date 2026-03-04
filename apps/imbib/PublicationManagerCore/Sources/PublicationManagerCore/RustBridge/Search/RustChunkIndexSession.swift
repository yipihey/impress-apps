//
//  RustChunkIndexSession.swift
//  PublicationManagerCore
//
//  Actor-based chunk-level HNSW index using Rust.
//  Provides publication-aware similarity search for RAG retrieval.
//

import Foundation
import ImbibRustCore

// MARK: - Chunk Index Session (Actor-based)

/// Actor-based chunk-level ANN index using Rust HNSW implementation.
/// Maps chunk embeddings to their parent publications for scoped search.
public actor RustChunkIndexSession {
    private var handleId: UInt64?

    public init() {}

    /// Initialize with default configuration (50K capacity for ~1000 papers × 50 chunks)
    public func initialize() async {
        handleId = chunkIndexCreate()
    }

    /// Add a single chunk embedding to the index
    /// - Parameters:
    ///   - chunkId: The chunk identifier
    ///   - publicationId: The parent publication identifier
    ///   - embedding: The embedding vector
    /// - Returns: True if the operation succeeded
    @discardableResult
    public func add(chunkId: String, publicationId: String, embedding: [Float]) async -> Bool {
        guard let id = handleId else { return false }
        return chunkIndexAdd(handle: id, chunkId: chunkId, publicationId: publicationId, embedding: embedding)
    }

    /// Add multiple chunk embeddings at once
    /// - Parameter items: Array of chunk items to add
    /// - Returns: True if the operation succeeded
    @discardableResult
    public func addBatch(_ items: [ChunkIndexItem]) async -> Bool {
        guard let id = handleId else { return false }
        return chunkIndexAddBatch(handle: id, items: items)
    }

    /// Search for similar chunks across the entire index
    /// - Parameters:
    ///   - embedding: The query embedding vector
    ///   - topK: Maximum number of results to return
    /// - Returns: Array of chunk similarity results, sorted by similarity (descending)
    public func search(query embedding: [Float], topK: Int = 10) async -> [ChunkSimilarityResult] {
        guard let id = handleId else { return [] }
        return chunkIndexSearch(handle: id, query: embedding, topK: UInt32(topK))
    }

    /// Search for similar chunks, filtered to specific publications
    /// - Parameters:
    ///   - embedding: The query embedding vector
    ///   - topK: Maximum number of results to return
    ///   - publicationIds: Set of publication IDs to restrict search to
    /// - Returns: Filtered chunk similarity results
    public func searchScoped(
        query embedding: [Float],
        topK: Int = 10,
        publicationIds: [String]
    ) async -> [ChunkSimilarityResult] {
        guard let id = handleId else { return [] }
        return chunkIndexSearchScoped(
            handle: id,
            query: embedding,
            topK: UInt32(topK),
            publicationIds: publicationIds
        )
    }

    /// Get the number of chunks in the index
    public func count() async -> Int {
        guard let id = handleId else { return 0 }
        return Int(chunkIndexSize(handle: id))
    }

    /// Check if the index is initialized
    public var isInitialized: Bool {
        handleId != nil
    }

    /// Close the index and release resources
    public func close() async {
        guard let id = handleId else { return }
        _ = chunkIndexClose(handle: id)
        handleId = nil
    }

    deinit {
        if let id = handleId {
            _ = chunkIndexClose(handle: id)
        }
    }
}
