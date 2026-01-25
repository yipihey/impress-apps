//
//  ArXivURLParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation

/// Parser for arXiv URLs.
///
/// Supports multiple URL types:
/// 1. **Paper URLs** - Import individual papers by arXiv ID
///    - `https://arxiv.org/abs/2301.12345`
///    - `https://arxiv.org/abs/2301.12345v2`
///    - `https://arxiv.org/pdf/2301.12345.pdf`
///    - `https://arxiv.org/abs/hep-th/9901001` (old format)
///
/// 2. **Search URLs** - Create smart searches from queries
///    - `https://arxiv.org/search/?query=machine+learning&searchtype=all`
///
/// 3. **Category URLs** - Create category feeds
///    - `https://arxiv.org/list/cs.LG/recent`
///    - `https://arxiv.org/list/astro-ph.GA/new`
public struct ArXivURLParser {

    // MARK: - Types

    /// The type of arXiv URL that was parsed
    public enum ArXivURLType: Equatable, Sendable {
        /// A paper URL with extracted arXiv ID
        case paper(arxivID: String)

        /// A PDF URL with extracted arXiv ID
        case pdf(arxivID: String)

        /// A search URL with extracted query
        case search(query: String, title: String?)

        /// A category listing URL (e.g., /list/cs.LG/recent)
        case categoryList(category: String, timeframe: String)
    }

    /// arXiv host variants to recognize
    private static let arxivHosts = [
        "arxiv.org",
        "www.arxiv.org",
        "export.arxiv.org"
    ]

    // MARK: - Public API

    /// Parse an arXiv URL and determine its type.
    ///
    /// - Parameter url: The URL to parse
    /// - Returns: The parsed URL type, or nil if not a valid arXiv URL
    public static func parse(_ url: URL) -> ArXivURLType? {
        guard let host = url.host?.lowercased(),
              arxivHosts.contains(host) else {
            return nil
        }

        let path = url.path

        // Check for PDF URL: /pdf/{id} or /pdf/{id}.pdf
        if path.hasPrefix("/pdf/") {
            return parsePDFURL(url)
        }

        // Check for paper URL: /abs/{id}
        if path.hasPrefix("/abs/") {
            return parsePaperURL(url)
        }

        // Check for category list: /list/{category}/{timeframe}
        if path.hasPrefix("/list/") {
            return parseCategoryListURL(url)
        }

        // Check for search URL: /search/...
        if path.hasPrefix("/search") {
            return parseSearchURL(url)
        }

        return nil
    }

    /// Check if a URL is a valid arXiv URL.
    ///
    /// - Parameter url: The URL to check
    /// - Returns: True if the URL is a recognized arXiv URL
    public static func isArXivURL(_ url: URL) -> Bool {
        parse(url) != nil
    }

    // MARK: - Private Parsing

    /// Parse an arXiv paper URL to extract the arXiv ID.
    ///
    /// Paper URLs have these forms:
    /// - New format: `https://arxiv.org/abs/2301.12345` or `https://arxiv.org/abs/2301.12345v2`
    /// - Old format: `https://arxiv.org/abs/hep-th/9901001`
    private static func parsePaperURL(_ url: URL) -> ArXivURLType? {
        let path = url.path

        // Remove /abs/ prefix
        let withoutPrefix = path.dropFirst("/abs/".count)

        // Get the arXiv ID (everything after /abs/)
        let arxivID = String(withoutPrefix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !arxivID.isEmpty else {
            return nil
        }

        // Validate: either new format (YYMM.NNNNN) or old format (category/YYMMNNN)
        if isValidArXivID(arxivID) {
            return .paper(arxivID: normalizeArXivID(arxivID))
        }

        return nil
    }

    /// Parse an arXiv PDF URL to extract the arXiv ID.
    ///
    /// PDF URLs have these forms:
    /// - `https://arxiv.org/pdf/2301.12345`
    /// - `https://arxiv.org/pdf/2301.12345.pdf`
    /// - `https://arxiv.org/pdf/2301.12345v2.pdf`
    private static func parsePDFURL(_ url: URL) -> ArXivURLType? {
        let path = url.path

        // Remove /pdf/ prefix
        var arxivID = String(path.dropFirst("/pdf/".count))

        // Remove .pdf extension if present
        if arxivID.hasSuffix(".pdf") {
            arxivID = String(arxivID.dropLast(4))
        }

        arxivID = arxivID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !arxivID.isEmpty else {
            return nil
        }

        if isValidArXivID(arxivID) {
            return .pdf(arxivID: normalizeArXivID(arxivID))
        }

        return nil
    }

    /// Parse an arXiv category list URL.
    ///
    /// Category list URLs have the form:
    /// - `https://arxiv.org/list/cs.LG/recent`
    /// - `https://arxiv.org/list/astro-ph.GA/new`
    /// - `https://arxiv.org/list/hep-th/2301` (year-month)
    private static func parseCategoryListURL(_ url: URL) -> ArXivURLType? {
        let path = url.path

        // Remove /list/ prefix
        let withoutPrefix = String(path.dropFirst("/list/".count))
        let components = withoutPrefix.split(separator: "/")

        guard components.count >= 1 else {
            return nil
        }

        let category = String(components[0])
        let timeframe = components.count >= 2 ? String(components[1]) : "recent"

        // Validate category format (e.g., cs.LG, astro-ph.GA, hep-th)
        guard isValidCategory(category) else {
            return nil
        }

        return .categoryList(category: category, timeframe: timeframe)
    }

    /// Parse an arXiv search URL to extract the query.
    ///
    /// Search URLs have the form:
    /// - `https://arxiv.org/search/?query=machine+learning&searchtype=all`
    /// - `https://arxiv.org/search/cs?query=neural+networks`
    private static func parseSearchURL(_ url: URL) -> ArXivURLType? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else {
            return nil
        }

        // Look for 'query' or 'searchquery' parameter
        let query = queryItems.first(where: { $0.name == "query" || $0.name == "searchquery" })?.value

        guard let query = query, !query.isEmpty else {
            return nil
        }

        let title = generateTitle(from: query)
        return .search(query: query, title: title)
    }

    // MARK: - Validation

    /// Validate an arXiv ID format.
    ///
    /// Valid formats:
    /// - New format: `YYMM.NNNNN` or `YYMM.NNNNNvN` (e.g., 2301.12345, 2301.12345v2)
    /// - Old format: `category/YYMMNNN` (e.g., hep-th/9901001)
    private static func isValidArXivID(_ id: String) -> Bool {
        // New format: YYMM.NNNNN(vN)?
        let newFormatPattern = #"^\d{4}\.\d{4,5}(v\d+)?$"#
        if id.range(of: newFormatPattern, options: .regularExpression) != nil {
            return true
        }

        // Old format: category/YYMMNNN
        let oldFormatPattern = #"^[a-z-]+/\d{7}(v\d+)?$"#
        if id.range(of: oldFormatPattern, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Validate an arXiv category format.
    ///
    /// Valid formats:
    /// - With subcategory: `cs.LG`, `astro-ph.GA`, `cond-mat.str-el`
    /// - Without subcategory: `hep-th`, `quant-ph`, `math`
    private static func isValidCategory(_ category: String) -> Bool {
        // Category with subcategory: letters(-letters)?.letters(-letters)?
        let withSubcategoryPattern = #"^[a-z]+(-[a-z]+)?\.[A-Za-z]+(-[A-Za-z]+)?$"#
        if category.range(of: withSubcategoryPattern, options: .regularExpression) != nil {
            return true
        }

        // Category without subcategory: letters(-letters)?
        let withoutSubcategoryPattern = #"^[a-z]+(-[a-z]+)?$"#
        if category.range(of: withoutSubcategoryPattern, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Normalize an arXiv ID by removing version suffix if present.
    ///
    /// - Parameter id: The arXiv ID to normalize
    /// - Returns: The ID without version suffix (e.g., 2301.12345v2 → 2301.12345)
    private static func normalizeArXivID(_ id: String) -> String {
        // Keep version suffix - it's important for citation
        // Just trim whitespace
        return id.trimmingCharacters(in: .whitespaces)
    }

    /// Generate a human-readable title from a search query.
    private static func generateTitle(from query: String) -> String? {
        var title = query

        // URL decode
        title = title.removingPercentEncoding ?? title

        // Replace + with space
        title = title.replacingOccurrences(of: "+", with: " ")

        // Trim
        title = title.trimmingCharacters(in: .whitespaces)

        return title.isEmpty ? nil : title
    }
}

// MARK: - URL Extension

public extension URL {
    /// Check if this URL is an arXiv URL that can be shared to imbib.
    var isArXivURL: Bool {
        ArXivURLParser.isArXivURL(self)
    }

    /// Parse this URL as an arXiv URL.
    var arxivURLType: ArXivURLParser.ArXivURLType? {
        ArXivURLParser.parse(self)
    }
}
