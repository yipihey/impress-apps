//
//  EmbeddingProvider.swift
//  ImpressEmbeddings
//
//  Defines the provider-agnostic embedding protocol.
//  Implementations can use Apple NL, fastembed (Rust), Ollama, OpenAI, etc.
//

import Foundation

// MARK: - Embedding Provider Protocol

/// A provider that generates embedding vectors from text.
///
/// Conforming types must be `Sendable` for use in concurrent pipelines.
/// The protocol is designed for plug-and-play swapping: change the active
/// provider in settings and all embedding operations automatically use it.
///
/// ## Providers
///
/// | Provider | Dimension | Local | Speed | Quality |
/// |----------|-----------|-------|-------|---------|
/// | AppleNL  | 384       | Yes   | ~2ms  | Moderate |
/// | FastEmbed| 384       | Yes   | ~5ms  | Good |
/// | Ollama   | 768       | Yes   | ~20ms | Very good |
/// | OpenAI   | 1536      | No    | ~50ms | Excellent |
public protocol EmbeddingProvider: Sendable {
    /// Unique identifier for this provider, e.g. "apple-nl", "fastembed", "ollama", "openai"
    var id: String { get }

    /// The dimensionality of vectors produced by this provider.
    var embeddingDimension: Int { get }

    /// Whether this provider works without network access.
    var supportsLocal: Bool { get }

    /// Estimated milliseconds per single embedding (for pipeline planning).
    var estimatedMsPerEmbedding: Double { get }

    /// Compute an embedding vector for the given text.
    func embed(_ text: String) async throws -> [Float]

    /// Compute embeddings for multiple texts in batch.
    /// Default implementation calls `embed` sequentially.
    func embedBatch(_ texts: [String]) async throws -> [[Float]]

    /// Compute cosine similarity between two embedding vectors.
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float
}

// MARK: - Default Implementations

public extension EmbeddingProvider {
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            try results.append(await embed(text))
        }
        return results
    }

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }
}

// MARK: - Embedding Errors

public enum EmbeddingError: Error, LocalizedError {
    case providerNotAvailable(String)
    case embeddingFailed(String)
    case dimensionMismatch(expected: Int, got: Int)
    case modelNotLoaded
    case networkRequired

    public var errorDescription: String? {
        switch self {
        case .providerNotAvailable(let reason):
            return "Embedding provider not available: \(reason)"
        case .embeddingFailed(let reason):
            return "Embedding failed: \(reason)"
        case .dimensionMismatch(let expected, let got):
            return "Dimension mismatch: expected \(expected), got \(got)"
        case .modelNotLoaded:
            return "Embedding model not loaded"
        case .networkRequired:
            return "This provider requires network access"
        }
    }
}
