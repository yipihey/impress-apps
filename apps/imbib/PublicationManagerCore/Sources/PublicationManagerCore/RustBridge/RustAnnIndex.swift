//
//  RustAnnIndex.swift
//  PublicationManagerCore
//
//  Swift bridge for Rust Approximate Nearest Neighbor (ANN) index.
//  Provides O(log n) similarity search for embeddings.
//

import Foundation
import ImbibRustCore

// ANN index using Rust HNSW implementation for O(log n) similarity search

// MARK: - ANN Index (Rust-backed)

/// Swift wrapper for Rust ANN index
/// Provides fast O(log n) similarity search for publication embeddings
public actor RustAnnIndex {
    private var handleId: UInt64?

    public init() {}

    /// Initialize with default configuration
    public func initialize() async {
        handleId = annIndexCreate()
    }

    /// Initialize with custom configuration
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

    @discardableResult
    public func add(publicationId: String, embedding: [Float]) async -> Bool {
        guard let id = handleId else { return false }
        return annIndexAdd(handleId: id, publicationId: publicationId, embedding: embedding)
    }

    @discardableResult
    public func addBatch(_ items: [(String, [Float])]) async -> Bool {
        guard let id = handleId else { return false }
        let annItems = items.map { AnnIndexItem(publicationId: $0.0, embedding: $0.1) }
        return annIndexAddBatch(handleId: id, items: annItems)
    }

    public func findSimilar(to embedding: [Float], topK: Int = 10) async -> [SimilarityResult] {
        guard let id = handleId else { return [] }
        let results = annIndexSearch(handleId: id, query: embedding, topK: UInt32(topK))
        return results.map { SimilarityResult(publicationId: $0.publicationId, similarity: $0.similarity) }
    }

    public func count() async -> Int {
        guard let id = handleId else { return 0 }
        return Int(annIndexSize(handleId: id))
    }

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

public enum RustAnnIndexInfo {
    public static var isAvailable: Bool { true }
}
