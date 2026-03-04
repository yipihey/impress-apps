//
//  RAGOrchestrator.swift
//  ImpressEmbeddings
//
//  Retrieval-Augmented Generation: query → embed → retrieve → assemble → generate.
//  Domain-aware: understands scholarly metadata, cites with BibTeX keys.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.impress.embeddings", category: "RAG")

// MARK: - Search Scope

/// Scope for RAG queries — which papers to search.
public enum SearchScope: Sendable {
    /// Search the entire library.
    case library
    /// Search a specific collection.
    case collection(UUID)
    /// Search specific publications only.
    case papers([UUID])
}

// MARK: - Source Reference

/// A cited source in a RAG response.
public struct SourceReference: Sendable {
    public let publicationId: UUID
    public let bibkey: String
    public let title: String
    public let authors: String
    public let year: String?
    public let chunkText: String
    public let pageNumber: Int?
    public let similarity: Float

    public init(
        publicationId: UUID, bibkey: String, title: String, authors: String,
        year: String?, chunkText: String, pageNumber: Int?, similarity: Float
    ) {
        self.publicationId = publicationId
        self.bibkey = bibkey
        self.title = title
        self.authors = authors
        self.year = year
        self.chunkText = chunkText
        self.pageNumber = pageNumber
        self.similarity = similarity
    }
}

// MARK: - RAG Response

/// Complete response from a RAG query.
public struct RAGResponse: Sendable {
    /// The generated answer with [bibkey] citations.
    public let answer: String
    /// Cited sources with metadata and chunk text.
    public let sources: [SourceReference]
    /// The original question.
    public let question: String
    /// The LLM model used for generation.
    public let model: String
    /// The embedding model used for retrieval.
    public let embeddingModel: String
    /// Milliseconds spent on retrieval (embed + search).
    public let retrievalTimeMs: Int
    /// Milliseconds spent on LLM generation.
    public let generationTimeMs: Int

    public init(
        answer: String, sources: [SourceReference], question: String,
        model: String, embeddingModel: String,
        retrievalTimeMs: Int, generationTimeMs: Int
    ) {
        self.answer = answer
        self.sources = sources
        self.question = question
        self.model = model
        self.embeddingModel = embeddingModel
        self.retrievalTimeMs = retrievalTimeMs
        self.generationTimeMs = generationTimeMs
    }
}

// MARK: - Retrieval Result (pre-generation)

/// Retrieved chunks with metadata, ready for context assembly.
/// This intermediate result allows callers to inspect retrieval before generation.
public struct RetrievalResult: Sendable {
    public let question: String
    public let queryEmbedding: [Float]
    public let sources: [SourceReference]
    public let retrievalTimeMs: Int
    public let embeddingModel: String

    public init(question: String, queryEmbedding: [Float], sources: [SourceReference], retrievalTimeMs: Int, embeddingModel: String) {
        self.question = question
        self.queryEmbedding = queryEmbedding
        self.sources = sources
        self.retrievalTimeMs = retrievalTimeMs
        self.embeddingModel = embeddingModel
    }
}

// MARK: - Context Assembly

/// Assembles retrieved chunks into an LLM-ready context string.
///
/// Format designed for scholarly domain:
/// ```
/// Source [AuthorYear]: "Title"
/// Page: N
/// ---
/// {chunk text}
/// ===
/// ```
public struct ContextAssembler {

    /// Assemble sources into a formatted context string for the LLM.
    public static func assemble(_ sources: [SourceReference], maxTokens: Int = 8000) -> String {
        var context = ""
        var estimatedTokens = 0

        for source in sources {
            let entry = formatSource(source)
            let entryTokens = entry.count / 4 // rough estimate: 4 chars per token

            if estimatedTokens + entryTokens > maxTokens { break }

            context += entry + "\n\n"
            estimatedTokens += entryTokens
        }

        return context
    }

    /// Build the system prompt for scholarly RAG.
    public static func systemPrompt() -> String {
        """
        You are a research assistant helping a scholar understand their paper collection.

        Rules:
        - Answer using ONLY information from the provided paper excerpts.
        - Cite papers using their BibTeX keys in square brackets, e.g. [Smith2024].
        - If multiple papers support a claim, cite all of them: [Smith2024, Jones2023].
        - If the excerpts don't contain enough information to answer, say so explicitly.
        - Be precise and scholarly in tone.
        - When comparing papers, organize by methodology, findings, or chronology.
        - Use markdown formatting for structure (headers, lists, bold).
        """
    }

    /// Build the user message combining question and context.
    public static func userMessage(question: String, context: String) -> String {
        """
        ## Paper Excerpts

        \(context)

        ## Question

        \(question)
        """
    }

    private static func formatSource(_ source: SourceReference) -> String {
        var header = "Source [\(source.bibkey)]: \"\(source.title)\""
        header += "\nAuthors: \(source.authors)"
        if let year = source.year {
            header += " (\(year))"
        }
        if let page = source.pageNumber {
            header += "\nPage: \(page + 1)" // Convert 0-indexed to 1-indexed for display
        }
        header += "\nRelevance: \(String(format: "%.0f%%", source.similarity * 100))"
        header += "\n---\n"
        header += source.chunkText
        header += "\n==="
        return header
    }
}
