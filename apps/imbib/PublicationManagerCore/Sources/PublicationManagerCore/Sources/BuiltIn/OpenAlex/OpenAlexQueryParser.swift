//
//  OpenAlexQueryParser.swift
//  PublicationManagerCore
//
//  Parses user queries into OpenAlex search and filter components.
//  Translates user-friendly field prefixes to OpenAlex API syntax.
//

import Foundation

// MARK: - OpenAlex Query Parser

/// Parses user queries into OpenAlex search and filter components.
///
/// Translates user-friendly field prefixes to OpenAlex filter syntax:
/// - `author:"Name"` → `raw_author_name.search:Name`
/// - `title:"text"` → `title.search:text`
/// - `abstract:"text"` → `abstract.search:text`
/// - `year:2020` → `publication_year:2020`
/// - `type:article` → `type:article`
/// - `doi:10.xxx` → `doi:https://doi.org/10.xxx`
/// - `is_oa:true` → `open_access.is_oa:true`
/// - `cited_by_count:>100` → `cited_by_count:>100`
///
public enum OpenAlexQueryParser {

    // MARK: - Types

    /// Parsed query with search text and filters separated.
    public struct ParsedQuery: Sendable {
        public let searchText: String?
        public let filters: [String]

        public init(searchText: String?, filters: [String]) {
            self.searchText = searchText
            self.filters = filters
        }
    }

    // MARK: - Public API

    /// Parse a user query into OpenAlex search and filter components.
    public static func parse(_ query: String) -> ParsedQuery {
        var filters: [String] = []
        var searchParts: [String] = []

        // Regex to match field:value patterns (with optional quotes)
        // Matches: field:"quoted value" or field:unquoted_value
        let pattern = #"(\b[a-z_\.]+):(?:"([^"]+)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return ParsedQuery(searchText: query, filters: [])
        }

        var lastEnd = query.startIndex
        let matches = regex.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))

        for match in matches {
            // Add any text before this match as search text
            if let matchRange = Range(match.range, in: query) {
                let beforeText = String(query[lastEnd..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !beforeText.isEmpty {
                    searchParts.append(beforeText)
                }
                lastEnd = matchRange.upperBound
            }

            guard let fieldRange = Range(match.range(at: 1), in: query) else { continue }
            let field = String(query[fieldRange]).lowercased()

            // Get value from either quoted (group 2) or unquoted (group 3)
            let value: String
            if let quotedRange = Range(match.range(at: 2), in: query) {
                value = String(query[quotedRange])
            } else if let unquotedRange = Range(match.range(at: 3), in: query) {
                value = String(query[unquotedRange])
            } else {
                continue
            }

            // Translate field to OpenAlex filter syntax
            if let filter = translateToFilter(field: field, value: value) {
                filters.append(filter)
            } else {
                // Unknown field - treat as search text
                searchParts.append("\(field):\(value)")
            }
        }

        // Add any remaining text after the last match
        let remainingText = String(query[lastEnd...]).trimmingCharacters(in: .whitespaces)
        if !remainingText.isEmpty {
            searchParts.append(remainingText)
        }

        let searchText = searchParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return ParsedQuery(
            searchText: searchText.isEmpty ? nil : searchText,
            filters: filters
        )
    }

    // MARK: - Field Translation

    /// Translate a user-friendly field:value to OpenAlex filter syntax.
    public static func translateToFilter(field: String, value: String) -> String? {
        switch field {
        // Author searches
        case "author", "authors":
            return "raw_author_name.search:\(value)"
        case "authorships.author.display_name.search":
            return "raw_author_name.search:\(value)"
        case "author.id", "authorships.author.id":
            let id = value.hasPrefix("A") ? value : "A\(value)"
            return "author.id:\(id)"
        case "orcid", "authorships.author.orcid":
            return "author.orcid:\(value)"

        // Title and abstract
        case "title", "title.search":
            return "title.search:\(value)"
        case "abstract", "abstract.search":
            return "abstract.search:\(value)"

        // Year
        case "year", "publication_year":
            return "publication_year:\(value)"
        case "from_publication_date", "from_date":
            return "from_publication_date:\(value)"
        case "to_publication_date", "to_date":
            return "to_publication_date:\(value)"

        // Type
        case "type":
            return "type:\(value)"

        // Identifiers
        case "doi":
            let cleanDOI = value.hasPrefix("https://doi.org/") ? value : (value.hasPrefix("10.") ? "https://doi.org/\(value)" : value)
            return "doi:\(cleanDOI)"
        case "pmid", "ids.pmid":
            return "ids.pmid:\(value)"
        case "pmcid", "ids.pmcid":
            return "ids.pmcid:\(value)"

        // Open access
        case "is_oa", "open_access.is_oa":
            return "open_access.is_oa:\(value)"
        case "oa_status", "open_access.oa_status":
            return "open_access.oa_status:\(value)"

        // Boolean filters
        case "has_doi":
            return "has_doi:\(value)"
        case "has_abstract":
            return "has_abstract:\(value)"
        case "has_fulltext":
            return "has_fulltext:\(value)"
        case "has_pdf", "has_pdf_url":
            return "has_pdf_url:\(value)"

        // Citations
        case "cited_by_count", "citations":
            return "cited_by_count:\(value)"

        // Institution
        case "institution", "authorships.institutions.display_name.search":
            return "authorships.institutions.display_name.search:\(value)"

        // Source/journal
        case "source", "journal", "primary_location.source.display_name.search":
            return "primary_location.source.display_name.search:\(value)"

        // Topics and concepts
        case "topic", "topics.display_name.search":
            return "topics.display_name.search:\(value)"
        case "concept", "concepts.display_name.search":
            return "concepts.display_name.search:\(value)"

        // Already valid OpenAlex filters - pass through
        case "raw_author_name.search",
             "default.search",
             "display_name.search",
             "authorships.institutions.id",
             "authorships.institutions.ror",
             "authorships.institutions.country_code",
             "primary_location.source.id",
             "topics.id",
             "concepts.id",
             "grants.funder",
             "grants.award_id",
             "language",
             "cites",
             "cited_by",
             "related_to":
            return "\(field):\(value)"

        default:
            // Check if it looks like a valid OpenAlex filter (contains dots or underscores)
            if field.contains(".") || field.contains("_") {
                return "\(field):\(value)"
            }
            return nil
        }
    }
}
