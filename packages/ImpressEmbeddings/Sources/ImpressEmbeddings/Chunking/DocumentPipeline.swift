//
//  DocumentPipeline.swift
//  ImpressEmbeddings
//
//  End-to-end pipeline: PDF → text → chunks → embeddings → store + index.
//  Runs in the background, reports progress, handles errors gracefully.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.impress.embeddings", category: "Pipeline")

// MARK: - Processing Status

/// Status of document processing for a publication.
public enum ProcessingStatus: Sendable {
    case unprocessed
    case processing
    case complete(chunkCount: Int, model: String)
    case failed(String)
}

// MARK: - Pipeline Result

/// Result of processing a single publication.
public struct PipelineResult: Sendable {
    public let publicationId: UUID
    public let chunkCount: Int
    public let embeddingModel: String
    public let extractionTimeMs: Int
    public let chunkingTimeMs: Int
    public let embeddingTimeMs: Int
    public let totalTimeMs: Int
}

// MARK: - Document Pipeline

/// Orchestrates the full document processing pipeline.
///
/// ## Pipeline Stages
/// 1. **Extract**: `PDFTextExtractor` → page text
/// 2. **Chunk**: `TextChunker` → overlapping chunks with metadata
/// 3. **Embed**: `EmbeddingProvider.embedBatch()` → vectors
/// 4. **Return**: chunks + vectors for caller to store and index
///
/// The pipeline does NOT own storage or indexing — the calling app (imbib)
/// handles persistence via its Rust bridge. This keeps the package reusable
/// across apps (imprint could use it for manuscript sections).
///
/// ## Usage
/// ```swift
/// let pipeline = DocumentPipeline(provider: registry.activeProvider!)
/// let result = try await pipeline.processDocument(
///     publicationId: pubId,
///     pdfURL: pdfUrl
/// )
/// // Store result.chunks and result.embeddings via Rust bridge
/// ```
public actor DocumentPipeline {

    private let provider: any EmbeddingProvider
    private let chunkerConfig: TextChunker.Config
    private var processingSet: Set<UUID> = []

    public init(
        provider: any EmbeddingProvider,
        chunkerConfig: TextChunker.Config = .init()
    ) {
        self.provider = provider
        self.chunkerConfig = chunkerConfig
    }

    // MARK: - Public API

    /// Result of processing a single document.
    public struct DocumentResult: Sendable {
        public let publicationId: UUID
        public let chunks: [ChunkWithMetadata]
        public let embeddings: [[Float]]
        public let model: String
        public let stats: PipelineResult
    }

    /// Process a single publication's PDF through the full pipeline.
    ///
    /// - Parameters:
    ///   - publicationId: The publication UUID.
    ///   - pdfURL: File URL of the PDF.
    /// - Returns: Chunks and their embeddings, ready for storage.
    public func processDocument(
        publicationId: UUID,
        pdfURL: URL
    ) async throws -> DocumentResult {
        guard !processingSet.contains(publicationId) else {
            throw EmbeddingError.embeddingFailed("Publication \(publicationId) is already being processed")
        }

        processingSet.insert(publicationId)
        defer { processingSet.remove(publicationId) }

        let totalStart = DispatchTime.now()

        // Stage 1: Extract text from PDF
        let extractStart = DispatchTime.now()
        let pages = PDFTextExtractor.extract(from: pdfURL)
        let extractionMs = millisSince(extractStart)

        guard !pages.isEmpty else {
            logger.warning("No text extracted from PDF: \(pdfURL.lastPathComponent)")
            throw EmbeddingError.embeddingFailed("No text could be extracted from the PDF")
        }

        logger.info("Extracted \(pages.count) pages in \(extractionMs)ms")

        // Stage 2: Chunk the text
        let chunkStart = DispatchTime.now()
        let chunks = TextChunker.chunkPages(pages.map { (page: $0.page, text: $0.text) }, publicationId: publicationId, config: chunkerConfig)
        let chunkingMs = millisSince(chunkStart)

        guard !chunks.isEmpty else {
            logger.warning("No chunks produced from extracted text")
            throw EmbeddingError.embeddingFailed("Text chunking produced no chunks")
        }

        logger.info("Produced \(chunks.count) chunks in \(chunkingMs)ms")

        // Stage 3: Embed all chunks
        let embedStart = DispatchTime.now()
        let texts = chunks.map(\.text)
        let embeddings = try await provider.embedBatch(texts)
        let embeddingMs = millisSince(embedStart)

        logger.info("Embedded \(embeddings.count) chunks in \(embeddingMs)ms using \(self.provider.id)")

        let totalMs = millisSince(totalStart)

        let stats = PipelineResult(
            publicationId: publicationId,
            chunkCount: chunks.count,
            embeddingModel: provider.id,
            extractionTimeMs: extractionMs,
            chunkingTimeMs: chunkingMs,
            embeddingTimeMs: embeddingMs,
            totalTimeMs: totalMs
        )

        return DocumentResult(
            publicationId: publicationId,
            chunks: chunks,
            embeddings: embeddings,
            model: provider.id,
            stats: stats
        )
    }

    /// Check if a publication is currently being processed.
    public func isProcessing(_ publicationId: UUID) -> Bool {
        processingSet.contains(publicationId)
    }

    // MARK: - Helpers

    private func millisSince(_ start: DispatchTime) -> Int {
        let end = DispatchTime.now()
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Int(nanos / 1_000_000)
    }
}
