//
//  NLSearchService.swift
//  PublicationManagerCore
//
//  Translates natural language search descriptions into ADS/SciX query syntax
//  using Apple's on-device Foundation Models framework with tool calling.
//
//  The on-device LLM autonomously selects the right sciX operation:
//  - search_papers: topic/author/year queries → ADS query string
//  - get_citations: "papers citing X" → citation network traversal
//  - get_references: "what does X cite" → reference list
//  - get_similar: "papers like X" → content similarity
//  - get_coreads: "what else do readers of X read" → co-read discovery
//  - count_results: preview query specificity
//

import Foundation
import ImpressScixCore
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - NL Search State

/// State of a natural language search translation
public enum NLSearchState: Sendable, Equatable {
    case idle
    case thinking
    case translated(query: String, interpretation: String, estimatedCount: UInt32?)
    case searching
    case complete(query: String, resultCount: Int)
    case error(String)

    public var isWorking: Bool {
        switch self {
        case .thinking, .searching: return true
        default: return false
        }
    }
}

// MARK: - NL Search Result Type

/// The type of operation the model chose to perform
public enum NLSearchResultType: Sendable, Equatable {
    /// A standard ADS query search
    case querySearch(query: String)
    /// A bibcode-based operation (citations, references, similar, coreads)
    case bibcodeOperation(bibcodes: [String], operation: String, sourceBibcode: String)
}

// MARK: - NL Search Service

/// Service that uses Apple Foundation Models to translate natural language into ADS queries.
///
/// Uses guided generation with tool calling so the on-device LLM autonomously
/// selects the right sciX operation (search, citations, similar, coreads, etc.)
/// based on the user's natural language request.
///
/// The session is cached for conversational refinement — follow-up prompts like
/// "narrow to refereed only" refine the previous query using session transcript memory.
///
/// Requires macOS 26+ with Apple Intelligence enabled.
@Observable
public final class NLSearchService: @unchecked Sendable {

    // MARK: - Properties

    public private(set) var state: NLSearchState = .idle
    public private(set) var lastNaturalLanguageInput: String = ""
    public private(set) var lastGeneratedQuery: String = ""
    public private(set) var lastInterpretation: String = ""
    public private(set) var lastResultType: NLSearchResultType?
    public private(set) var estimatedCount: UInt32?

    /// Number of turns in the current conversation (for refinement tracking)
    public private(set) var conversationTurnCount: Int = 0

    // MARK: - Session Cache

    #if canImport(FoundationModels)
    /// Cached Foundation Models session for conversational refinement.
    /// The session maintains a transcript so follow-up prompts like
    /// "narrow to refereed only" work in context.
    @available(macOS 26, iOS 26, *)
    private var _cachedSession: LanguageModelSession?

    @available(macOS 26, iOS 26, *)
    private var cachedSession: LanguageModelSession? {
        get { _cachedSession }
        set { _cachedSession = newValue }
    }
    #endif

    // MARK: - Initialization

    public init() {}

    // MARK: - Availability

    /// Whether the on-device Foundation Models framework is available
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return true
        }
        #endif
        return false
    }

    // MARK: - Translation

    /// Translate a natural language description into an ADS/SciX query string.
    ///
    /// Uses the on-device Foundation Models LLM with tool calling. The model
    /// autonomously selects the right sciX operation based on user intent.
    ///
    /// The session is cached, so follow-up calls refine the previous query
    /// using conversation context (e.g., "narrow to refereed only").
    ///
    /// - Parameter naturalLanguage: The user's natural language search description
    /// - Returns: The generated ADS query string, or nil if translation failed
    @MainActor
    public func translate(_ naturalLanguage: String) async -> String? {
        guard !naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        lastNaturalLanguageInput = naturalLanguage
        state = .thinking

        Logger.viewModels.infoCapture(
            "NLSearch: translating '\(naturalLanguage)' (turn \(conversationTurnCount + 1))",
            category: "nlsearch"
        )

        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return await translateWithFoundationModels(naturalLanguage)
        }
        #endif

        // Fallback: simple keyword extraction for older OS
        let query = fallbackTranslation(naturalLanguage)
        lastGeneratedQuery = query
        lastInterpretation = "Basic keyword search (Apple Intelligence not available)"
        lastResultType = .querySearch(query: query)
        state = .translated(query: query, interpretation: lastInterpretation, estimatedCount: nil)
        return query
    }

    // MARK: - Foundation Models Translation

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    @MainActor
    private func translateWithFoundationModels(_ naturalLanguage: String) async -> String? {
        do {
            // Get or create session (cached for conversational refinement)
            let session = try await getOrCreateSession()

            // Use tool-calling: the model picks search_papers, get_citations, etc.
            let userPrompt: String
            if conversationTurnCount == 0 {
                userPrompt = """
                Translate this search request into an ADS query by calling the search_papers tool:

                "\(naturalLanguage)"
                """
            } else {
                // Follow-up refinement — the session has context from previous turns
                userPrompt = """
                Refine the previous search based on this:

                "\(naturalLanguage)"

                Call search_papers with the updated query.
                """
            }

            let response = try await session.respond(to: userPrompt)
            conversationTurnCount += 1

            // Parse the tool response to extract query and interpretation
            let responseText = response.content
            let (query, interpretation) = parseToolResponse(responseText)

            guard !query.isEmpty else {
                state = .error("Model returned empty query")
                return nil
            }

            lastGeneratedQuery = query
            lastInterpretation = interpretation
            lastResultType = .querySearch(query: query)

            Logger.viewModels.infoCapture(
                "NLSearch: translated to '\(query)' — \(interpretation)",
                category: "nlsearch"
            )

            // Fetch count preview in background
            let capturedQuery = query
            estimatedCount = nil
            Task.detached { [weak self] in
                guard let apiKey = await CredentialManager.shared.apiKey(for: "ads") else { return }
                let count = try? scixCount(token: apiKey, query: capturedQuery)
                await MainActor.run {
                    self?.estimatedCount = count
                    if let count {
                        self?.state = .translated(
                            query: capturedQuery,
                            interpretation: interpretation,
                            estimatedCount: count
                        )
                    }
                }
            }

            state = .translated(query: query, interpretation: interpretation, estimatedCount: nil)
            return query
        } catch {
            let message = error.localizedDescription
            state = .error(message)
            Logger.viewModels.errorCapture(
                "NLSearch: Foundation Models error: \(message)",
                category: "nlsearch"
            )
            return nil
        }
    }

    @available(macOS 26, iOS 26, *)
    private func getOrCreateSession() async throws -> LanguageModelSession {
        if let session = cachedSession {
            return session
        }

        // Get API token for sciX tools
        let apiToken = await CredentialManager.shared.apiKey(for: "ads")

        let session: LanguageModelSession
        if let token = apiToken {
            // Full tool-calling session with sciX tools
            let tools = NLSearchToolFactory.makeTools(apiToken: token)
            session = LanguageModelSession(
                instructions: Self.adsQuerySystemPrompt,
                tools: tools
            )
        } else {
            // No API key — session without tools, just query generation
            session = LanguageModelSession(
                instructions: Self.adsQuerySystemPrompt
            )
        }

        cachedSession = session
        return session
    }

    /// Parse the tool response text to extract query and interpretation.
    /// Tool responses come in format: "Query: ...\nInterpretation: ...\n..."
    private func parseToolResponse(_ text: String) -> (query: String, interpretation: String) {
        var query = ""
        var interpretation = ""

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Query: ") {
                query = String(trimmed.dropFirst("Query: ".count))
            } else if trimmed.hasPrefix("Interpretation: ") {
                interpretation = String(trimmed.dropFirst("Interpretation: ".count))
            }
        }

        // If structured parsing fails, try to use the whole response as a query
        if query.isEmpty {
            query = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if interpretation.isEmpty {
                interpretation = describeQuery(query)
            }
        }

        if interpretation.isEmpty {
            interpretation = describeQuery(query)
        }

        return (query, interpretation)
    }
    #endif

    // MARK: - System Prompt

    /// Comprehensive system prompt teaching ADS query syntax.
    /// Used as session instructions for Foundation Models.
    static let adsQuerySystemPrompt = """
    You are an expert at NASA ADS (Astrophysics Data System) / SciX search queries. \
    Your job is to translate natural language descriptions of papers into precise ADS query strings \
    by calling the search_papers tool.

    ADS Query Syntax Reference:
    - author:"Last, First" or author:"Last" — search by author name
    - first_author:"Last" — first author only
    - title:"words" — search in title
    - abs:"words" — search in abstract
    - year:YYYY — exact year
    - year:YYYY-YYYY — year range
    - object:"name" — astronomical object (e.g., "M31", "NGC 1234")
    - property:refereed — only refereed (peer-reviewed) papers
    - property:eprint_openaccess — open access preprints
    - doctype:article — journal articles only
    - bibcode:XXXX — specific bibcode
    - doi:XXXX — specific DOI
    - arXiv:XXXX — arXiv identifier
    - citations(bibcode:XXXX) — papers that cite a specific paper
    - references(bibcode:XXXX) — papers cited by a specific paper
    - similar(bibcode:XXXX) — similar papers

    Boolean operators: AND, OR, NOT (uppercase)
    Grouping: use parentheses for complex queries
    Wildcards: * for prefix matching (e.g., author:"Ein*")

    Rules:
    1. Always call the search_papers tool — never reply with plain text
    2. Always use field qualifiers (author:, abs:, title:, year:, etc.)
    3. Multi-word values MUST be quoted: abs:"dark matter"
    4. Multiple authors: author:"Last1" AND author:"Last2" or author:("Last1" "Last2")
    5. When the user says "recent" or "last N years", calculate from 2026
    6. When the user mentions a specific topic, use abs: for the most relevant keywords
    7. When the user says "refereed" or "published" or "peer-reviewed", add property:refereed
    8. Prefer abs: over title: for topic searches (broader match)
    9. Keep queries concise — don't over-constrain
    10. For vague descriptions, use the most specific terms available
    11. For follow-up requests like "narrow to refereed", modify the previous query
    12. If the user mentions citations, similar papers, or co-reads, use the appropriate tool instead

    For citation/reference/similar/co-read requests, use the corresponding tool \
    (get_citations, get_references, get_similar, get_coreads) when you know the bibcode. \
    If you don't know the bibcode, use search_papers first to find it.
    """

    // MARK: - Query Description

    /// Generate a human-readable description of what an ADS query searches for.
    /// Used as fallback when the model doesn't provide an interpretation.
    private func describeQuery(_ query: String) -> String {
        var parts: [String] = []

        // Extract author
        if let range = query.range(of: #"author:"([^"]+)""#, options: .regularExpression) {
            let author = query[range].replacingOccurrences(of: "author:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parts.append("by \(author)")
        } else if let range = query.range(of: #"first_author:"([^"]+)""#, options: .regularExpression) {
            let author = query[range].replacingOccurrences(of: "first_author:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parts.append("first author \(author)")
        }

        // Extract topic from abs:
        if let range = query.range(of: #"abs:"([^"]+)""#, options: .regularExpression) {
            let topic = query[range].replacingOccurrences(of: "abs:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parts.append("about \(topic)")
        }

        // Extract year
        if let range = query.range(of: #"year:(\d{4}(?:-\d{4})?)"#, options: .regularExpression) {
            let year = query[range].replacingOccurrences(of: "year:", with: "")
            parts.append("from \(year)")
        }

        // Extract refereed
        if query.contains("property:refereed") {
            parts.append("refereed only")
        }

        if parts.isEmpty {
            return "Custom ADS query"
        }

        return "Papers " + parts.joined(separator: ", ")
    }

    // MARK: - Fallback Translation

    /// Simple keyword-based translation for when Foundation Models is unavailable
    private func fallbackTranslation(_ naturalLanguage: String) -> String {
        let words = naturalLanguage.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var queryParts: [String] = []
        var i = 0

        while i < words.count {
            let word = words[i]

            // Detect "by Author" pattern
            if word == "by" && i + 1 < words.count {
                let author = words[i + 1].capitalized
                queryParts.append("author:\"\(author)\"")
                i += 2
                continue
            }

            // Detect year patterns
            if let year = Int(word), year >= 1900 && year <= 2100 {
                // Check for range: "2020-2024" or "2020 to 2024"
                if i + 2 < words.count && (words[i + 1] == "to" || words[i + 1] == "-") {
                    if let endYear = Int(words[i + 2]), endYear >= 1900 && endYear <= 2100 {
                        queryParts.append("year:\(year)-\(endYear)")
                        i += 3
                        continue
                    }
                }
                queryParts.append("year:\(year)")
                i += 1
                continue
            }

            // Detect "since YYYY" or "after YYYY"
            if (word == "since" || word == "after") && i + 1 < words.count {
                if let year = Int(words[i + 1]), year >= 1900 && year <= 2100 {
                    queryParts.append("year:\(year)-2026")
                    i += 2
                    continue
                }
            }

            // Detect "recent" / "last N years"
            if word == "recent" || word == "latest" {
                queryParts.append("year:2022-2026")
                i += 1
                continue
            }
            if word == "last" && i + 2 < words.count && words[i + 2] == "years" {
                if let n = Int(words[i + 1]) {
                    queryParts.append("year:\(2026 - n)-2026")
                    i += 3
                    continue
                }
            }

            // Skip common filler words
            let skipWords: Set<String> = [
                "papers", "articles", "about", "on", "the", "a", "an", "and", "or",
                "in", "with", "for", "from", "that", "which", "published", "find",
                "search", "looking", "look"
            ]
            if skipWords.contains(word) {
                i += 1
                continue
            }

            // Detect refereed/peer-reviewed
            if word == "refereed" || word == "peer-reviewed" {
                queryParts.append("property:refereed")
                i += 1
                continue
            }

            // Remaining words go into abstract search
            // Collect consecutive topic words
            var topicWords: [String] = [word]
            while i + 1 < words.count && !skipWords.contains(words[i + 1])
                    && Int(words[i + 1]) == nil && words[i + 1] != "by" {
                i += 1
                topicWords.append(words[i])
            }

            if topicWords.count > 1 {
                queryParts.append("abs:\"\(topicWords.joined(separator: " "))\"")
            } else {
                queryParts.append("abs:\"\(topicWords[0])\"")
            }

            i += 1
        }

        return queryParts.joined(separator: " ")
    }

    // MARK: - State Management

    /// Reset to idle state and clear the cached session (start fresh conversation)
    @MainActor
    public func reset() {
        state = .idle
        lastNaturalLanguageInput = ""
        lastGeneratedQuery = ""
        lastInterpretation = ""
        lastResultType = nil
        estimatedCount = nil
        conversationTurnCount = 0

        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            cachedSession = nil
        }
        #endif
    }

    /// Update state to indicate search is executing
    @MainActor
    public func markSearching() {
        state = .searching
    }

    /// Update state to indicate search completed with results
    @MainActor
    public func markComplete(resultCount: Int) {
        state = .complete(query: lastGeneratedQuery, resultCount: resultCount)
        Logger.viewModels.infoCapture(
            "NLSearch: complete, \(resultCount) results for '\(lastGeneratedQuery)'",
            category: "nlsearch"
        )
    }
}
