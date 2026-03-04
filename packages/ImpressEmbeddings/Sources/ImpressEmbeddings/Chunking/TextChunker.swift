//
//  TextChunker.swift
//  ImpressEmbeddings
//
//  Splits text into overlapping chunks suitable for embedding and RAG retrieval.
//  Respects paragraph boundaries when possible for more coherent chunks.
//

import Foundation

// MARK: - Chunk Metadata

/// A text chunk with its source location metadata.
public struct ChunkWithMetadata: Sendable {
    /// The chunk text content.
    public let text: String
    /// Parent publication ID.
    public let publicationId: UUID
    /// Page number in the source PDF (0-indexed), if known.
    public let pageNumber: Int?
    /// Character offset within the source text.
    public let charOffset: Int
    /// Character length of the chunk.
    public let charLength: Int
    /// Sequential index of this chunk within the publication (0, 1, 2, ...).
    public let chunkIndex: Int

    public init(text: String, publicationId: UUID, pageNumber: Int?, charOffset: Int, charLength: Int, chunkIndex: Int) {
        self.text = text
        self.publicationId = publicationId
        self.pageNumber = pageNumber
        self.charOffset = charOffset
        self.charLength = charLength
        self.chunkIndex = chunkIndex
    }
}

// MARK: - Text Chunker

/// Splits text into overlapping chunks for embedding.
///
/// ## Strategy
/// 1. Split text into paragraphs (double newline boundaries)
/// 2. Accumulate paragraphs until reaching `chunkSize` words
/// 3. When threshold reached, emit a chunk and start a new one with `overlap` words of overlap
/// 4. If a single paragraph exceeds `chunkSize`, split at word boundaries
///
/// Word-based splitting (not token-based) for simplicity — typical sentence transformer
/// tokenizers produce ~1.3x more tokens than words, so 512 words ≈ 665 tokens.
public struct TextChunker {

    public struct Config: Sendable {
        /// Target chunk size in words.
        public var chunkSize: Int
        /// Number of words to overlap between consecutive chunks.
        public var overlap: Int
        /// Whether to prefer splitting at paragraph boundaries.
        public var respectParagraphs: Bool

        public init(chunkSize: Int = 512, overlap: Int = 64, respectParagraphs: Bool = true) {
            self.chunkSize = chunkSize
            self.overlap = overlap
            self.respectParagraphs = respectParagraphs
        }
    }

    /// Split text into overlapping chunks with metadata.
    ///
    /// - Parameters:
    ///   - text: The full text to chunk.
    ///   - publicationId: The parent publication's ID.
    ///   - pageNumber: The page number (if text comes from a single page).
    ///   - config: Chunking configuration.
    /// - Returns: Array of chunks with metadata.
    public static func chunk(
        text: String,
        publicationId: UUID,
        pageNumber: Int? = nil,
        config: Config = .init()
    ) -> [ChunkWithMetadata] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if config.respectParagraphs {
            return chunkByParagraph(trimmed, publicationId: publicationId, pageNumber: pageNumber, config: config)
        } else {
            return chunkByWords(trimmed, publicationId: publicationId, pageNumber: pageNumber, config: config)
        }
    }

    /// Chunk multi-page text, preserving page boundaries in metadata.
    ///
    /// - Parameters:
    ///   - pages: Array of (pageNumber, pageText) pairs.
    ///   - publicationId: The parent publication's ID.
    ///   - config: Chunking configuration.
    /// - Returns: Array of chunks with page-accurate metadata.
    public static func chunkPages(
        _ pages: [(page: Int, text: String)],
        publicationId: UUID,
        config: Config = .init()
    ) -> [ChunkWithMetadata] {
        // Concatenate all pages with page markers for offset tracking
        var allChunks: [ChunkWithMetadata] = []
        var globalChunkIndex = 0
        var globalCharOffset = 0

        for (page, pageText) in pages {
            let pageChunks = chunk(
                text: pageText,
                publicationId: publicationId,
                pageNumber: page,
                config: config
            )

            for var c in pageChunks {
                allChunks.append(ChunkWithMetadata(
                    text: c.text,
                    publicationId: publicationId,
                    pageNumber: page,
                    charOffset: globalCharOffset + c.charOffset,
                    charLength: c.charLength,
                    chunkIndex: globalChunkIndex
                ))
                globalChunkIndex += 1
            }

            globalCharOffset += pageText.count
        }

        return allChunks
    }

    // MARK: - Private Chunking Implementations

    private static func chunkByParagraph(
        _ text: String,
        publicationId: UUID,
        pageNumber: Int?,
        config: Config
    ) -> [ChunkWithMetadata] {
        // Split into paragraphs (double newline or more)
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [ChunkWithMetadata] = []
        var currentWords: [String] = []
        var currentCharOffset = 0
        var chunkStartOffset = 0
        var chunkIndex = 0

        for paragraph in paragraphs {
            let paragraphWords = paragraph.split(separator: " ").map(String.init)

            // If adding this paragraph would exceed chunk size, emit current chunk
            if !currentWords.isEmpty && currentWords.count + paragraphWords.count > config.chunkSize {
                let chunkText = currentWords.joined(separator: " ")
                chunks.append(ChunkWithMetadata(
                    text: chunkText,
                    publicationId: publicationId,
                    pageNumber: pageNumber,
                    charOffset: chunkStartOffset,
                    charLength: chunkText.count,
                    chunkIndex: chunkIndex
                ))
                chunkIndex += 1

                // Keep overlap words for next chunk
                let overlapWords = Array(currentWords.suffix(config.overlap))
                currentWords = overlapWords
                chunkStartOffset = currentCharOffset - overlapWords.joined(separator: " ").count
            }

            // If a single paragraph is larger than chunk size, split it by words
            if paragraphWords.count > config.chunkSize {
                let subChunks = splitLargeParagraph(
                    paragraphWords,
                    publicationId: publicationId,
                    pageNumber: pageNumber,
                    startOffset: currentCharOffset,
                    startIndex: chunkIndex,
                    config: config,
                    prefixWords: currentWords
                )
                chunks.append(contentsOf: subChunks)
                chunkIndex += subChunks.count
                currentWords = Array(paragraphWords.suffix(config.overlap))
                chunkStartOffset = currentCharOffset + paragraph.count - currentWords.joined(separator: " ").count
            } else {
                if currentWords.isEmpty {
                    chunkStartOffset = currentCharOffset
                }
                currentWords.append(contentsOf: paragraphWords)
            }

            currentCharOffset += paragraph.count + 2 // +2 for "\n\n"
        }

        // Emit remaining words
        if !currentWords.isEmpty {
            let chunkText = currentWords.joined(separator: " ")
            chunks.append(ChunkWithMetadata(
                text: chunkText,
                publicationId: publicationId,
                pageNumber: pageNumber,
                charOffset: chunkStartOffset,
                charLength: chunkText.count,
                chunkIndex: chunkIndex
            ))
        }

        return chunks
    }

    private static func splitLargeParagraph(
        _ words: [String],
        publicationId: UUID,
        pageNumber: Int?,
        startOffset: Int,
        startIndex: Int,
        config: Config,
        prefixWords: [String]
    ) -> [ChunkWithMetadata] {
        var chunks: [ChunkWithMetadata] = []
        var currentWords = prefixWords
        var offset = startOffset
        var idx = startIndex

        for word in words {
            currentWords.append(word)

            if currentWords.count >= config.chunkSize {
                let chunkText = currentWords.joined(separator: " ")
                chunks.append(ChunkWithMetadata(
                    text: chunkText,
                    publicationId: publicationId,
                    pageNumber: pageNumber,
                    charOffset: offset,
                    charLength: chunkText.count,
                    chunkIndex: idx
                ))
                idx += 1
                offset += chunkText.count - Array(currentWords.suffix(config.overlap)).joined(separator: " ").count
                currentWords = Array(currentWords.suffix(config.overlap))
            }
        }

        if !currentWords.isEmpty {
            let chunkText = currentWords.joined(separator: " ")
            chunks.append(ChunkWithMetadata(
                text: chunkText,
                publicationId: publicationId,
                pageNumber: pageNumber,
                charOffset: offset,
                charLength: chunkText.count,
                chunkIndex: idx
            ))
        }

        return chunks
    }

    private static func chunkByWords(
        _ text: String,
        publicationId: UUID,
        pageNumber: Int?,
        config: Config
    ) -> [ChunkWithMetadata] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }

        var chunks: [ChunkWithMetadata] = []
        var start = 0
        var chunkIndex = 0

        while start < words.count {
            let end = min(start + config.chunkSize, words.count)
            let chunkWords = Array(words[start..<end])
            let chunkText = chunkWords.joined(separator: " ")

            // Approximate char offset
            let charOffset = words[0..<start].joined(separator: " ").count + (start > 0 ? 1 : 0)

            chunks.append(ChunkWithMetadata(
                text: chunkText,
                publicationId: publicationId,
                pageNumber: pageNumber,
                charOffset: charOffset,
                charLength: chunkText.count,
                chunkIndex: chunkIndex
            ))

            chunkIndex += 1
            start = end - config.overlap
            if start >= end { break } // Prevent infinite loop at end
        }

        return chunks
    }
}
