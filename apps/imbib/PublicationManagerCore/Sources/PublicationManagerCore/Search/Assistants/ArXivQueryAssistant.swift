//
//  ArXivQueryAssistant.swift
//  PublicationManagerCore
//
//  Query assistant for arXiv searches.
//  Provides validation rules and preview fetching.
//

import Foundation
import OSLog

// MARK: - arXiv Query Assistant

/// Query assistant for arXiv searches.
///
/// Validation Rules:
/// - `arxiv.operator.andnot`: Use ANDNOT (one word), not AND NOT
/// - `arxiv.space.aftercolon`: No space after colon in field:value
/// - `arxiv.field.unknown`: Unknown field prefix
/// - `arxiv.category.unknown`: Unknown category
/// - `arxiv.date.format`: Date format validation
public actor ArXivQueryAssistant: QueryAssistant {

    // MARK: - Properties

    public nonisolated let source: QueryAssistanceSource = .arxiv

    public nonisolated let knownFields: Set<String> = [
        "ti", "au", "abs", "co", "jr", "rn", "id", "doi", "cat",
        "all", "submitteddate", "lastupdateddate"
    ]

    private let rateLimiter: RateLimiter

    // MARK: - Initialization

    public init() {
        // arXiv requires 3 second delay between requests
        self.rateLimiter = RateLimiter(rateLimit: RateLimit(requestsPerInterval: 1, intervalSeconds: 3))
    }

    // MARK: - Validation

    public nonisolated func validate(_ query: String) -> QueryValidationResult {
        var issues: [QueryValidationIssue] = []

        // Skip validation for empty queries
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return QueryValidationResult(issues: [], query: query)
        }

        // Run all validation rules
        issues.append(contentsOf: validateAndNotOperator(query))
        issues.append(contentsOf: validateSpaceAfterColon(query))
        issues.append(contentsOf: validateFieldPrefixes(query))
        issues.append(contentsOf: validateCategories(query))
        issues.append(contentsOf: validateDateFormat(query))

        // Sort by severity (errors first)
        issues.sort { $0.severity > $1.severity }

        return QueryValidationResult(issues: issues, query: query)
    }

    // MARK: - Validation Rules

    /// Rule: arxiv.operator.andnot - Use ANDNOT (one word), not AND NOT
    private nonisolated func validateAndNotOperator(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: AND NOT (two words, case insensitive)
        let pattern = #"\bAND\s+NOT\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let range = Range(match.range, in: query) else { continue }
            let matched = String(query[range])

            let correctedQuery = query.replacingCharacters(in: range, with: "ANDNOT")

            issues.append(QueryValidationIssue(
                ruleID: "arxiv.operator.andnot",
                severity: .error,
                message: "arXiv uses 'ANDNOT' as one word, not 'AND NOT'",
                range: range,
                suggestions: [
                    QuerySuggestion(
                        correctedQuery: correctedQuery,
                        description: "Replace '\(matched)' with 'ANDNOT'"
                    )
                ]
            ))
        }

        return issues
    }

    /// Rule: arxiv.space.aftercolon - No space after colon in field:value
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

            let correctedQuery = query.replacingOccurrences(
                of: #"\#(field): +"#,
                with: "\(field):",
                options: .regularExpression
            )

            issues.append(QueryValidationIssue(
                ruleID: "arxiv.space.aftercolon",
                severity: .warning,
                message: "Spaces after colon in '\(field):' may cause issues",
                range: Range(match.range, in: query),
                suggestions: [
                    QuerySuggestion(
                        correctedQuery: correctedQuery,
                        description: "Remove space after colon"
                    )
                ]
            ))
        }

        return issues
    }

    /// Rule: arxiv.field.unknown - Unknown field prefix
    private nonisolated func validateFieldPrefixes(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: word:something (but not inside quotes)
        let pattern = #"(?<!["\w])(\w+):(?=[^\s\[])"#
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
                    ruleID: "arxiv.field.unknown",
                    severity: .warning,
                    message: "Unknown arXiv field '\(field)'. Valid fields: ti, au, abs, co, jr, cat",
                    range: Range(match.range, in: query)
                ))
            }
        }

        return issues
    }

    /// Rule: arxiv.category.unknown - Unknown category
    private nonisolated func validateCategories(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: cat:category
        let pattern = #"cat:([^\s()]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let catRange = Range(match.range(at: 1), in: query) else { continue }
            let category = String(query[catRange])

            // Check if category exists
            if ArXivCategories.category(for: category) == nil {
                // Check if it's a valid group prefix (e.g., "cs.*", "math.*")
                let groupPrefix = category.split(separator: ".").first.map(String.init) ?? category
                if ArXivCategories.group(for: groupPrefix) == nil && category != "*" {
                    issues.append(QueryValidationIssue(
                        ruleID: "arxiv.category.unknown",
                        severity: .warning,
                        message: "Unknown arXiv category '\(category)'",
                        range: Range(match.range, in: query)
                    ))
                }
            }
        }

        return issues
    }

    /// Rule: arxiv.date.format - Date format validation
    private nonisolated func validateDateFormat(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: submittedDate:[...] or lastUpdatedDate:[...]
        let pattern = #"(submittedDate|lastUpdatedDate):\[([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let valueRange = Range(match.range(at: 2), in: query) else { continue }
            let value = String(query[valueRange])

            // Valid format: YYYYMMDDHHMM+TO+YYYYMMDDHHMM or * TO YYYYMMDDHHMM etc.
            let validPattern = #"^(\d{12}|\*)\s*(TO|\+TO\+)\s*(\d{12}|\*)$"#
            if value.range(of: validPattern, options: .regularExpression) == nil {
                issues.append(QueryValidationIssue(
                    ruleID: "arxiv.date.format",
                    severity: .error,
                    message: "Invalid date format. Use: submittedDate:[YYYYMMDDHHMM TO YYYYMMDDHHMM]",
                    range: Range(match.range, in: query),
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: query.replacingOccurrences(
                                of: "[\(value)]",
                                with: "[202001010000 TO 202412312359]"
                            ),
                            description: "Example: [202001010000 TO 202412312359]"
                        )
                    ]
                ))
            }
        }

        return issues
    }

    // MARK: - Preview Fetching

    public func fetchPreview(_ query: String) async throws -> QueryPreviewResult {
        // Respect rate limits
        await rateLimiter.waitIfNeeded()

        // Build URL with max_results=1 (arXiv doesn't have a count-only endpoint)
        var components = URLComponents(string: "http://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            URLQueryItem(name: "max_results", value: "1"),  // Minimal results
            URLQueryItem(name: "start", value: "0")
        ]

        guard let url = components.url else {
            throw QueryAssistantError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("imbib/1.0 (mailto:support@imbib.app)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QueryAssistantError.invalidResponse
        }

        // Check for rate limiting
        if httpResponse.statusCode == 429 {
            throw QueryAssistantError.rateLimitExceeded
        }

        guard httpResponse.statusCode == 200 else {
            Logger.queryAssistance.error("arXiv preview failed with status \(httpResponse.statusCode)")
            throw QueryAssistantError.invalidResponse
        }

        // Parse XML response to extract totalResults
        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw QueryAssistantError.invalidResponse
        }

        // Extract totalResults from <opensearch:totalResults>...</opensearch:totalResults>
        let totalResults = parseTotalResults(from: xmlString)

        await rateLimiter.recordRequest()

        return QueryPreviewResult(totalResults: totalResults)
    }

    /// Parse totalResults from arXiv Atom XML response
    private func parseTotalResults(from xml: String) -> Int {
        // Pattern: <opensearch:totalResults>N</opensearch:totalResults>
        let pattern = #"<opensearch:totalResults>(\d+)</opensearch:totalResults>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml),
              let count = Int(xml[range]) else {
            return 0
        }
        return count
    }
}
