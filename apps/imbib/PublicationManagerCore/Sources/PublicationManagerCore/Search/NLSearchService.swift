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
/// based on the user's natural language request, then returns a structured
/// `ADSQueryResult` via constrained decoding.
///
/// The session is cached for conversational refinement — follow-up prompts like
/// "narrow to refereed only" refine the previous query using session transcript memory.
///
/// Requires macOS 26+ with Apple Intelligence enabled.
@Observable
@MainActor
public final class NLSearchService {

    // MARK: - Properties

    public private(set) var state: NLSearchState = .idle
    public private(set) var lastNaturalLanguageInput: String = ""
    public private(set) var lastGeneratedQuery: String = ""
    public private(set) var lastInterpretation: String = ""
    public private(set) var lastResultType: NLSearchResultType?
    public private(set) var estimatedCount: UInt32?

    /// Number of turns in the current conversation (for refinement tracking)
    public private(set) var conversationTurnCount: Int = 0

    /// User-configurable max results (passed through to search pipeline)
    public var maxResults: Int = 0

    /// User-selected source IDs (default ADS, can include arXiv, OpenAlex, etc.)
    public var selectedSourceIDs: Set<String> = ["ads"]

    /// Whether to restrict to refereed/peer-reviewed papers
    public var refereedOnly: Bool = false

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

    /// Whether the on-device Foundation Models framework is available AND
    /// Apple Intelligence is enabled on this device.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
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
    private func translateWithFoundationModels(_ naturalLanguage: String) async -> String? {
        do {
            // Get or create session (cached for conversational refinement)
            let session = try await getOrCreateSession()

            // Build the prompt with any user-selected constraints
            var constraints: [String] = []
            if refereedOnly { constraints.append("Only include refereed (peer-reviewed) papers.") }

            let constraintClause = constraints.isEmpty ? "" : "\n\nConstraints: \(constraints.joined(separator: " "))"

            let userPrompt: String
            if conversationTurnCount == 0 {
                userPrompt = """
                Translate this search request into an ADS query by calling the search_papers tool:

                "\(naturalLanguage)"\(constraintClause)
                """
            } else {
                // Follow-up refinement — the session has context from previous turns
                userPrompt = """
                Refine the previous search based on this:

                "\(naturalLanguage)"\(constraintClause)

                Call search_papers with the updated query.
                """
            }

            // Use guided generation: tools execute, then the model returns a structured ADSQueryResult.
            // session.respond(to:generating:) returns a GeneratedContent<ADSQueryResult>
            // whose .content is the typed result.
            let response = try await session.respond(
                to: userPrompt,
                generating: ADSQueryResult.self
            )
            conversationTurnCount += 1

            // Guided generation guarantees structured output via .content
            let result = response.content
            let query = result.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let interpretation = result.interpretation.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !query.isEmpty else {
                state = .error("Model returned empty query")
                return nil
            }

            // Append refereed filter if user toggled it and model didn't include it
            let finalQuery: String
            if refereedOnly && !query.contains("property:refereed") {
                finalQuery = "\(query) property:refereed"
            } else {
                finalQuery = query
            }

            lastGeneratedQuery = finalQuery
            lastInterpretation = interpretation.isEmpty ? describeQuery(finalQuery) : interpretation
            lastResultType = .querySearch(query: finalQuery)

            Logger.viewModels.infoCapture(
                "NLSearch: translated to '\(finalQuery)' — \(lastInterpretation)",
                category: "nlsearch"
            )

            // Set state first, then fetch count in background (avoids race where
            // the background task completes before this line and gets overwritten)
            estimatedCount = nil
            state = .translated(query: finalQuery, interpretation: lastInterpretation, estimatedCount: nil)

            // Fetch count preview in background
            let capturedQuery = finalQuery
            let capturedInterpretation = lastInterpretation
            Task.detached { [weak self] in
                guard let apiKey = await CredentialManager.shared.apiKey(for: "ads") else { return }
                do {
                    let count = try scixCount(token: apiKey, query: capturedQuery)
                    await MainActor.run {
                        self?.estimatedCount = count
                        // Only update state if still showing this query's translation
                        if case .translated(let q, _, _) = self?.state, q == capturedQuery {
                            self?.state = .translated(
                                query: capturedQuery,
                                interpretation: capturedInterpretation,
                                estimatedCount: count
                            )
                        }
                    }
                } catch {
                    Logger.viewModels.warningCapture(
                        "NLSearch: count preview failed: \(error.localizedDescription)",
                        category: "nlsearch"
                    )
                }
            }

            return finalQuery
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
                tools: tools,
                instructions: Self.adsQuerySystemPrompt
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

    /// Prewarm the Foundation Models session in the background.
    /// Call after the startup grace period (90s) to avoid cold-start latency on first Cmd+S.
    @available(macOS 26, iOS 26, *)
    public func prewarm() {
        Task { [weak self] in
            _ = try? await self?.getOrCreateSession()
        }
    }
    #endif

    // MARK: - System Prompt

    /// Current year for dynamic query generation
    private static var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    /// Comprehensive system prompt teaching ADS query syntax.
    /// Used as session instructions for Foundation Models.
    static var adsQuerySystemPrompt: String {
        let year = currentYear
        return """
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
        1. Always call the search_papers tool to validate and count results
        2. Always use field qualifiers (author:, abs:, title:, year:, etc.)
        3. Multi-word values MUST be quoted: abs:"dark matter"
        4. Multiple authors: author:"Last1" AND author:"Last2" or author:("Last1" "Last2")
        5. When the user says "recent" or "last N years", calculate from \(year)
        6. When the user mentions a specific topic, use abs: for the most relevant keywords
        7. When the user says "refereed" or "published" or "peer-reviewed", add property:refereed
        8. Prefer abs: over title: for topic searches (broader match)
        9. Keep queries concise — don't over-constrain
        10. For vague descriptions, use the most specific terms available
        11. For follow-up requests like "narrow to refereed", modify the previous query
        12. If the user mentions citations of a paper and you know the bibcode, use citations(bibcode:XXXX) syntax
        13. If the user mentions similar papers, use similar(bibcode:XXXX) syntax
        14. If the user mentions references of a paper, use references(bibcode:XXXX) syntax

        For citation/reference/similar requests, use ADS operator syntax in the query field: \
        citations(bibcode:XXXX), references(bibcode:XXXX), similar(bibcode:XXXX). \
        Use the get_citations, get_references, get_similar, get_coreads tools to explore \
        the citation network and gather bibcodes, then construct a query using those bibcodes.
        """
    }

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
            let thisYear = Self.currentYear
            if (word == "since" || word == "after") && i + 1 < words.count {
                if let year = Int(words[i + 1]), year >= 1900 && year <= 2100 {
                    queryParts.append("year:\(year)-\(thisYear)")
                    i += 2
                    continue
                }
            }

            // Detect "recent" / "last N years"
            if word == "recent" || word == "latest" {
                queryParts.append("year:\(thisYear - 4)-\(thisYear)")
                i += 1
                continue
            }
            if word == "last" && i + 2 < words.count && words[i + 2] == "years" {
                if let n = Int(words[i + 1]) {
                    queryParts.append("year:\(thisYear - n)-\(thisYear)")
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

    /// Reset to idle state and clear the cached session (start fresh conversation).
    /// Use this when the user explicitly clears the search or starts over.
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

    /// Start a new conversation while preserving the last results.
    /// Used when the overlay closes — keeps recent results visible but resets the session
    /// so the next search starts fresh.
    public func startNewConversation() {
        conversationTurnCount = 0

        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            cachedSession = nil
        }
        #endif
    }

    /// Update state to indicate search is executing
    public func markSearching() {
        state = .searching
    }

    /// Update state to indicate search completed with results
    public func markComplete(resultCount: Int) {
        state = .complete(query: lastGeneratedQuery, resultCount: resultCount)
        Logger.viewModels.infoCapture(
            "NLSearch: complete, \(resultCount) results for '\(lastGeneratedQuery)'",
            category: "nlsearch"
        )
    }
}
