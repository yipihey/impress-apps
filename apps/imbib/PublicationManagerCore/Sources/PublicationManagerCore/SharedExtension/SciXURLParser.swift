//
//  SciXURLParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-08.
//

import Foundation

/// Parser for SciX (Science Explorer) URLs.
///
/// Supports two URL types:
/// 1. **Search URLs** - Create smart searches from saved queries
///    - `https://scixplorer.org/search/q=author%3AAbel%2CTom&...`
///
/// 2. **Paper URLs** - Import individual papers by bibcode
///    - `https://scixplorer.org/abs/2024ApJ...123..456B/abstract`
public struct SciXURLParser {

    // MARK: - Types

    /// The type of SciX URL that was parsed
    public enum SciXURLType: Equatable, Sendable {
        /// A search URL with extracted query and optional display name
        case search(query: String, title: String?)

        /// A paper URL with extracted bibcode
        case paper(bibcode: String)

        /// A docs() selection URL - temporary selection of papers to import
        /// These should be imported to Inbox, not saved as smart searches
        case docsSelection(query: String)
    }

    /// SciX host variants to recognize
    private static let scixHosts = [
        "scixplorer.org",
        "www.scixplorer.org"
    ]

    // MARK: - Public API

    /// Parse a SciX URL and determine its type.
    ///
    /// - Parameter url: The URL to parse
    /// - Returns: The parsed URL type, or nil if not a valid SciX URL
    public static func parse(_ url: URL) -> SciXURLType? {
        guard let host = url.host?.lowercased(),
              scixHosts.contains(host) else {
            return nil
        }

        let path = url.path

        // Check for search URL: /search/...
        if path.hasPrefix("/search") {
            return parseSearchURL(url)
        }

        // Check for paper URL: /abs/{bibcode}/...
        if path.hasPrefix("/abs/") {
            return parsePaperURL(url)
        }

        return nil
    }

    /// Check if a URL is a valid SciX URL (search or paper).
    ///
    /// - Parameter url: The URL to check
    /// - Returns: True if the URL is a recognized SciX URL
    public static func isSciXURL(_ url: URL) -> Bool {
        parse(url) != nil
    }

    // MARK: - Private Parsing

    /// Parse a SciX search URL to extract the query.
    ///
    /// Search URLs have two forms:
    /// 1. Traditional: `https://scixplorer.org/search?q=author%3AAbel%2CTom`
    /// 2. SciX-style (params in path): `https://scixplorer.org/search/q=author%3AAbel%2CTom&sort=date%20desc`
    ///
    /// Special case: `docs(hash)` queries represent temporary paper selections
    /// and should be imported to Inbox, not saved as smart searches.
    ///
    /// The `q` parameter contains the search query (URL encoded).
    private static func parseSearchURL(_ url: URL) -> SciXURLType? {
        // First try traditional query string (after ?)
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let queryItems = components.queryItems,
           let query = queryItems.first(where: { $0.name == "q" })?.value,
           !query.isEmpty {
            return classifyQuery(query)
        }

        // SciX-style: parameters are in the path after /search/
        // URL looks like: /search/fq=...&q=author:Abel&sort=...
        let path = url.path
        guard path.hasPrefix("/search/") else {
            // Just /search with no parameters
            return nil
        }

        // Extract the part after /search/
        let paramString = String(path.dropFirst("/search/".count))
        guard !paramString.isEmpty else {
            return nil
        }

        // Parse as if it were a query string
        // URL-decode the entire param string first since path components are encoded
        let decodedParams = paramString.removingPercentEncoding ?? paramString

        // Split by & to get individual params
        let params = decodedParams.split(separator: "&")

        // Find the 'q' parameter
        for param in params {
            let parts = param.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == "q" {
                let query = String(parts[1])
                if !query.isEmpty {
                    return classifyQuery(query)
                }
            }
        }

        return nil
    }

    /// Classify a query as either a docs() selection or a regular search.
    ///
    /// `docs(hash)` queries are temporary paper selections that should be
    /// imported to Inbox rather than saved as smart searches.
    private static func classifyQuery(_ query: String) -> SciXURLType {
        // Check if this is a docs() selection (temporary, not a real search)
        // Pattern: docs(hexhash) where hexhash is typically 32 hex chars
        if query.hasPrefix("docs(") && query.hasSuffix(")") {
            return .docsSelection(query: query)
        }

        // Regular search query
        let title = generateTitle(from: query)
        return .search(query: query, title: title)
    }

    /// Parse a SciX paper URL to extract the bibcode.
    ///
    /// Paper URLs have the form:
    /// `https://scixplorer.org/abs/2024ApJ...123..456B/abstract`
    ///
    /// The bibcode is the path component after `/abs/`.
    private static func parsePaperURL(_ url: URL) -> SciXURLType? {
        let path = url.path

        // Remove /abs/ prefix
        let withoutPrefix = path.dropFirst("/abs/".count)

        // Get the bibcode (first path component after /abs/)
        // Remove any trailing path like /abstract, /citations, etc.
        let pathComponents = withoutPrefix.split(separator: "/")
        guard let bibcodeComponent = pathComponents.first else {
            return nil
        }

        let bibcode = String(bibcodeComponent)

        // Validate bibcode format (basic check)
        // Bibcodes are typically 19 characters: YYYYJJJJJVVVVMPPPPA
        // But can vary, so just check it's not empty and has reasonable length
        guard bibcode.count >= 10 && bibcode.count <= 25 else {
            return nil
        }

        return .paper(bibcode: bibcode)
    }

    /// Generate a human-readable title from a SciX query string.
    ///
    /// Examples:
    /// - `author:Abel,Tom` -> "author: Abel,Tom"
    /// - `author:"Abel, Tom" year:2020` -> "author: Abel, Tom . year: 2020"
    /// - `bibstem:ApJ author:Abel` -> "bibstem: ApJ . author: Abel"
    private static func generateTitle(from query: String) -> String? {
        // Simple approach: Just clean up the query for display
        // Replace common operators with more readable versions
        var title = query

        // Remove quotes (they're for SciX syntax)
        title = title.replacingOccurrences(of: "\"", with: "")

        // Add space after colons for readability
        title = title.replacingOccurrences(of: ":", with: ": ")
        title = title.replacingOccurrences(of: ":  ", with: ": ") // Fix double space

        // Replace multiple spaces with single space
        while title.contains("  ") {
            title = title.replacingOccurrences(of: "  ", with: " ")
        }

        // Trim
        title = title.trimmingCharacters(in: .whitespaces)

        return title.isEmpty ? nil : title
    }
}

// MARK: - URL Extension

public extension URL {
    /// Check if this URL is a SciX URL that can be shared to imbib.
    var isSciXURL: Bool {
        SciXURLParser.isSciXURL(self)
    }

    /// Parse this URL as a SciX URL.
    var scixURLType: SciXURLParser.SciXURLType? {
        SciXURLParser.parse(self)
    }
}
