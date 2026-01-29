//
//  AISearchAssistant.swift
//  PublicationManagerCore
//
//  AI assistant for research tasks in imbib.
//

import Foundation
import ImpressAI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "aiSearchAssistant")

// MARK: - Search Assistant

/// AI assistant for research tasks in imbib.
///
/// Features:
/// - Query expansion: Expand search terms with synonyms and related concepts
/// - Paper summarization: Generate abstract summaries
/// - Paper discovery: Find related papers based on library
/// - BibTeX generation: Generate citations from title/DOI
@MainActor
@Observable
public final class AISearchAssistant {

    /// Shared singleton instance.
    public static let shared = AISearchAssistant()

    private let providerManager: AIProviderManager
    private let categoryManager: AITaskCategoryManager
    private let executor: AIMultiModelExecutor

    /// Whether the assistant is currently processing.
    public private(set) var isProcessing = false

    /// Last error message, if any.
    public var errorMessage: String?

    public init(
        providerManager: AIProviderManager = .shared,
        categoryManager: AITaskCategoryManager = .shared,
        executor: AIMultiModelExecutor = .shared
    ) {
        self.providerManager = providerManager
        self.categoryManager = categoryManager
        self.executor = executor
    }

    // MARK: - Query Expansion

    /// Expand a search query with synonyms and related concepts.
    ///
    /// - Parameter query: The original search query
    /// - Returns: Expanded query with suggestions
    public func expandQuery(_ query: String) async throws -> QueryExpansionResult {
        isProcessing = true
        defer { isProcessing = false }

        let systemPrompt = """
        You are a research assistant helping expand academic search queries.
        Given a search query, suggest:
        1. Synonyms and alternative terms
        2. Related concepts that might be relevant
        3. More specific sub-topics
        4. Broader parent topics

        Format your response as JSON with the following structure:
        {
            "original": "the original query",
            "synonyms": ["synonym1", "synonym2"],
            "related": ["related concept 1", "related concept 2"],
            "specific": ["specific topic 1", "specific topic 2"],
            "broader": ["broader topic 1", "broader topic 2"],
            "suggested_queries": ["full query suggestion 1", "full query suggestion 2"]
        }
        """

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: "Expand this search query: \(query)")],
            systemPrompt: systemPrompt,
            maxTokens: 1000
        )

        do {
            let result = try await executor.executePrimary(request, categoryId: "research.search")

            guard let response = result, let text = response.text else {
                throw AISearchError.noResponse
            }

            // Parse JSON response
            let expansion = try parseQueryExpansion(text, original: query)
            logger.debug("Expanded query: \(query) -> \(expansion.suggestedQueries.count) suggestions")
            return expansion
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Paper Summarization

    /// Generate a summary of a paper.
    ///
    /// - Parameters:
    ///   - title: Paper title
    ///   - abstract: Paper abstract (if available)
    ///   - fullText: Full paper text (if available)
    /// - Returns: Generated summary
    public func summarizePaper(
        title: String,
        abstract: String? = nil,
        fullText: String? = nil
    ) async throws -> PaperSummary {
        isProcessing = true
        defer { isProcessing = false }

        let content: String
        if let fullText = fullText {
            content = "Title: \(title)\n\nFull text:\n\(fullText.prefix(15000))"
        } else if let abstract = abstract {
            content = "Title: \(title)\n\nAbstract:\n\(abstract)"
        } else {
            content = "Title: \(title)"
        }

        let systemPrompt = """
        You are an academic research assistant. Summarize the given paper.
        Provide:
        1. A brief one-paragraph summary (2-3 sentences)
        2. Key findings/contributions (bullet points)
        3. Methodology overview
        4. Relevance/impact

        Format as JSON:
        {
            "brief_summary": "...",
            "key_findings": ["finding 1", "finding 2"],
            "methodology": "...",
            "relevance": "..."
        }
        """

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: content)],
            systemPrompt: systemPrompt,
            maxTokens: 2000
        )

        do {
            let result = try await executor.executePrimary(request, categoryId: "research.summarize")

            guard let response = result, let text = response.text else {
                throw AISearchError.noResponse
            }

            let summary = try parsePaperSummary(text, title: title)
            logger.debug("Summarized paper: \(title)")
            return summary
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Paper Discovery

    /// Find related papers based on a seed paper or topic.
    ///
    /// - Parameters:
    ///   - seedTitle: Title of the seed paper
    ///   - seedAbstract: Abstract of the seed paper
    ///   - existingPapers: Titles of papers already in library (to avoid duplicates)
    /// - Returns: Suggestions for related papers
    public func discoverRelatedPapers(
        seedTitle: String,
        seedAbstract: String? = nil,
        existingPapers: [String] = []
    ) async throws -> [PaperSuggestion] {
        isProcessing = true
        defer { isProcessing = false }

        let existingList = existingPapers.isEmpty ? "None provided" : existingPapers.prefix(20).joined(separator: "\n- ")

        let systemPrompt = """
        You are a research librarian helping find related academic papers.
        Based on the given paper, suggest related papers that might be relevant.

        For each suggestion, provide:
        - Title (as accurate as possible)
        - Authors (if known)
        - Approximate year
        - Why it's relevant

        The user already has these papers (avoid duplicates):
        - \(existingList)

        Format as JSON array:
        [
            {
                "title": "Paper Title",
                "authors": "Author1, Author2",
                "year": 2023,
                "relevance": "Why this paper is relevant"
            }
        ]

        Suggest 5-10 papers. Only suggest real papers you're confident exist.
        """

        var content = "Find papers related to: \(seedTitle)"
        if let abstract = seedAbstract {
            content += "\n\nAbstract: \(abstract)"
        }

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: content)],
            systemPrompt: systemPrompt,
            maxTokens: 2000
        )

        do {
            let result = try await executor.executePrimary(request, categoryId: "research.discover")

            guard let response = result, let text = response.text else {
                throw AISearchError.noResponse
            }

            let suggestions = try parsePaperSuggestions(text)
            logger.debug("Found \(suggestions.count) related paper suggestions")
            return suggestions
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - BibTeX Generation

    /// Generate BibTeX entry from a paper title or DOI.
    ///
    /// - Parameters:
    ///   - title: Paper title
    ///   - doi: Paper DOI (if available)
    ///   - additionalInfo: Any additional information
    /// - Returns: Generated BibTeX entry
    public func generateBibTeX(
        title: String,
        doi: String? = nil,
        additionalInfo: String? = nil
    ) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        let systemPrompt = """
        You are a citation formatting assistant. Generate a BibTeX entry for the given paper.
        Use the @article type unless another type is clearly more appropriate.
        Generate a cite key in the format: LastNameYearFirstWord (e.g., Einstein1905Electrodynamics)
        Include all standard fields: author, title, journal, year, volume, pages, doi.
        If information is unknown, make reasonable assumptions but mark uncertain fields with a comment.
        Return ONLY the BibTeX entry, no explanations.
        """

        var content = "Generate BibTeX for: \(title)"
        if let doi = doi {
            content += "\nDOI: \(doi)"
        }
        if let info = additionalInfo {
            content += "\nAdditional info: \(info)"
        }

        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: content)],
            systemPrompt: systemPrompt,
            maxTokens: 500
        )

        do {
            let result = try await executor.executePrimary(request, categoryId: "citation.format")

            guard let response = result, let text = response.text else {
                throw AISearchError.noResponse
            }

            // Clean up the response
            let bibtex = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```bibtex", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            logger.debug("Generated BibTeX for: \(title)")
            return bibtex
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Parsing Helpers

    private func parseQueryExpansion(_ text: String, original: String) throws -> QueryExpansionResult {
        // Try to extract JSON from the response
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw AISearchError.parseError("Failed to parse response")
        }

        do {
            let decoded = try JSONDecoder().decode(QueryExpansionJSON.self, from: data)
            return QueryExpansionResult(
                originalQuery: original,
                synonyms: decoded.synonyms ?? [],
                relatedConcepts: decoded.related ?? [],
                specificTopics: decoded.specific ?? [],
                broaderTopics: decoded.broader ?? [],
                suggestedQueries: decoded.suggested_queries ?? []
            )
        } catch {
            // Fall back to simple parsing if JSON fails
            return QueryExpansionResult(
                originalQuery: original,
                synonyms: [],
                relatedConcepts: [],
                specificTopics: [],
                broaderTopics: [],
                suggestedQueries: [original]
            )
        }
    }

    private func parsePaperSummary(_ text: String, title: String) throws -> PaperSummary {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw AISearchError.parseError("Failed to parse response")
        }

        do {
            let decoded = try JSONDecoder().decode(PaperSummaryJSON.self, from: data)
            return PaperSummary(
                title: title,
                briefSummary: decoded.brief_summary ?? "",
                keyFindings: decoded.key_findings ?? [],
                methodology: decoded.methodology,
                relevance: decoded.relevance
            )
        } catch {
            // Fall back to using the raw text
            return PaperSummary(
                title: title,
                briefSummary: text,
                keyFindings: [],
                methodology: nil,
                relevance: nil
            )
        }
    }

    private func parsePaperSuggestions(_ text: String) throws -> [PaperSuggestion] {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw AISearchError.parseError("Failed to parse response")
        }

        do {
            let decoded = try JSONDecoder().decode([PaperSuggestionJSON].self, from: data)
            return decoded.map { json in
                PaperSuggestion(
                    title: json.title,
                    authors: json.authors,
                    year: json.year,
                    relevance: json.relevance
                )
            }
        } catch {
            return []
        }
    }

    private func extractJSON(from text: String) -> String {
        // Try to find JSON in the response
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        if let start = text.firstIndex(of: "["),
           let end = text.lastIndex(of: "]") {
            return String(text[start...end])
        }
        return text
    }
}

// MARK: - Result Types

/// Result of query expansion.
public struct QueryExpansionResult: Sendable {
    public let originalQuery: String
    public let synonyms: [String]
    public let relatedConcepts: [String]
    public let specificTopics: [String]
    public let broaderTopics: [String]
    public let suggestedQueries: [String]
}

/// Summary of a paper.
public struct PaperSummary: Sendable {
    public let title: String
    public let briefSummary: String
    public let keyFindings: [String]
    public let methodology: String?
    public let relevance: String?
}

/// Suggestion for a related paper.
public struct PaperSuggestion: Sendable, Identifiable {
    public let title: String
    public let authors: String?
    public let year: Int?
    public let relevance: String?

    public var id: String { title }
}

// MARK: - JSON Decoding Types

private struct QueryExpansionJSON: Decodable {
    let original: String?
    let synonyms: [String]?
    let related: [String]?
    let specific: [String]?
    let broader: [String]?
    let suggested_queries: [String]?
}

private struct PaperSummaryJSON: Decodable {
    let brief_summary: String?
    let key_findings: [String]?
    let methodology: String?
    let relevance: String?
}

private struct PaperSuggestionJSON: Decodable {
    let title: String
    let authors: String?
    let year: Int?
    let relevance: String?
}

// MARK: - Errors

/// Errors that can occur during AI search operations.
public enum AISearchError: LocalizedError {
    case noResponse
    case parseError(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .noResponse:
            return "No response from AI provider"
        case .parseError(let detail):
            return "Failed to parse response: \(detail)"
        case .notConfigured:
            return "AI is not configured. Please add an API key in Settings."
        }
    }
}
