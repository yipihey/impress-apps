//
//  RustAnnIndexSession.swift
//  PublicationManagerCore
//
//  Actor-based Approximate Nearest Neighbor (ANN) index using Rust HNSW.
//  Provides O(log n) similarity search for publication embeddings.
//

import Foundation
import ImbibRustCore

// MARK: - ANN Index Session (Actor-based)

/// Actor-based ANN index using Rust HNSW implementation.
/// Provides fast O(log n) similarity search for publication embeddings.
public actor RustAnnIndexSession {
    private var handleId: UInt64?

    public init() {}

    /// Initialize with default configuration
    public func initialize() async {
        handleId = annIndexCreate()
    }

    /// Initialize with custom configuration
    /// - Parameters:
    ///   - maxConnections: Maximum number of connections per node (default: 16)
    ///   - capacity: Initial capacity of the index (default: 10000)
    ///   - maxLayer: Maximum layer in the graph (default: 16)
    ///   - efConstruction: Size of dynamic candidate list during construction (default: 200)
    public func initialize(
        maxConnections: UInt32 = 16,
        capacity: UInt32 = 10000,
        maxLayer: UInt32 = 16,
        efConstruction: UInt32 = 200
    ) async {
        handleId = annIndexCreateWithConfig(
            maxConnections: maxConnections,
            capacity: capacity,
            maxLayer: maxLayer,
            efConstruction: efConstruction
        )
    }

    /// Add a single embedding to the index
    /// - Parameters:
    ///   - publicationId: The publication identifier
    ///   - embedding: The embedding vector
    /// - Returns: True if the operation succeeded
    @discardableResult
    public func add(publicationId: String, embedding: [Float]) async -> Bool {
        guard let id = handleId else { return false }
        return annIndexAdd(handleId: id, publicationId: publicationId, embedding: embedding)
    }

    /// Add multiple embeddings to the index in batch
    /// - Parameter items: Array of (publicationId, embedding) pairs
    /// - Returns: True if the operation succeeded
    @discardableResult
    public func addBatch(_ items: [(String, [Float])]) async -> Bool {
        guard let id = handleId else { return false }
        let annItems = items.map { AnnIndexItem(publicationId: $0.0, embedding: $0.1) }
        return annIndexAddBatch(handleId: id, items: annItems)
    }

    /// Find similar publications to the given embedding
    /// - Parameters:
    ///   - embedding: The query embedding vector
    ///   - topK: Maximum number of results to return (default: 10)
    /// - Returns: Array of similarity results, sorted by similarity (descending)
    public func findSimilar(to embedding: [Float], topK: Int = 10) async -> [SimilarityResult] {
        guard let id = handleId else { return [] }
        let results = annIndexSearch(handleId: id, query: embedding, topK: UInt32(topK))
        return results.map { SimilarityResult(publicationId: $0.publicationId, similarity: $0.similarity) }
    }

    /// Get the number of items in the index
    public func count() async -> Int {
        guard let id = handleId else { return 0 }
        return Int(annIndexSize(handleId: id))
    }

    /// Check if the index is initialized
    public var isInitialized: Bool {
        handleId != nil
    }

    /// Close the index and release resources
    public func close() async {
        guard let id = handleId else { return }
        _ = annIndexClose(handleId: id)
        handleId = nil
    }

    deinit {
        if let id = handleId {
            _ = annIndexClose(handleId: id)
        }
    }
}

// MARK: - Similarity Result

/// Result from similarity search
public struct SimilarityResult: Sendable, Identifiable {
    public let id: String
    public let publicationId: String
    public let similarity: Float

    init(publicationId: String, similarity: Float) {
        self.id = publicationId
        self.publicationId = publicationId
        self.similarity = similarity
    }
}

/// Information about Rust ANN index availability
public enum RustAnnIndexInfo {
    public static var isAvailable: Bool { true }
}

// MARK: - Legacy Type Alias

/// Type alias for backwards compatibility
@available(*, deprecated, renamed: "RustAnnIndexSession")
public typealias RustAnnIndex = RustAnnIndexSession
