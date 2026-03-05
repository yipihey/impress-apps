//
//  NLSearchService.swift
//  PublicationManagerCore
//
//  Translates natural language search descriptions into ADS/SciX query syntax
//  using Apple's on-device Foundation Models framework.
//

import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - NL Search State

/// State of a natural language search translation
public enum NLSearchState: Sendable, Equatable {
    case idle
    case thinking
    case translated(query: String, interpretation: String)
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

// MARK: - NL Search Service

/// Service that uses Apple Foundation Models to translate natural language into ADS queries.
///
/// The service uses guided generation to produce structured output containing both
/// the ADS query string and a human-readable interpretation of what was understood.
///
/// Requires macOS 26+ with Apple Intelligence enabled.
@Observable
public final class NLSearchService: @unchecked Sendable {

    // MARK: - Properties

    public private(set) var state: NLSearchState = .idle
    public private(set) var lastNaturalLanguageInput: String = ""
    public private(set) var lastGeneratedQuery: String = ""
    public private(set) var lastInterpretation: String = ""

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
    /// Uses the on-device Foundation Models LLM with guided generation to produce
    /// a structured ADS query. The model understands astronomy terminology and
    /// ADS query syntax fields.
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
            "NLSearch: translating '\(naturalLanguage)'",
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
        state = .translated(query: query, interpretation: lastInterpretation)
        return query
    }

    // MARK: - Foundation Models Translation

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    @MainActor
    private func translateWithFoundationModels(_ naturalLanguage: String) async -> String? {
        do {
            let session = LanguageModelSession(
                instructions: Self.adsQuerySystemPrompt
            )

            let userPrompt = """
            Translate this natural language search into an ADS query:

            "\(naturalLanguage)"

            Reply with ONLY the ADS query string. No explanation, no quotes, just the query.
            """

            let response = try await session.respond(to: userPrompt)

            let query = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            guard !query.isEmpty else {
                state = .error("Model returned empty query")
                return nil
            }

            lastGeneratedQuery = query
            lastInterpretation = describeQuery(query)
            state = .translated(query: query, interpretation: lastInterpretation)

            Logger.viewModels.infoCapture(
                "NLSearch: translated to '\(query)'",
                category: "nlsearch"
            )

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
    #endif

    // MARK: - System Prompt

    /// Comprehensive system prompt teaching ADS query syntax
    static let adsQuerySystemPrompt = """
    You are an expert at NASA ADS (Astrophysics Data System) / SciX search queries. \
    Your job is to translate natural language descriptions of papers into precise ADS query strings.

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
    1. Always use field qualifiers (author:, abs:, title:, year:, etc.)
    2. Multi-word values MUST be quoted: abs:"dark matter"
    3. Multiple authors: author:"Last1" AND author:"Last2" or author:("Last1" "Last2")
    4. When the user says "recent" or "last N years", calculate from 2026
    5. When the user mentions a specific topic, use abs: for the most relevant keywords
    6. When the user says "refereed" or "published" or "peer-reviewed", add property:refereed
    7. Prefer abs: over title: for topic searches (broader match)
    8. Keep queries concise — don't over-constrain
    9. For vague descriptions, use the most specific terms available
    10. Output ONLY the query string, nothing else
    """

    // MARK: - Query Description

    /// Generate a human-readable description of what an ADS query searches for
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

    /// Reset to idle state
    @MainActor
    public func reset() {
        state = .idle
        lastNaturalLanguageInput = ""
        lastGeneratedQuery = ""
        lastInterpretation = ""
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
