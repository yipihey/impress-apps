//
//  WoSQueryAssistant.swift
//  PublicationManagerCore
//
//  Query assistant for Web of Science (WoS) searches.
//  Provides validation rules and preview fetching for WoS query syntax.
//

import Foundation
import OSLog

// MARK: - WoS Query Assistant

/// Query assistant for Web of Science searches.
///
/// Validation Rules:
/// - `wos.field.unknown`: Unknown field code
/// - `wos.operator.case`: Boolean operators must be uppercase
/// - `wos.year.format`: Year format validation (YYYY or YYYY-YYYY)
/// - `wos.paren.unbalanced`: Unbalanced parentheses
/// - `wos.quote.unbalanced`: Unbalanced quotes
/// - `wos.proximity.format`: NEAR/n syntax validation
/// - `wos.field.syntax`: Field syntax requires = (e.g., AU=Einstein)
///
/// WoS Query Syntax Examples:
/// - `TS=quantum computing` (Topic search)
/// - `AU=Einstein, Albert` (Author)
/// - `TI=neural network AND PY=2020-2024` (Title + Year range)
/// - `TS=machine NEAR/5 learning` (Proximity search)
public actor WoSQueryAssistant: QueryAssistant {

    // MARK: - Properties

    public nonisolated let source: QueryAssistanceSource = .wos

    public nonisolated let knownFields: Set<String> = [
        // Core fields
        "ts", "ti", "au", "ai", "gp", "do", "py", "so",
        // Extended fields
        "ad", "og", "fo", "fg", "dt", "la", "ut",
        // Aliases (case-insensitive matching)
        "topic", "title", "author", "doi", "year", "source",
        "address", "organization", "funding"
    ]

    /// WoS-specific field codes (two-letter uppercase)
    private nonisolated let wosFieldCodes: Set<String> = [
        "TS", "TI", "AU", "AI", "GP", "DO", "PY", "SO",
        "AD", "OG", "FO", "FG", "DT", "LA", "UT"
    ]

    private let credentialManager: CredentialManager
    private let rateLimiter: RateLimiter

    // MARK: - Initialization

    public init(credentialManager: CredentialManager = .shared) {
        self.credentialManager = credentialManager
        // WoS allows 5 requests/sec
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
        issues.append(contentsOf: validateFieldSyntax(query))
        issues.append(contentsOf: validateFieldCodes(query))
        issues.append(contentsOf: validateOperatorCase(query))
        issues.append(contentsOf: validateYearFormat(query))
        issues.append(contentsOf: validateParentheses(query))
        issues.append(contentsOf: validateQuotes(query))
        issues.append(contentsOf: validateProximity(query))

        // Sort by severity (errors first)
        issues.sort { $0.severity > $1.severity }

        return QueryValidationResult(issues: issues, query: query)
    }

    // MARK: - Validation Rules

    /// Rule: wos.field.syntax - Field queries require = (e.g., AU=Einstein, not AU Einstein)
    private nonisolated func validateFieldSyntax(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: two-letter field code followed by space and term (missing =)
        let pattern = #"\b([A-Z]{2})\s+(?=[^\s=])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let fieldRange = Range(match.range(at: 1), in: query) else { continue }
            let field = String(query[fieldRange])

            // Only warn for known WoS field codes
            if wosFieldCodes.contains(field) {
                let correctedQuery = query.replacingOccurrences(
                    of: #"\#(field)\s+"#,
                    with: "\(field)=",
                    options: .regularExpression
                )

                issues.append(QueryValidationIssue(
                    ruleID: "wos.field.syntax",
                    severity: .error,
                    message: "WoS field queries require '=' (e.g., \(field)=term)",
                    range: Range(match.range, in: query),
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: correctedQuery,
                            description: "Use \(field)= instead of \(field) "
                        )
                    ]
                ))
            }
        }

        return issues
    }

    /// Rule: wos.field.unknown - Unknown field code
    private nonisolated func validateFieldCodes(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: uppercase letters followed by = (field code pattern)
        let pattern = #"(?<!["\w])([A-Z]{2,4})=(?=[^\s])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let fieldRange = Range(match.range(at: 1), in: query) else { continue }
            let field = String(query[fieldRange])

            // Check if field is known (case-insensitive for the set check)
            if !wosFieldCodes.contains(field) && !knownFields.contains(field.lowercased()) {
                issues.append(QueryValidationIssue(
                    ruleID: "wos.field.unknown",
                    severity: .warning,
                    message: "Unknown WoS field code '\(field)'. Common codes: TS (Topic), TI (Title), AU (Author), PY (Year), DO (DOI).",
                    range: Range(match.range, in: query)
                ))
            }
        }

        return issues
    }

    /// Rule: wos.operator.case - Boolean operators must be uppercase (AND, OR, NOT)
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
                    ruleID: "wos.operator.case",
                    severity: .error,
                    message: "WoS requires uppercase boolean operators: \(op.uppercased())",
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

    /// Rule: wos.year.format - Year format validation
    private nonisolated func validateYearFormat(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: PY=something
        let pattern = #"PY=([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: query) else { continue }
            let value = String(query[valueRange])

            // Valid formats: YYYY or YYYY-YYYY
            let validYearPattern = #"^\d{4}$|^\d{4}-\d{4}$"#
            if value.range(of: validYearPattern, options: .regularExpression) == nil {
                issues.append(QueryValidationIssue(
                    ruleID: "wos.year.format",
                    severity: .error,
                    message: "Invalid year format. Use PY=YYYY or PY=YYYY-YYYY",
                    range: Range(match.range, in: query),
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: query.replacingOccurrences(of: "PY=\(value)", with: "PY=2020-2024"),
                            description: "Example: PY=2020-2024"
                        )
                    ]
                ))
            }
        }

        return issues
    }

    /// Rule: wos.paren.unbalanced - Unbalanced parentheses
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
                            ruleID: "wos.paren.unbalanced",
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
                ruleID: "wos.paren.unbalanced",
                severity: .error,
                message: "Unbalanced parentheses: \(depth) unclosed opening parenthesis(es)"
            ))
        }

        return issues
    }

    /// Rule: wos.quote.unbalanced - Unbalanced quotes
    private nonisolated func validateQuotes(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        var doubleQuoteCount = 0
        var singleQuoteCount = 0

        for char in query {
            if char == "\"" {
                doubleQuoteCount += 1
            } else if char == "'" {
                singleQuoteCount += 1
            }
        }

        if doubleQuoteCount % 2 != 0 {
            issues.append(QueryValidationIssue(
                ruleID: "wos.quote.unbalanced",
                severity: .error,
                message: "Unbalanced double quotes"
            ))
        }

        // Note: Single quotes are less commonly used in WoS, but still validate
        if singleQuoteCount % 2 != 0 {
            issues.append(QueryValidationIssue(
                ruleID: "wos.quote.unbalanced",
                severity: .warning,
                message: "Unbalanced single quotes"
            ))
        }

        return issues
    }

    /// Rule: wos.proximity.format - NEAR/n syntax validation
    private nonisolated func validateProximity(_ query: String) -> [QueryValidationIssue] {
        var issues: [QueryValidationIssue] = []

        // Pattern: NEAR followed by something
        let pattern = #"NEAR(/\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            guard let range = Range(match.range, in: query) else { continue }
            let nearExpr = String(query[range])

            // Check if it's lowercase
            if nearExpr.contains("near") && !nearExpr.contains("NEAR") {
                let correctedQuery = query.replacingOccurrences(
                    of: nearExpr,
                    with: nearExpr.uppercased()
                )

                issues.append(QueryValidationIssue(
                    ruleID: "wos.proximity.format",
                    severity: .warning,
                    message: "NEAR operator should be uppercase",
                    range: range,
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: correctedQuery,
                            description: "Use \(nearExpr.uppercased())"
                        )
                    ]
                ))
            }

            // Check if NEAR lacks distance specifier
            if !nearExpr.contains("/") {
                issues.append(QueryValidationIssue(
                    ruleID: "wos.proximity.format",
                    severity: .hint,
                    message: "Consider specifying distance with NEAR/n (e.g., NEAR/5)",
                    range: range,
                    suggestions: [
                        QuerySuggestion(
                            correctedQuery: query.replacingOccurrences(of: nearExpr, with: "NEAR/5"),
                            description: "Use NEAR/5 for 5-word proximity"
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
        guard let apiKey = await credentialManager.apiKey(for: "wos") else {
            throw QueryAssistantError.apiKeyRequired
        }

        // Respect rate limits
        await rateLimiter.waitIfNeeded()

        // Build URL with count=0 for count-only query (WoS doesn't support count=0, use count=1)
        var components = URLComponents(string: "https://wos-api.clarivate.com/api/wos")!
        components.queryItems = [
            URLQueryItem(name: "databaseId", value: "WOS"),
            URLQueryItem(name: "usrQuery", value: query),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "firstRecord", value: "1"),
        ]

        guard let url = components.url else {
            throw QueryAssistantError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-ApiKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let startTime = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let duration = Date().timeIntervalSince(startTime)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QueryAssistantError.invalidResponse
        }

        // Check for rate limiting
        if httpResponse.statusCode == 429 {
            throw QueryAssistantError.rateLimitExceeded
        }

        guard httpResponse.statusCode == 200 else {
            Logger.queryAssistance.error("WoS preview failed with status \(httpResponse.statusCode)")
            throw QueryAssistantError.invalidResponse
        }

        // Parse response to get total count
        let decoder = JSONDecoder()
        guard let searchResponse = try? decoder.decode(WoSSearchResponse.self, from: data) else {
            throw QueryAssistantError.invalidResponse
        }

        await rateLimiter.recordRequest()

        return QueryPreviewResult(
            totalResults: searchResponse.queryResult.recordsFound,
            fetchDuration: duration
        )
    }
}
