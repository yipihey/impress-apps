//
//  RustEmbeddingStoreSession.swift
//  PublicationManagerCore
//
//  Actor-based SQLite embedding store using Rust.
//  Persists embedding vectors and text chunks across app launches.
//

import Foundation
import ImbibRustCore

// MARK: - Embedding Store Session (Actor-based)

/// Actor-based embedding persistence using Rust SQLite store.
/// Stores computed embedding vectors and document chunks so they survive across launches.
public actor RustEmbeddingStoreSession {
    private var handleId: UInt64?

    public init() {}

    /// Open or create an embedding store at the given path
    /// - Parameter path: Path to the SQLite database file
    /// - Returns: True if the store was opened successfully
    @discardableResult
    public func open(at path: String) async -> Bool {
        let handle = embeddingStoreOpen(path: path)
        if handle > 0 {
            handleId = handle
            return true
        }
        return false
    }

    /// Open at the default location in Application Support
    @discardableResult
    public func openDefault() async -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("imbib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("embeddings.sqlite").path
        return await open(at: path)
    }

    // MARK: - Vector Operations

    /// Save embedding vectors (upserts by id)
    /// - Returns: Number of vectors saved
    @discardableResult
    public func saveVectors(_ vectors: [StoredVector]) async -> Int {
        guard let id = handleId else { return 0 }
        return Int(embeddingStoreSaveVectors(handle: id, vectors: vectors))
    }

    /// Get all vectors for a given source entity
    public func getVectors(sourceId: String) async -> [StoredVector] {
        guard let id = handleId else { return [] }
        return embeddingStoreGetVectors(handle: id, sourceId: sourceId)
    }

    /// Load all vectors (for rebuilding HNSW index at startup)
    public func loadAllVectors() async -> [StoredVector] {
        guard let id = handleId else { return [] }
        return embeddingStoreLoadAllVectors(handle: id)
    }

    /// Load vectors filtered by source type ("publication" or "chunk")
    public func loadVectorsByType(_ sourceType: String) async -> [StoredVector] {
        guard let id = handleId else { return [] }
        return embeddingStoreLoadVectorsByType(handle: id, sourceType: sourceType)
    }

    /// Delete all vectors for a source entity
    @discardableResult
    public func deleteBySource(_ sourceId: String) async -> Int {
        guard let id = handleId else { return 0 }
        return Int(embeddingStoreDeleteBySource(handle: id, sourceId: sourceId))
    }

    /// Delete all vectors for a given model (used when switching providers)
    @discardableResult
    public func deleteByModel(_ model: String) async -> Int {
        guard let id = handleId else { return 0 }
        return Int(embeddingStoreDeleteByModel(handle: id, model: model))
    }

    // MARK: - Chunk Operations

    /// Save text chunks (upserts by id)
    /// - Returns: Number of chunks saved
    @discardableResult
    public func saveChunks(_ chunks: [StoredChunk]) async -> Int {
        guard let id = handleId else { return 0 }
        return Int(embeddingStoreSaveChunks(handle: id, chunks: chunks))
    }

    /// Get all chunks for a publication
    public func getChunks(publicationId: String) async -> [StoredChunk] {
        guard let id = handleId else { return [] }
        return embeddingStoreGetChunks(handle: id, publicationId: publicationId)
    }

    /// Get a single chunk by ID
    public func getChunk(chunkId: String) async -> StoredChunk? {
        guard let id = handleId else { return nil }
        return embeddingStoreGetChunk(handle: id, chunkId: chunkId)
    }

    // MARK: - Statistics

    /// Total vector count
    public func vectorCount() async -> Int {
        guard let id = handleId else { return 0 }
        return Int(embeddingStoreVectorCount(handle: id))
    }

    /// Total chunk count
    public func chunkCount() async -> Int {
        guard let id = handleId else { return 0 }
        return Int(embeddingStoreChunkCount(handle: id))
    }

    /// Number of publications with chunks
    public func chunkedPublicationCount() async -> Int {
        guard let id = handleId else { return 0 }
        return Int(embeddingStoreChunkedPublicationCount(handle: id))
    }

    /// Get per-model statistics
    public func modelStats() async -> [ModelStats] {
        guard let id = handleId else { return [] }
        return embeddingStoreModelStats(handle: id)
    }

    // MARK: - Maintenance

    /// Clear all data (used when switching providers entirely)
    @discardableResult
    public func clearAll() async -> Bool {
        guard let id = handleId else { return false }
        return embeddingStoreClear(handle: id)
    }

    /// Close the store and release resources
    public func close() async {
        guard let id = handleId else { return }
        _ = embeddingStoreClose(handle: id)
        handleId = nil
    }

    /// Check if the store is open
    public var isOpen: Bool {
        handleId != nil
    }

    deinit {
        if let id = handleId {
            _ = embeddingStoreClose(handle: id)
        }
    }
}
