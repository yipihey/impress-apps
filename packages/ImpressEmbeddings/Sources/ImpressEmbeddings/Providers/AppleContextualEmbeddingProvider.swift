//
//  AppleContextualEmbeddingProvider.swift
//  ImpressEmbeddings
//
//  Embedding provider using Apple's NLContextualEmbedding (macOS 14+/iOS 17+).
//  Produces context-aware sentence-level embeddings by averaging token vectors
//  from a transformer model — semantically richer than word-level aggregation.
//

import Foundation
import NaturalLanguage
import OSLog

private let logger = Logger(subsystem: "com.impress.embeddings", category: "AppleContextual")

// MARK: - Apple Contextual Embedding Provider

/// Embedding provider using NLContextualEmbedding for sentence-level transformer embeddings.
///
/// Unlike `NLEmbedding.wordEmbedding` which aggregates individual word vectors,
/// `NLContextualEmbedding` uses a transformer model that considers surrounding context,
/// producing semantically richer representations for semantic search.
///
/// Dimension is 512 for the English model on macOS 14+.
/// Requires model assets to be available (downloaded on-device by the OS).
@available(macOS 14, iOS 17, *)
public actor AppleContextualEmbeddingProvider: EmbeddingProvider {

    // MARK: - EmbeddingProvider conformance (nonisolated constants)

    public nonisolated let id = "apple-contextual"
    public nonisolated let embeddingDimension: Int = 512
    public nonisolated let supportsLocal = true
    public nonisolated let estimatedMsPerEmbedding: Double = 10.0

    // MARK: - Private state

    private var embedding: NLContextualEmbedding?

    // MARK: - Initialization

    public init() {}

    // MARK: - EmbeddingProvider

    public func embed(_ text: String) async throws -> [Float] {
        try await ensureLoaded()

        guard let model = embedding else {
            throw EmbeddingError.modelNotLoaded
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [Float](repeating: 0, count: embeddingDimension)
        }

        let result = try model.embeddingResult(for: trimmed, language: .english)

        // Collect token-level vectors and average them → sentence-level embedding
        var tokenVectors: [[Double]] = []
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            if !vector.isEmpty {
                tokenVectors.append(vector)
            }
            return true
        }

        guard !tokenVectors.isEmpty else {
            return [Float](repeating: 0, count: embeddingDimension)
        }

        let dim = tokenVectors[0].count
        var averaged = [Double](repeating: 0.0, count: dim)
        for vec in tokenVectors {
            for i in 0..<min(dim, vec.count) {
                averaged[i] += vec[i]
            }
        }
        let count = Double(tokenVectors.count)
        averaged = averaged.map { $0 / count }

        // Normalize to unit vector
        let norm = sqrt(averaged.reduce(0.0) { $0 + $1 * $1 })
        if norm > 0 {
            averaged = averaged.map { $0 / norm }
        }

        return averaged.map { Float($0) }
    }

    // MARK: - Private

    private func ensureLoaded() async throws {
        guard embedding == nil else { return }

        guard let model = NLContextualEmbedding(language: .english) else {
            throw EmbeddingError.providerNotAvailable("NLContextualEmbedding(language: .english) returned nil")
        }

        // Download assets if not already on device
        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else {
                throw EmbeddingError.providerNotAvailable("NLContextualEmbedding assets unavailable (result: \(result))")
            }
        }

        // Load the model into memory
        try model.load()

        self.embedding = model
        logger.info("AppleContextualEmbeddingProvider loaded (dimension: \(model.dimension))")
    }
}
