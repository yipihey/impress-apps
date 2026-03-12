//
//  SmartQueryTranslator.swift
//  PublicationManagerCore
//
//  Deterministic natural language → ADS query translator.
//  Combines pattern matching from the former fallbackTranslation() with
//  optional synonym expansion from VagueMemoryQueryBuilder.
//  All output is normalized via ADSQueryNormalizer.
//

import Foundation

// MARK: - Smart Query Translator

/// Translates natural language search descriptions into ADS query syntax
/// using deterministic pattern matching. No LLM required.
///
/// Translation priority:
/// 1. ADS passthrough — input already has field qualifiers
/// 2. DOI passthrough — `10.XXXX/...`
/// 3. arXiv ID — `YYMM.NNNNN`
/// 4. Bibcode — `2023ApJ...`
/// 5. NL parsing — extract authors, years, refereed, topic words
/// 6. Optional synonym expansion via VagueMemoryQueryBuilder dictionary
/// 7. ADSQueryNormalizer as final pass
public enum SmartQueryTranslator {

    // MARK: - Result

    public struct Result {
        /// The generated ADS query string
        public let query: String
        /// Human-readable interpretation of the query
        public let interpretation: String
    }

    // MARK: - Current Year

    private static var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    // MARK: - Public API

    /// Translate natural language to an ADS query.
    ///
    /// - Parameters:
    ///   - input: The user's natural language search description
    ///   - expandSynonyms: When true, topic words are expanded using the astronomy synonym dictionary
    ///   - refereedOnly: When true, appends `property:refereed` if not already present
    /// - Returns: A `Result` with the query and interpretation, or nil if input is empty
    public static func translate(
        _ input: String,
        expandSynonyms: Bool = false,
        refereedOnly: Bool = false
    ) -> Result? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. ADS passthrough — if input has field qualifiers, normalize and return
        if hasFieldQualifiers(trimmed) {
            return passthroughResult(trimmed, refereedOnly: refereedOnly)
        }

        // 2. DOI passthrough
        if let match = trimmed.firstMatch(of: #/\b10\.\d{4,}\/\S+\b/#) {
            let query = applyRefereed("doi:\(match.output)", refereedOnly: refereedOnly)
            return normalizedResult(query: query, interpretation: "DOI lookup")
        }

        // 3. arXiv ID
        if let match = trimmed.firstMatch(of: #/\b\d{4}\.\d{4,5}\b/#) {
            let query = applyRefereed("identifier:\(match.output)", refereedOnly: refereedOnly)
            return normalizedResult(query: query, interpretation: "arXiv paper lookup")
        }

        // 4. Bibcode
        if let match = trimmed.firstMatch(of: #/\b\d{4}[A-Za-z&]{2,7}[\.\d]+[A-Z]\b/#) {
            let query = applyRefereed("bibcode:\(match.output)", refereedOnly: refereedOnly)
            return normalizedResult(query: query, interpretation: "Bibcode lookup")
        }

        // 5. NL parsing
        let parsed = parseNaturalLanguage(trimmed, expandSynonyms: expandSynonyms)
        var query = parsed.query

        // Apply refereed filter
        query = applyRefereed(query, refereedOnly: refereedOnly)

        // Generate interpretation
        let interpretation = describeQuery(query)

        return normalizedResult(query: query, interpretation: interpretation)
    }

    // MARK: - ADS Query Detection

    /// Known ADS field qualifiers
    private static let adsFieldQualifiers: Set<String> = [
        "author", "first_author", "title", "abs", "abstract",
        "year", "bibcode", "doi", "arxiv", "orcid",
        "aff", "affiliation", "full", "object", "body",
        "keyword", "property", "doctype", "collection", "bibstem",
        "arxiv_class", "identifier", "citations", "references",
        "similar", "trending", "reviews", "useful",
        "author_count", "citation_count", "read_count", "database",
        // Shorthand aliases
        "a", "t", "b"
    ]

    /// Detect whether the input is already an ADS query.
    private static func hasFieldQualifiers(_ text: String) -> Bool {
        for field in adsFieldQualifiers {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: field)):"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        // Functional operators: citations(...), references(...)
        let funcPattern = "\\b(citations|references|similar|trending|reviews|useful)\\("
        if let regex = try? NSRegularExpression(pattern: funcPattern, options: .caseInsensitive),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return true
        }
        return false
    }

    // MARK: - Passthrough

    private static func passthroughResult(_ adsQuery: String, refereedOnly: Bool) -> Result {
        var query = adsQuery
        query = applyRefereed(query, refereedOnly: refereedOnly)

        let normalized = ADSQueryNormalizer.normalize(query)
        let interpretationParts = ["Direct ADS query"] + normalized.corrections
        let interpretation = interpretationParts.joined(separator: " · ")

        return Result(query: normalized.correctedQuery, interpretation: interpretation)
    }

    // MARK: - Natural Language Parsing

    private struct ParsedQuery {
        let query: String
    }

    private static func parseNaturalLanguage(_ text: String, expandSynonyms: Bool) -> ParsedQuery {
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var queryParts: [String] = []
        var i = 0

        let skipWords: Set<String> = [
            "papers", "articles", "about", "on", "the", "a", "an", "and", "or",
            "in", "with", "for", "from", "that", "which", "published", "find",
            "search", "looking", "look"
        ]
        let stopAtWords: Set<String> = [
            "by", "refereed", "peer-reviewed",
            "since", "after", "recent", "latest", "last"
        ]

        let thisYear = currentYear

        while i < words.count {
            let word = words[i]

            // "by FirstName LastName" or "by LastName"
            if word == "by" && i + 1 < words.count {
                let nextWord = words[i + 1]
                // Two-word author: "by FirstName LastName"
                if i + 2 < words.count {
                    let afterNext = words[i + 2]
                    let isAfterNextYear = Int(afterNext).map { (1900...2100).contains($0) } ?? false
                    if !skipWords.contains(nextWord) && !skipWords.contains(afterNext)
                        && !isAfterNextYear && !stopAtWords.contains(afterNext) {
                        let lastName = afterNext.capitalized
                        let firstInitial = nextWord.prefix(1).uppercased()
                        queryParts.append("author:\"\(lastName), \(firstInitial)\"")
                        i += 3
                        continue
                    }
                }
                // Single-word author
                queryParts.append("author:\"\(nextWord.capitalized)\"")
                i += 2
                continue
            }

            // Hyphenated year range: "2020-2024"
            let hyphenParts = word.split(separator: "-")
            if hyphenParts.count == 2,
               let startYear = Int(hyphenParts[0]), (1900...2100).contains(startYear),
               let endYear = Int(hyphenParts[1]), (1900...2100).contains(endYear) {
                queryParts.append("year:\(startYear)-\(endYear)")
                i += 1
                continue
            }

            // Decade: "1970s" → year:1968-1982
            if let decadeMatch = word.firstMatch(of: #/^(\d{4})s$/#) {
                if let decadeStart = Int(String(decadeMatch.output.1)) {
                    let bufferedStart = decadeStart - 2
                    let bufferedEnd = decadeStart + 12
                    queryParts.append("year:\(bufferedStart)-\(bufferedEnd)")
                    i += 1
                    continue
                }
            }

            // Standalone year or "YYYY to YYYY" / "YYYY - YYYY"
            if let year = Int(word), (1900...2100).contains(year) {
                if i + 2 < words.count && (words[i + 1] == "to" || words[i + 1] == "-") {
                    if let endYear = Int(words[i + 2]), (1900...2100).contains(endYear) {
                        queryParts.append("year:\(year)-\(endYear)")
                        i += 3
                        continue
                    }
                }
                queryParts.append("year:\(year)")
                i += 1
                continue
            }

            // "since YYYY" / "after YYYY"
            if (word == "since" || word == "after") && i + 1 < words.count {
                if let year = Int(words[i + 1]), (1900...2100).contains(year) {
                    queryParts.append("year:\(year)-\(thisYear)")
                    i += 2
                    continue
                }
            }

            // "recent" / "latest"
            if word == "recent" || word == "latest" {
                queryParts.append("year:\(thisYear - 4)-\(thisYear)")
                i += 1
                continue
            }

            // "last N years"
            if word == "last" && i + 2 < words.count && words[i + 2] == "years" {
                if let n = Int(words[i + 1]) {
                    queryParts.append("year:\(thisYear - n)-\(thisYear)")
                    i += 3
                    continue
                }
            }

            // Skip filler
            if skipWords.contains(word) {
                i += 1
                continue
            }

            // Refereed / peer-reviewed
            if word == "refereed" || word == "peer-reviewed" {
                queryParts.append("property:refereed")
                i += 1
                continue
            }

            // Collect consecutive topic words
            var topicWords: [String] = [word]
            while i + 1 < words.count {
                let next = words[i + 1]
                if skipWords.contains(next) || Int(next) != nil || stopAtWords.contains(next) {
                    break
                }
                // Stop at hyphenated year ranges
                let nextHyphenParts = next.split(separator: "-")
                if nextHyphenParts.count == 2,
                   let _ = Int(nextHyphenParts[0]),
                   let _ = Int(nextHyphenParts[1]) {
                    break
                }
                // Stop at decade patterns like "1970s"
                if next.firstMatch(of: #/^\d{4}s$/#) != nil {
                    break
                }
                i += 1
                topicWords.append(next)
            }

            let topicPhrase = topicWords.joined(separator: " ")

            if expandSynonyms {
                let expanded = buildExpandedTopicQuery(topicPhrase)
                queryParts.append(expanded)
            } else {
                queryParts.append("abs:\"\(topicPhrase)\"")
            }

            i += 1
        }

        return ParsedQuery(query: queryParts.joined(separator: " "))
    }

    // MARK: - Synonym Expansion

    /// Build an expanded topic query using VagueMemoryQueryBuilder's synonym dictionary.
    /// Produces `(title:(...) OR abs:(...))` with synonym-expanded terms.
    private static func buildExpandedTopicQuery(_ phrase: String) -> String {
        let lowercased = phrase.lowercased()

        // Check for synonym match
        if let synonymList = VagueMemoryQueryBuilder.findSynonyms(for: lowercased) {
            var allTerms = [phrase] + synonymList
            // Deduplicate
            var seen = Set<String>()
            allTerms = allTerms.filter { term in
                let key = term.lowercased()
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }

            let quotedTerms = allTerms.map { term in
                term.contains(" ") ? "\"\(term)\"" : term
            }
            let orGroup = quotedTerms.joined(separator: " OR ")
            return "(title:(\(orGroup)) OR abs:(\(orGroup)))"
        }

        // No synonyms — standard abs search
        return "abs:\"\(phrase)\""
    }

    // MARK: - Query Description

    /// Generate a human-readable description of what an ADS query searches for.
    public static func describeQuery(_ query: String) -> String {
        var parts: [String] = []

        // Extract authors
        let authorPattern = #"(?:first_)?author:"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: authorPattern),
           let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            parts.append("by \(query[range])")
        }

        // Extract topic from abs:
        let absPattern = #"abs:"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: absPattern),
           let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            parts.append("about \(query[range])")
        }

        // Extract topic from title: (for synonym-expanded queries)
        if !query.contains("abs:") {
            let titlePattern = #"title:\(([^)]+)\)"#
            if let regex = try? NSRegularExpression(pattern: titlePattern),
               let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
               let range = Range(match.range(at: 1), in: query) {
                let titleTerms = String(query[range])
                    .replacingOccurrences(of: "\"", with: "")
                    .components(separatedBy: " OR ")
                    .first ?? ""
                if !titleTerms.isEmpty {
                    parts.append("about \(titleTerms) (with synonyms)")
                }
            }
        }

        // Extract year
        let yearPattern = #"year:(\d{4}(?:-\d{4})?)"#
        if let regex = try? NSRegularExpression(pattern: yearPattern),
           let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            parts.append("from \(query[range])")
        }

        // DOI
        if query.contains("doi:") {
            parts.append("DOI lookup")
        }

        // Identifier
        if query.contains("identifier:") {
            parts.append("arXiv lookup")
        }

        // Bibcode
        if query.contains("bibcode:") && !query.contains("citations(") {
            parts.append("bibcode lookup")
        }

        // Refereed
        if query.contains("property:refereed") {
            parts.append("refereed only")
        }

        if parts.isEmpty {
            return "Custom ADS query"
        }

        return "Papers " + parts.joined(separator: ", ")
    }

    // MARK: - Helpers

    private static func applyRefereed(_ query: String, refereedOnly: Bool) -> String {
        if refereedOnly && !query.contains("property:refereed") {
            return "\(query) property:refereed"
        }
        return query
    }

    private static func normalizedResult(query: String, interpretation: String) -> Result {
        let normalized = ADSQueryNormalizer.normalize(query)
        return Result(
            query: normalized.correctedQuery,
            interpretation: interpretation
        )
    }
}
