//
//  OpenAlexQueryAssistant.swift
//  PublicationManagerCore
//
//  Query assistant for OpenAlex.
//  Provides validation rules and preview fetching.
//

import Foundation
import OSLog

// MARK: - OpenAlex Query Assistant

/// Query assistant for OpenAlex searches.
///
/// Validation Rules:
/// - `openalex.filter.syntax`: Filter requires colon (e.g., `publication_year:2024`)
/// - `openalex.filter.unknown`: Unknown filter field
/// - `openalex.year.format`: Year ranges use hyphen (2020-2024)
/// - `openalex.boolean.case`: Boolean operators (AND, OR, NOT)
/// - `openalex.paren.unbalanced`: Unbalanced parentheses
/// - `openalex.quote.unbalanced`: Unbalanced quotes
public actor OpenAlexQueryAssistant: QueryAssistant {

    // MARK: - Properties

    public nonisolated let source: QueryAssistanceSource = .openalex

    public nonisolated let knownFields: Set<String> = [
        // Search fields
        "title.search", "abstract.search", "display_name.search", "default.search",
        // Author fields
        "authorships.author.display_name.search", "authorships.author.id",
        "authorships.author.orcid",
        // Institution fields
        "authorships.institutions.display_name.search", "authorships.institutions.id",
        "authorships.institutions.ror", "authorships.institutions.country_code",
        // Date fields
        "publication_year", "from_publication_date", "to_publication_date",
        // Source fields
        "primary_location.source.display_name.search", "primary_location.source.id",
        // Identifier fields
        "doi", "ids.pmid", "ids.pmcid", "ids.openalex",
        // Type and access fields
        "type", "open_access.is_oa", "open_access.oa_status",
        // Boolean filters
        "has_doi", "has_abstract", "has_fulltext", "has_pdf_url", "has_orcid", "has_references",
        // Metrics
        "cited_by_count", "referenced_works_count",
        // Classification
        "topics.id", "topics.display_name.search", "concepts.id",
        // Funding
        "grants.funder", "grants.award_id",
        // Other
        "language", "cites", "cited_by", "related_to"
    ]

    private let rateLimiter: RateLimiter
    private let credentialManager: CredentialManager

    // MARK: - Initialization

    public init(credentialManager: CredentialManager = .shared) {
        self.credentialManager = credentialManager
        // OpenAlex allows 10 requests/sec with polite pool
        self.rateLimiter = RateLimiter(rateLimit: RateLimit(requestsPerInterval: 10, intervalSeconds: 1))
    }

    // MARK: - Validation

    public nonisolated func validate(_ query: String) -> QueryValidationResult {
        var issues: [QueryValidationIssue] = []

        // Skip validation for empty queries
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return QueryValidationResult(issues: [], query: query)
        }

        // Run all validation rules
        issues.append(contentsOf: validateFilterSyntax(query))
        issues.append(contentsOf: validateYearFormat(query))
        issues.append(contentsOf: validateParentheses(query))
        issues.append(contentsOf: validateQuotes(query))
        issues.append(contentsOf: validateBooleanOperators(query))

        // Sort by severity (errors first)
        issues.sort { $0.severity > $1.severity }

        return QueryValidationResult(issues: issues, query: query)
    }

    // MARK: - Validation Rules

    /// Rule: openalex.filter.syntax - Validate filter field syntax
    private nonisolated func validateFilterSyntax(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Look for patterns that look like filter fields but are malformed
        // e.g., "publication_year=2024" instead of "publication_year:2024"
        let pattern = #"(\b[a-z_\.]+)\s*=\s*(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let fieldRange = Range(match.range(at: 1), in: query),
                  let valueRange = Range(match.range(at: 2), in: query) else { continue }

            let field = String(query[fieldRange])
            let value = String(query[valueRange])

            // Check if this looks like a known filter field
            if knownFields.contains(field.lowercased()) ||
               field.contains(".") ||
               field.contains("_") {

                let correctedQuery = query.replacingCharacters(
                    in: Range(match.range, in: query)!,
                    with: "\(field):\(value)"
                )

                issues.append(QueryValidationIssue(
                    ruleID: "openalex.filter.syntax",
                    severity: .error,
                    message: "OpenAlex filters use colon (:) not equals (=)",
                    range: Range(match.range, in: query),
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: correctedQuery,
                            description: "Use \(field):\(value)"
                        )
                    ]
                ))
            }
        }

        return issues
    }

    /// Rule: openalex.year.format - Year format validation
    private nonisolated func validateYearFormat(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Check for year ranges with wrong separator (e.g., "2020..2024" or "2020 to 2024")
        let patterns = [
            (#"publication_year:(\d{4})\.\.(\d{4})"#, "dotdot"),
            (#"publication_year:(\d{4})\s+to\s+(\d{4})"#, "to"),
        ]

        for (pattern, type) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

            for match in matches {
                guard let startYearRange = Range(match.range(at: 1), in: query),
                      let endYearRange = Range(match.range(at: 2), in: query) else { continue }

                let startYear = String(query[startYearRange])
                let endYear = String(query[endYearRange])

                let correctedQuery = query.replacingCharacters(
                    in: Range(match.range, in: query)!,
                    with: "publication_year:\(startYear)-\(endYear)"
                )

                let message = type == "dotdot"
                    ? "Use hyphen (-) for year ranges, not double dot (..)"
                    : "Use hyphen (-) for year ranges, not 'to'"

                issues.append(QueryValidationIssue(
                    ruleID: "openalex.year.format",
                    severity: .error,
                    message: message,
                    range: Range(match.range, in: query),
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: correctedQuery,
                            description: "Use publication_year:\(startYear)-\(endYear)"
                        )
                    ]
                ))
            }
        }

        return issues
    }

    /// Rule: openalex.paren.unbalanced - Check for unbalanced parentheses
    private nonisolated func validateParentheses(_ query: String) -> [QueryValidationIssue] {
        var depth = 0
        var firstUnbalanced: String.Index?

        for (index, char) in zip(query.indices, query) {
            if char == "(" {
                depth += 1
            } else if char == ")" {
                depth -= 1
                if depth < 0 && firstUnbalanced == nil {
                    firstUnbalanced = index
                }
            }
        }

        if depth != 0 || firstUnbalanced != nil {
            return [QueryValidationIssue(
                ruleID: "openalex.paren.unbalanced",
                severity: .error,
                message: "Unbalanced parentheses in query",
                range: nil,
                suggestions: []
            )]
        }

        return []
    }

    /// Rule: openalex.quote.unbalanced - Check for unbalanced quotes
    private nonisolated func validateQuotes(_ query: String) -> [QueryValidationIssue] {
        var doubleQuoteCount = 0

        for char in query {
            if char == "\"" {
                doubleQuoteCount += 1
            }
        }

        if doubleQuoteCount % 2 != 0 {
            return [QueryValidationIssue(
                ruleID: "openalex.quote.unbalanced",
                severity: .error,
                message: "Unbalanced quotes in query",
                range: nil,
                suggestions: []
            )]
        }

        return []
    }

    /// Rule: openalex.boolean.case - Boolean operators should be uppercase
    private nonisolated func validateBooleanOperators(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        let operators = ["and", "or", "not"]

        for op in operators {
            // Look for lowercase operators between words (not inside words)
            let pattern = #"\s\#(op)\s"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }

            let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

            for match in matches {
                guard let range = Range(match.range, in: query) else { continue }

                let correctedQuery = query.replacingCharacters(
                    in: range,
                    with: " \(op.uppercased()) "
                )

                issues.append(QueryValidationIssue(
                    ruleID: "openalex.boolean.case",
                    severity: .warning,
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

    // MARK: - Preview

    public func fetchPreview(_ query: String) async throws -> QueryPreviewResult {
        Logger.queryAssistance.info("OpenAlex: Fetching preview for query")

        let startTime = Date()

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "https://api.openalex.org/works")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "per-page", value: "1"),
        ]

        // Add email for polite pool
        if let email = await credentialManager.email(for: "openalex") {
            components.queryItems?.append(URLQueryItem(name: "mailto", value: email))
        }

        guard let url = components.url else {
            throw QueryAssistantError.invalidResponse
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QueryAssistantError.networkError(underlying: URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 429 {
            throw QueryAssistantError.rateLimitExceeded
        }

        guard httpResponse.statusCode == 200 else {
            throw QueryAssistantError.networkError(underlying: URLError(.badServerResponse))
        }

        let decoder = JSONDecoder()
        let searchResponse = try decoder.decode(OpenAlexSearchResponse.self, from: data)

        let duration = Date().timeIntervalSince(startTime)

        return QueryPreviewResult(
            totalResults: searchResponse.meta.count,
            fetchDuration: duration,
            fromCache: false,
            message: nil
        )
    }
}
