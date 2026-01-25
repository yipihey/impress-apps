//
//  ADSQueryAssistant.swift
//  PublicationManagerCore
//
//  Query assistant for NASA ADS (Astrophysics Data System).
//  Provides validation rules and preview fetching.
//

import Foundation
import OSLog

// MARK: - ADS Query Assistant

/// Query assistant for NASA ADS searches.
///
/// Validation Rules:
/// - `ads.author.quote`: Author names with commas must be quoted
/// - `ads.space.aftercolon`: Spaces after colons may cause issues
/// - `ads.field.unknown`: Unknown field prefix
/// - `ads.year.format`: Year format validation
/// - `ads.paren.unbalanced`: Unbalanced parentheses
/// - `ads.operator.case`: Operators should be uppercase
public actor ADSQueryAssistant: QueryAssistant {

    // MARK: - Properties

    public nonisolated let source: QueryAssistanceSource = .ads

    public nonisolated let knownFields: Set<String> = [
        "author", "first_author", "abs", "abstract", "title",
        "year", "bibcode", "doi", "arxiv", "orcid",
        "aff", "affiliation", "full", "object", "body",
        "ack", "keyword", "identifier", "citations", "references",
        "property", "doctype", "collection", "bibstem"
    ]

    private let credentialManager: CredentialManager
    private let rateLimiter: RateLimiter

    // MARK: - Initialization

    public init(credentialManager: CredentialManager = .shared) {
        self.credentialManager = credentialManager
        // ADS allows 5 requests/sec with API key
        self.rateLimiter = RateLimiter(rateLimit: RateLimit(requestsPerInterval: 5, intervalSeconds: 1))
    }

    // MARK: - Validation

    public nonisolated func validate(_ query: String) -> QueryValidationResult {
        var issues: [QueryValidationIssue] = []

        // Skip validation for empty queries
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return QueryValidationResult(issues: [], query: query)
        }

        // Run all validation rules
        issues.append(contentsOf: validateAuthorQuoting(query))
        issues.append(contentsOf: validateSpaceAfterColon(query))
        issues.append(contentsOf: validateFieldPrefixes(query))
        issues.append(contentsOf: validateYearFormat(query))
        issues.append(contentsOf: validateParentheses(query))
        issues.append(contentsOf: validateOperatorCase(query))

        // Sort by severity (errors first)
        issues.sort { $0.severity > $1.severity }

        return QueryValidationResult(issues: issues, query: query)
    }

    // MARK: - Validation Rules

    /// Rule: ads.author.quote - Author names with commas must be quoted
    private nonisolated func validateAuthorQuoting(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: author:Name, Name (without quotes) - allows optional spaces around comma
        let pattern = #"author:([^"\s]+,\s*[^"\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let range = Range(match.range(at: 1), in: query) else { continue }
            let authorName = String(query[range])

            let correctedQuery = query.replacingOccurrences(
                of: "author:\(authorName)",
                with: "author:\"\(authorName)\""
            )

            issues.append(QueryValidationIssue(
                ruleID: "ads.author.quote",
                severity: .error,
                message: "Author names with commas must be quoted",
                range: Range(match.range, in: query),
                suggestions: [
                    QuerySuggestion(
                        correctedQuery: correctedQuery,
                        description: "Use author:\"\(authorName)\""
                    )
                ]
            ))
        }

        return issues
    }

    /// Rule: ads.space.aftercolon - Spaces after colons may cause unexpected results
    private nonisolated func validateSpaceAfterColon(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: field: value (space after colon)
        let pattern = #"(\w+):\s+(?=[^\s])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let fieldRange = Range(match.range(at: 1), in: query) else { continue }
            let field = String(query[fieldRange])

            // Only warn for known fields
            if knownFields.contains(field.lowercased()) {
                let correctedQuery = query.replacingOccurrences(
                    of: #"\#(field): +"#,
                    with: "\(field):",
                    options: .regularExpression
                )

                issues.append(QueryValidationIssue(
                    ruleID: "ads.space.aftercolon",
                    severity: .warning,
                    message: "Space after colon in '\(field):' may cause unexpected results",
                    range: Range(match.range, in: query),
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: correctedQuery,
                            description: "Remove space after colon"
                        )
                    ]
                ))
            }
        }

        return issues
    }

    /// Rule: ads.field.unknown - Unknown field prefix
    private nonisolated func validateFieldPrefixes(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: word:something (but not inside quotes)
        let pattern = #"(?<!["\w])(\w+):(?=[^\s])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let fieldRange = Range(match.range(at: 1), in: query) else { continue }
            let field = String(query[fieldRange])

            // Check if field is known (case-insensitive)
            if !knownFields.contains(field.lowercased()) {
                issues.append(QueryValidationIssue(
                    ruleID: "ads.field.unknown",
                    severity: .warning,
                    message: "Unknown field '\(field)'. Check spelling or use 'full:' for full-text search.",
                    range: Range(match.range, in: query)
                ))
            }
        }

        return issues
    }

    /// Rule: ads.year.format - Year format validation
    private nonisolated func validateYearFormat(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: year:something
        let pattern = #"year:([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: query) else { continue }
            let value = String(query[valueRange])

            // Valid formats: YYYY, YYYY-YYYY, [YYYY TO YYYY]
            let validYearPattern = #"^\d{4}$|^\d{4}-\d{4}$|^\[\d{4}\s+TO\s+\d{4}\]$"#
            if value.range(of: validYearPattern, options: .regularExpression) == nil {
                issues.append(QueryValidationIssue(
                    ruleID: "ads.year.format",
                    severity: .error,
                    message: "Invalid year format. Use year:YYYY or year:YYYY-YYYY",
                    range: Range(match.range, in: query),
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: query.replacingOccurrences(of: "year:\(value)", with: "year:2020-2024"),
                            description: "Example: year:2020-2024"
                        )
                    ]
                ))
            }
        }

        return issues
    }

    /// Rule: ads.paren.unbalanced - Unbalanced parentheses
    private nonisolated func validateParentheses(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        var depth = 0
        var inQuote = false
        var quoteChar: Character = "\""

        for char in query {
            if !inQuote && (char == "\"" || char == "'") {
                inQuote = true
                quoteChar = char
            } else if inQuote && char == quoteChar {
                inQuote = false
            } else if !inQuote {
                if char == "(" {
                    depth += 1
                } else if char == ")" {
                    depth -= 1
                    if depth < 0 {
                        issues.append(QueryValidationIssue(
                            ruleID: "ads.paren.unbalanced",
                            severity: .error,
                            message: "Unbalanced parentheses: extra closing parenthesis"
                        ))
                        return issues
                    }
                }
            }
        }

        if depth > 0 {
            issues.append(QueryValidationIssue(
                ruleID: "ads.paren.unbalanced",
                severity: .error,
                message: "Unbalanced parentheses: \(depth) unclosed opening parenthesis(es)"
            ))
        }

        return issues
    }

    /// Rule: ads.operator.case - Operators should be uppercase
    private nonisolated func validateOperatorCase(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: lowercase boolean operators (not in quotes)
        let operators = ["and", "or", "not"]
        let pattern = #"(?<!["\w])(\b(?:and|or|not)\b)(?!["\w])"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let range = Range(match.range(at: 1), in: query) else { continue }
            let op = String(query[range])

            // Only flag if not already uppercase
            if operators.contains(op.lowercased()) && op != op.uppercased() {
                let correctedQuery = query.replacingCharacters(in: range, with: op.uppercased())

                issues.append(QueryValidationIssue(
                    ruleID: "ads.operator.case",
                    severity: .hint,
                    message: "Boolean operators should be uppercase: \(op.uppercased())",
                    range: range,
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: correctedQuery,
                            description: "Use \(op.uppercased())"
                        )
                    ]
                ))
            }
        }

        return issues
    }

    // MARK: - Preview Fetching

    public func fetchPreview(_ query: String) async throws -> QueryPreviewResult {
        // Check for API key
        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw QueryAssistantError.apiKeyRequired
        }

        // Respect rate limits
        await rateLimiter.waitIfNeeded()

        // Build URL with rows=0 for count-only query
        var components = URLComponents(string: "https://api.adsabs.harvard.edu/v1/search/query")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "rows", value: "0"),  // Count only
            URLQueryItem(name: "fl", value: "")      // No fields
        ]

        guard let url = components.url else {
            throw QueryAssistantError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QueryAssistantError.invalidResponse
        }

        // Check for rate limiting
        if httpResponse.statusCode == 429 {
            throw QueryAssistantError.rateLimitExceeded
        }

        guard httpResponse.statusCode == 200 else {
            Logger.queryAssistance.error("ADS preview failed with status \(httpResponse.statusCode)")
            throw QueryAssistantError.invalidResponse
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseDict = json["response"] as? [String: Any],
              let numFound = responseDict["numFound"] as? Int else {
            throw QueryAssistantError.invalidResponse
        }

        await rateLimiter.recordRequest()

        return QueryPreviewResult(totalResults: numFound)
    }
}
