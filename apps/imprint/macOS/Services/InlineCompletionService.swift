//
//  InlineCompletionService.swift
//  imprint
//
//  Inline text completion service for AI-assisted writing.
//  Provides ghost text suggestions activated by Tab key.
//

import Foundation
import OSLog
import ImpressAI

private let logger = Logger(subsystem: "com.imprint.app", category: "inlineCompletion")

// MARK: - Inline Completion Service

/// Service for inline AI-powered text completions.
///
/// Features:
/// - Ghost text suggestions as user types
/// - Tab to accept completions
/// - Citation suggestions from imbib library
/// - Debounced requests to avoid API spam
@MainActor @Observable
public final class InlineCompletionService {

    // MARK: - Singleton

    public static let shared = InlineCompletionService()

    // MARK: - Published State

    /// Current ghost text suggestion (displayed faded after cursor)
    public private(set) var ghostText: String = ""

    /// Whether a completion request is in progress
    public private(set) var isLoading = false

    /// Whether inline completions are enabled
    public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "ai.inlineCompletions.enabled")
        }
    }

    /// Minimum characters before triggering completion
    public var minTriggerLength: Int {
        didSet {
            UserDefaults.standard.set(minTriggerLength, forKey: "ai.inlineCompletions.minLength")
        }
    }

    /// Debounce delay in milliseconds
    public var debounceDelay: Int {
        didSet {
            UserDefaults.standard.set(debounceDelay, forKey: "ai.inlineCompletions.debounceMs")
        }
    }

    // MARK: - Private State

    private var pendingTask: Task<Void, Never>?
    private var lastRequestedText: String = ""
    private var lastCursorPosition: Int = 0
    private let aiService = AIAssistantService.shared
    private let imbibPort = 23120

    // Cache for recent imbib searches
    private var citationCache: [String: [CitationSuggestion]] = [:]
    private let maxCacheSize = 50

    // MARK: - Initialization

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "ai.inlineCompletions.enabled")
        minTriggerLength = UserDefaults.standard.object(forKey: "ai.inlineCompletions.minLength") as? Int ?? 10
        debounceDelay = UserDefaults.standard.object(forKey: "ai.inlineCompletions.debounceMs") as? Int ?? 500
    }

    // MARK: - Completion API

    /// Request a completion for the current text and cursor position.
    ///
    /// This method debounces requests and cancels pending ones.
    ///
    /// - Parameters:
    ///   - text: Full document text
    ///   - cursorPosition: Current cursor position
    public func requestCompletion(text: String, cursorPosition: Int) {
        guard isEnabled else { return }

        // Cancel any pending request
        pendingTask?.cancel()
        ghostText = ""

        // Don't request if text too short or cursor at start
        guard cursorPosition >= minTriggerLength else { return }

        // Extract context around cursor
        let lineStart = text.lastIndex(of: "\n", before: cursorPosition) ?? 0
        let currentLine = String(text[text.index(text.startIndex, offsetBy: lineStart)..<text.index(text.startIndex, offsetBy: cursorPosition)])
            .trimmingCharacters(in: .whitespaces)

        // Skip if line is empty or just whitespace
        guard currentLine.count >= 5 else { return }

        lastRequestedText = text
        lastCursorPosition = cursorPosition

        // Debounce
        pendingTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(debounceDelay) * 1_000_000)

                // Check if still valid (not cancelled, position unchanged)
                guard !Task.isCancelled else { return }
                guard lastCursorPosition == cursorPosition else { return }

                await generateCompletion(text: text, cursorPosition: cursorPosition)
            } catch {
                // Task cancelled, ignore
            }
        }
    }

    /// Clear any pending completion.
    public func clearCompletion() {
        pendingTask?.cancel()
        ghostText = ""
    }

    /// Accept the current ghost text completion.
    ///
    /// - Returns: The ghost text that was accepted, or nil if none
    public func acceptCompletion() -> String? {
        guard !ghostText.isEmpty else { return nil }
        let accepted = ghostText
        ghostText = ""
        logger.info("Accepted completion: \(accepted.prefix(50))...")
        return accepted
    }

    // MARK: - Citation Suggestions

    /// Request citation suggestions for the text around cursor.
    ///
    /// - Parameters:
    ///   - text: Full document text
    ///   - cursorPosition: Current cursor position
    /// - Returns: Array of citation suggestions
    public func requestCitationSuggestions(text: String, cursorPosition: Int) async -> [CitationSuggestion] {
        // Extract the sentence or phrase around cursor
        let context = extractContext(from: text, at: cursorPosition, windowSize: 200)

        // Check cache first
        let cacheKey = context.prefix(100).description
        if let cached = citationCache[cacheKey] {
            return cached
        }

        // Search imbib for relevant papers
        let keywords = extractKeywords(from: context)
        guard !keywords.isEmpty else { return [] }

        let query = keywords.joined(separator: " ")
        let suggestions = await searchImbibForCitations(query: query)

        // Cache results
        if citationCache.count >= maxCacheSize {
            citationCache.removeAll()
        }
        citationCache[cacheKey] = suggestions

        return suggestions
    }

    // MARK: - Private Methods

    private func generateCompletion(text: String, cursorPosition: Int) async {
        guard await aiService.isConfigured else {
            logger.debug("AI not configured, skipping completion")
            return
        }

        isLoading = true
        defer { isLoading = false }

        // Extract context before cursor
        let contextBefore = extractContext(from: text, at: cursorPosition, windowSize: 500)

        // Check for citation context
        if shouldSuggestCitation(context: contextBefore) {
            await generateCitationCompletion(context: contextBefore)
            return
        }

        // Generate text completion
        await generateTextCompletion(context: contextBefore)
    }

    private func generateTextCompletion(context: String) async {
        let systemPrompt = """
        You are an inline text completion assistant for academic writing.
        Given the text so far, predict the next 10-30 words the author is likely to write.

        Rules:
        - Continue naturally from where the text ends
        - Match the academic tone and style
        - Keep completions concise (1-2 sentences max)
        - Don't repeat what's already written
        - If the context suggests a citation is needed, include @citekey placeholder
        - Return ONLY the completion text, no explanations

        If you cannot provide a meaningful completion, return an empty string.
        """

        do {
            let completion = try await aiService.streamMessage(
                systemPrompt: systemPrompt,
                userMessage: "Complete this text:\n\n\(context)",
                maxTokens: 100
            ).reduce(into: "") { $0 += $1 }

            // Only show if completion is meaningful
            let trimmed = completion.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 5 && trimmed.count <= 200 {
                ghostText = trimmed
                logger.info("Generated completion: \(trimmed.prefix(50))...")
            }
        } catch {
            logger.error("Completion failed: \(error.localizedDescription)")
        }
    }

    private func generateCitationCompletion(context: String) async {
        // Look for citation opportunities
        let suggestions = await requestCitationSuggestions(text: context, cursorPosition: context.count)

        if let best = suggestions.first {
            ghostText = "@\(best.citeKey)"
            logger.info("Suggested citation: @\(best.citeKey)")
        }
    }

    private func shouldSuggestCitation(context: String) -> Bool {
        // Detect patterns that typically need citations
        let citationIndicators = [
            "according to",
            "as shown by",
            "demonstrated that",
            "found that",
            "proposed by",
            "introduced by",
            "as described in",
            "following",
            "building on",
            "extending the work of",
            "similar to",
            "consistent with",
            "in contrast to",
            "unlike",
            "see also",
            "for a review",
            "for details"
        ]

        let lowercased = context.lowercased()
        for indicator in citationIndicators {
            if lowercased.hasSuffix(indicator) || lowercased.hasSuffix(indicator + " ") {
                return true
            }
        }

        // Check if last character suggests citation (after closing quote, period after claim)
        if context.hasSuffix("\"") || context.hasSuffix(").") || context.hasSuffix("].") {
            return true
        }

        return false
    }

    private func extractContext(from text: String, at position: Int, windowSize: Int) -> String {
        let startIndex = max(0, position - windowSize)
        let endIndex = min(text.count, position)

        guard startIndex < endIndex else { return "" }

        let start = text.index(text.startIndex, offsetBy: startIndex)
        let end = text.index(text.startIndex, offsetBy: endIndex)
        return String(text[start..<end])
    }

    private func extractKeywords(from text: String) -> [String] {
        // Extract meaningful words for citation search
        let stopwords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "must", "shall", "can", "need", "to", "of",
            "in", "for", "on", "with", "at", "by", "from", "as", "into", "through",
            "during", "before", "after", "above", "below", "between", "under",
            "and", "but", "or", "nor", "so", "yet", "both", "either", "neither",
            "that", "which", "who", "whom", "whose", "this", "these", "those",
            "it", "its", "they", "their", "them", "we", "our", "us", "you", "your"
        ]

        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) }

        // Return unique keywords, max 5
        return Array(Set(words).prefix(5))
    }

    private func searchImbibForCitations(query: String) async -> [CitationSuggestion] {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://localhost:\(imbibPort)/api/search?q=\(encodedQuery)&limit=5") else {
            return []
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2.0 // Short timeout for inline suggestions

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }

            let searchResponse = try JSONDecoder().decode(ImbibSearchAPIResponse.self, from: data)

            return searchResponse.results.map { paper in
                CitationSuggestion(
                    citeKey: paper.citeKey,
                    title: paper.title,
                    authors: paper.authors,
                    year: paper.year,
                    relevance: 1.0 // Could calculate based on query match
                )
            }
        } catch {
            logger.debug("imbib search failed: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - Supporting Types

/// A citation suggestion from imbib.
public struct CitationSuggestion: Identifiable, Sendable {
    public let id = UUID()
    public let citeKey: String
    public let title: String
    public let authors: String
    public let year: Int?
    public let relevance: Double

    /// Formatted citation for display
    public var formattedCitation: String {
        let authorPart: String
        if authors.contains(",") {
            let firstAuthor = authors.components(separatedBy: ",").first ?? authors
            authorPart = "\(firstAuthor) et al."
        } else {
            authorPart = authors
        }

        if let year = year, year > 0 {
            return "\(authorPart) (\(year))"
        }
        return authorPart
    }
}

/// Response from imbib HTTP search API.
private struct ImbibSearchAPIResponse: Codable {
    let results: [ImbibSearchPaper]
    let total: Int?
}

private struct ImbibSearchPaper: Codable {
    let id: String
    let citeKey: String
    let title: String
    let authors: String
    let year: Int?
    let venue: String?
}

// MARK: - String Extension

private extension String {
    func lastIndex(of character: Character, before position: Int) -> Int? {
        let endIndex = index(startIndex, offsetBy: min(position, count))
        let searchRange = startIndex..<endIndex

        if let found = self[searchRange].lastIndex(of: character) {
            return distance(from: startIndex, to: found)
        }
        return nil
    }
}
