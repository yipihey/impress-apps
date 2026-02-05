//
//  SemanticEmbeddingProvider.swift
//  ImpressAI
//
//  Provides semantic text embeddings using Apple's NaturalLanguage framework.
//  Uses NLEmbedding for word embeddings and aggregates to sentence-level.
//

import Foundation
import NaturalLanguage
import OSLog

// MARK: - Embedding Provider Protocol

/// Protocol for text embedding providers.
public protocol EmbeddingProvider: Sendable {
    /// The dimension of the embedding vectors produced by this provider.
    var embeddingDimension: Int { get }

    /// Compute an embedding vector for the given text.
    ///
    /// - Parameter text: The text to embed
    /// - Returns: A fixed-size vector representing the text's semantic content
    func embed(_ text: String) async -> [Float]

    /// Compute embeddings for multiple texts in batch.
    ///
    /// - Parameter texts: The texts to embed
    /// - Returns: Array of embedding vectors
    func embedBatch(_ texts: [String]) async -> [[Float]]

    /// Compute cosine similarity between two embedding vectors.
    ///
    /// - Parameters:
    ///   - a: First embedding vector
    ///   - b: Second embedding vector
    /// - Returns: Similarity score in [-1, 1] range (1 = identical, 0 = orthogonal)
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float
}

// MARK: - Default Implementation

public extension EmbeddingProvider {
    func embedBatch(_ texts: [String]) async -> [[Float]] {
        var results: [[Float]] = []
        for text in texts {
            results.append(await embed(text))
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

// MARK: - Apple NaturalLanguage Embedding Provider

/// Embedding provider using Apple's NaturalLanguage framework.
///
/// Uses word embeddings from `NLEmbedding` and aggregates them to create
/// sentence-level embeddings. This provides better semantic understanding
/// than simple bag-of-words approaches.
///
/// ## Embedding Strategy
///
/// 1. Tokenize text into words
/// 2. Look up each word's embedding vector
/// 3. Apply TF-IDF-style weighting (rare words get higher weight)
/// 4. Average weighted embeddings to get sentence vector
/// 5. Normalize to unit vector
///
/// ## Language Support
///
/// Apple's embeddings support English and several other languages.
/// Falls back to hash-based embeddings for unsupported languages.
public actor AppleNLEmbeddingProvider: EmbeddingProvider {

    // MARK: - Properties

    public nonisolated let embeddingDimension: Int

    private var wordEmbedding: NLEmbedding?
    private let language: NLLanguage
    private let logger = Logger(subsystem: "com.impressai", category: "Embeddings")

    // Word frequency for IDF weighting
    private var documentFrequency: [String: Int] = [:]
    private var totalDocuments: Int = 0

    // Cache for word embeddings to avoid repeated lookups
    private var wordEmbeddingCache: [String: [Float]] = [:]
    private let maxCacheSize = 10000

    // MARK: - Initialization

    /// Create an embedding provider for the specified language.
    ///
    /// - Parameter language: The language for embeddings (default: English)
    public init(language: NLLanguage = .english) {
        self.language = language

        // Apple's word embeddings are 512-dimensional for English
        // Use 384 to match common sentence transformer dimensions
        self.embeddingDimension = 384

        // Load embedding synchronously during init (NLEmbedding is thread-safe)
        let lang = language
        if let embedding = NLEmbedding.wordEmbedding(for: lang) {
            self.wordEmbedding = embedding
            logger.info("Loaded word embedding for \(lang.rawValue)")
        } else {
            logger.warning("No word embedding available for \(lang.rawValue), will use hash-based fallback")
        }
    }

    // MARK: - EmbeddingProvider

    public nonisolated func embed(_ text: String) async -> [Float] {
        await embedInternal(text)
    }

    private func embedInternal(_ text: String) -> [Float] {
        // Tokenize
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text.lowercased()

        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).lowercased()
            if token.count >= 2 {
                tokens.append(token)
            }
            return true
        }

        guard !tokens.isEmpty else {
            return [Float](repeating: 0, count: embeddingDimension)
        }

        // Get embeddings for each word
        var wordVectors: [[Float]] = []
        var weights: [Float] = []

        for token in tokens {
            if let vector = getWordEmbedding(token) {
                wordVectors.append(vector)
                // Simple IDF-style weight: rare words matter more
                let idf = log(Float(max(totalDocuments, 1)) / Float(documentFrequency[token] ?? 1) + 1)
                weights.append(idf)
            }
        }

        // If no word embeddings found, fall back to hash-based
        if wordVectors.isEmpty {
            return hashBasedEmbedding(text)
        }

        // Weighted average of word embeddings
        var result = [Float](repeating: 0, count: embeddingDimension)
        var totalWeight: Float = 0

        for (vector, weight) in zip(wordVectors, weights) {
            for i in 0..<min(vector.count, embeddingDimension) {
                result[i] += vector[i] * weight
            }
            totalWeight += weight
        }

        if totalWeight > 0 {
            result = result.map { $0 / totalWeight }
        }

        // Normalize to unit vector
        let norm = sqrt(result.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            result = result.map { $0 / norm }
        }

        return result
    }

    public nonisolated func embedBatch(_ texts: [String]) async -> [[Float]] {
        await embedBatchInternal(texts)
    }

    private func embedBatchInternal(_ texts: [String]) -> [[Float]] {
        texts.map { embedInternal($0) }
    }

    // MARK: - Word Frequency Tracking

    /// Update word frequency statistics for better IDF weighting.
    ///
    /// Call this when adding documents to the corpus to improve embedding quality.
    public func updateFrequencies(from texts: [String]) {
        for text in texts {
            let words = extractWords(from: text)
            let uniqueWords = Set(words)
            for word in uniqueWords {
                documentFrequency[word, default: 0] += 1
            }
            totalDocuments += 1
        }
    }

    /// Clear word frequency statistics.
    public func clearFrequencies() {
        documentFrequency.removeAll()
        totalDocuments = 0
    }

    // MARK: - Private Methods

    private func getWordEmbedding(_ word: String) -> [Float]? {
        // Check cache
        if let cached = wordEmbeddingCache[word] {
            return cached
        }

        // Look up from NLEmbedding
        guard let embedding = wordEmbedding,
              let vector = embedding.vector(for: word) else {
            return nil
        }

        // Convert [Double] to [Float] and resize to target dimension
        var floatVector = vector.map { Float($0) }

        // Pad or truncate to target dimension
        if floatVector.count < embeddingDimension {
            floatVector.append(contentsOf: [Float](repeating: 0, count: embeddingDimension - floatVector.count))
        } else if floatVector.count > embeddingDimension {
            floatVector = Array(floatVector.prefix(embeddingDimension))
        }

        // Cache result
        if wordEmbeddingCache.count < maxCacheSize {
            wordEmbeddingCache[word] = floatVector
        }

        return floatVector
    }

    private func extractWords(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text.lowercased()

        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            if word.count >= 2 {
                words.append(word)
            }
            return true
        }
        return words
    }

    /// Fallback hash-based embedding when word embeddings aren't available.
    private func hashBasedEmbedding(_ text: String) -> [Float] {
        var embedding = [Float](repeating: 0.0, count: embeddingDimension)

        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        for word in words {
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
}

// MARK: - Shared Instance

public extension AppleNLEmbeddingProvider {
    /// Shared instance for English embeddings.
    static let shared = AppleNLEmbeddingProvider(language: .english)
}
