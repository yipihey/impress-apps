//
//  ArXivSource.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - arXiv Source

/// Source plugin for arXiv preprint server.
/// Uses the arXiv API (Atom feed format).
public actor ArXivSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "arxiv",
        name: "arXiv",
        description: "Open-access preprint server for physics, math, CS, and more",
        rateLimit: RateLimit(requestsPerInterval: 1, intervalSeconds: 3),
        credentialRequirement: .none,
        registrationURL: nil,
        deduplicationPriority: 60,
        iconName: "doc.text"
    )

    private let rateLimiter: RateLimiter
    private let baseURL = "https://export.arxiv.org/api/query"
    private let session: URLSession

    // MARK: - Initialization

    public init(session: URLSession = .shared) {
        self.session = session
        self.rateLimiter = RateLimiter(rateLimit: RateLimit(requestsPerInterval: 1, intervalSeconds: 3))
    }

    // MARK: - SourcePlugin

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        try await searchWithRetry(query: query, maxResults: maxResults, daysBack: nil, retryCount: 0)
    }

    /// Search with a custom date range.
    ///
    /// - Parameters:
    ///   - query: The search query
    ///   - maxResults: Maximum number of results
    ///   - daysBack: Number of days back to search. If nil, uses default (7 days for category searches, no limit otherwise).
    ///               Use 0 to disable the automatic date filter entirely.
    public func search(query: String, maxResults: Int = 50, daysBack: Int?) async throws -> [SearchResult] {
        try await searchWithRetry(query: query, maxResults: maxResults, daysBack: daysBack, retryCount: 0)
    }

    private func searchWithRetry(query: String, maxResults: Int, daysBack: Int?, retryCount: Int) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        await rateLimiter.waitIfNeeded()

        // Cap maxResults to avoid excessive response sizes
        let cappedMaxResults = min(maxResults, 3000)

        // Build the arXiv API query from user query
        let apiQuery = buildAPIQuery(from: query)

        // Determine sort order based on query type
        let isCategorySearch = query.contains("cat:")
        let sortBy = isCategorySearch ? "submittedDate" : "relevance"
        let sortOrder = "descending"

        // Apply date filter:
        // - If daysBack is 0, no date filter
        // - If daysBack is specified (non-nil, non-zero), use that
        // - If daysBack is nil and it's a category search, default to 7 days
        var finalQuery = apiQuery
        let effectiveDaysBack: Int?
        if let days = daysBack {
            effectiveDaysBack = days > 0 ? days : nil  // 0 means no filter
        } else if isCategorySearch {
            effectiveDaysBack = 7  // Default for category searches
        } else {
            effectiveDaysBack = nil
        }

        if let days = effectiveDaysBack {
            let calendar = Calendar.current
            let endDate = Date()
            let startDate = calendar.date(byAdding: .day, value: -days, to: endDate)!

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMddHHmm"
            formatter.timeZone = TimeZone(identifier: "UTC")

            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)

            // arXiv date range format: submittedDate:[YYYYMMDDHHMM+TO+YYYYMMDDHHMM]
            // Note: arXiv API specifically requires +TO+ (plus signs), not spaces
            finalQuery = "(\(apiQuery)) AND submittedDate:[\(startStr)+TO+\(endStr)]"
        }

        // Build URL
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: finalQuery),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: "\(cappedMaxResults)"),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: sortOrder),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        // Handle rate limiting with retry (max 2 retries)
        if httpResponse.statusCode == 429 {
            if retryCount < 2 {
                // Respect Retry-After header if present, otherwise use conservative backoff
                let waitSeconds: Int
                if let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                   let retryAfterValue = Int(retryAfterHeader), retryAfterValue > 0, retryAfterValue <= 600 {
                    waitSeconds = retryAfterValue
                } else {
                    waitSeconds = 10 * (retryCount + 1)  // 10s, then 20s
                }
                Logger.sources.warningCapture("arXiv rate limited (429), waiting \(waitSeconds)s before retry \(retryCount + 1)/2", category: "sources")
                try await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
                return try await searchWithRetry(query: query, maxResults: maxResults, daysBack: daysBack, retryCount: retryCount + 1)
            } else {
                Logger.sources.errorCapture("arXiv rate limited after 2 retries, please wait a few minutes", category: "sources")
                throw SourceError.rateLimited(retryAfter: 300)  // Suggest 5 minutes
            }
        }

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        return try parseAtomFeed(data)
    }

    // MARK: - Query Building

    /// Build an arXiv API query from a user-friendly query string.
    ///
    /// Supports the following field prefixes:
    /// - `cat:cs.LG` - Category search
    /// - `au:Author` - Author search
    /// - `ti:Title` - Title search
    /// - `abs:Abstract` - Abstract search
    /// - `id:2301.12345` - arXiv ID search
    /// - Plain text - All fields search
    ///
    /// Multiple terms can be combined with AND/OR.
    private func buildAPIQuery(from query: String) -> String {
        // If query already contains arXiv API syntax, use it directly
        if isRawAPIQuery(query) {
            return query
        }

        // Handle field prefixes
        let fieldMappings: [(prefix: String, apiField: String)] = [
            ("cat:", "cat:"),
            ("category:", "cat:"),
            ("au:", "au:"),
            ("author:", "au:"),
            ("ti:", "ti:"),
            ("title:", "ti:"),
            ("abs:", "abs:"),
            ("abstract:", "abs:"),
            ("id:", "id:"),
            ("arxiv:", "id:"),
            ("co:", "co:"),
            ("comment:", "co:"),
            ("jr:", "jr:"),
            ("journal:", "jr:"),
            ("rn:", "rn:"),
            ("report:", "rn:"),
        ]

        // Check for field prefix at start
        for (prefix, apiField) in fieldMappings {
            if query.lowercased().hasPrefix(prefix) {
                let value = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                // Handle quoted values
                let cleanValue = value.replacingOccurrences(of: "\"", with: "")
                // Wrap multi-word values in quotes for phrase search
                if cleanValue.contains(" ") && !cleanValue.contains(" AND ") && !cleanValue.contains(" OR ") {
                    return "\(apiField)\"\(cleanValue)\""
                }
                return "\(apiField)\(cleanValue)"
            }
        }

        // Check for combined queries (field1:value1 AND field2:value2)
        let andParts = query.components(separatedBy: " AND ")
        if andParts.count > 1 {
            let transformedParts = andParts.map { transformSingleTerm($0.trimmingCharacters(in: .whitespaces)) }
            return transformedParts.joined(separator: " AND ")
        }

        let orParts = query.components(separatedBy: " OR ")
        if orParts.count > 1 {
            let transformedParts = orParts.map { transformSingleTerm($0.trimmingCharacters(in: .whitespaces)) }
            return transformedParts.joined(separator: " OR ")
        }

        // Plain text query - search all fields
        return "all:\(query)"
    }

    /// Transform a single term that might have a field prefix.
    private func transformSingleTerm(_ term: String) -> String {
        let fieldMappings: [(prefix: String, apiField: String)] = [
            ("cat:", "cat:"),
            ("category:", "cat:"),
            ("au:", "au:"),
            ("author:", "au:"),
            ("ti:", "ti:"),
            ("title:", "ti:"),
            ("abs:", "abs:"),
            ("abstract:", "abs:"),
            ("id:", "id:"),
            ("arxiv:", "id:"),
            ("co:", "co:"),
            ("comment:", "co:"),
            ("jr:", "jr:"),
            ("journal:", "jr:"),
            ("rn:", "rn:"),
            ("report:", "rn:"),
        ]

        for (prefix, apiField) in fieldMappings {
            if term.lowercased().hasPrefix(prefix) {
                let value = String(term.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                let cleanValue = value.replacingOccurrences(of: "\"", with: "")
                if cleanValue.contains(" ") {
                    return "\(apiField)\"\(cleanValue)\""
                }
                return "\(apiField)\(cleanValue)"
            }
        }

        // No prefix - treat as all fields
        return "all:\(term)"
    }

    /// Check if query is already in raw arXiv API format.
    private func isRawAPIQuery(_ query: String) -> Bool {
        let apiPrefixes = ["all:", "ti:", "au:", "abs:", "co:", "jr:", "cat:", "rn:", "id:", "submittedDate:", "lastUpdatedDate:"]
        return apiPrefixes.contains { query.hasPrefix($0) }
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        // Try to fetch from arXiv's BibTeX endpoint
        if let arxivID = result.arxivID {
            do {
                return try await fetchBibTeXFromEndpoint(arxivID: arxivID, result: result)
            } catch {
                Logger.sources.warningCapture("Failed to fetch BibTeX from arXiv endpoint: \(error.localizedDescription), falling back to constructed entry", category: "sources")
            }
        }

        // Fall back to constructed entry
        return constructBibTeXEntry(from: result)
    }

    /// Fetch BibTeX directly from arXiv's /bibtex/{id} endpoint.
    private func fetchBibTeXFromEndpoint(arxivID: String, result: SearchResult) async throws -> BibTeXEntry {
        await rateLimiter.waitIfNeeded()

        // Strip version suffix if present for cleaner URL (arXiv redirects)
        let cleanID = arxivID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)

        guard let url = URL(string: "https://arxiv.org/bibtex/\(cleanID)") else {
            throw SourceError.invalidRequest("Invalid arXiv BibTeX URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        guard let bibtexString = String(data: data, encoding: .utf8) else {
            throw SourceError.parseError("Invalid BibTeX encoding")
        }

        // Parse the BibTeX
        let parser = BibTeXParserFactory.createParser()
        let items = try parser.parse(bibtexString)

        // Find the first entry
        guard let firstItem = items.first,
              case .entry(let entry) = firstItem else {
            // If parsing fails, fall back to constructed entry
            return constructBibTeXEntry(from: result)
        }

        // Normalize and add any missing fields from result
        var fields = entry.fields

        // Ensure we have the arXiv-specific fields
        fields["eprint"] = arxivID
        fields["archiveprefix"] = "arXiv"

        // Add primaryclass if we have it from the search result
        if let primaryCategory = result.primaryCategory, fields["primaryclass"] == nil {
            fields["primaryclass"] = primaryCategory
        }

        // Add abstract if we have it and the BibTeX doesn't
        if let abstract = result.abstract, fields["abstract"] == nil {
            fields["abstract"] = abstract
        }

        return BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            fields: fields,
            rawBibTeX: bibtexString
        )
    }

    public nonisolated func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        var fields = entry.fields

        // Add arXiv-specific fields
        if let arxivID = extractArXivID(from: entry) {
            fields["eprint"] = arxivID
            fields["archiveprefix"] = "arXiv"

            // Extract primary category if present
            if let category = extractCategory(from: arxivID) {
                fields["primaryclass"] = category
            }
        }

        return BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            fields: fields,
            rawBibTeX: entry.rawBibTeX
        )
    }

    // MARK: - Atom Feed Parsing

    private func parseAtomFeed(_ data: Data) throws -> [SearchResult] {
        let parser = ArXivAtomParser()
        return try parser.parse(data)
    }

    private func constructBibTeXEntry(from result: SearchResult) -> BibTeXEntry {
        var fields: [String: String] = [:]

        fields["title"] = result.title
        fields["author"] = result.authors.joined(separator: " and ")
        if let year = result.year {
            fields["year"] = String(year)
        }
        if let abstract = result.abstract {
            fields["abstract"] = abstract
        }
        if let arxivID = result.arxivID {
            fields["eprint"] = arxivID
            fields["archiveprefix"] = "arXiv"
        }
        // Add primaryclass from category (arXiv convention)
        if let primaryCategory = result.primaryCategory {
            fields["primaryclass"] = primaryCategory
        }
        if let url = result.webURL {
            fields["url"] = url.absoluteString
        }
        if let doi = result.doi {
            fields["doi"] = doi
        }

        let citeKey = CiteKeyGenerator().generate(from: result)

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: "article",
            fields: fields
        )
    }

    private nonisolated func extractArXivID(from entry: BibTeXEntry) -> String? {
        if let eprint = entry.fields["eprint"] {
            return eprint
        }
        if let arxivid = entry.fields["arxivid"] {
            return arxivid
        }
        // Try to extract from URL
        if let url = entry.fields["url"], url.contains("arxiv.org") {
            if let match = url.range(of: #"\d{4}\.\d{4,5}(v\d+)?"#, options: .regularExpression) {
                return String(url[match])
            }
        }
        return nil
    }

    private nonisolated func extractCategory(from arxivID: String) -> String? {
        // Old format: hep-th/9901001
        if arxivID.contains("/") {
            return arxivID.components(separatedBy: "/").first
        }
        return nil
    }
}

// MARK: - Atom Parser

private class ArXivAtomParser: NSObject, XMLParserDelegate {

    private var results: [SearchResult] = []
    private var currentEntry: EntryData?
    private var currentElement: String = ""
    private var currentText: String = ""
    private var currentAuthors: [String] = []
    private var currentLinks: [String: String] = [:]
    private var currentCategories: [String] = []
    private var currentPrimaryCategory: String?

    struct EntryData {
        var id: String = ""
        var title: String = ""
        var summary: String = ""
        var published: String = ""
        var doi: String?
    }

    func parse(_ data: Data) throws -> [SearchResult] {
        results = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return results
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        if elementName == "entry" {
            currentEntry = EntryData()
            currentAuthors = []
            currentLinks = [:]
            currentCategories = []
            currentPrimaryCategory = nil
        } else if elementName == "link", let href = attributeDict["href"] {
            let rel = attributeDict["rel"] ?? "alternate"
            let type = attributeDict["type"] ?? ""
            if rel == "alternate" {
                currentLinks["web"] = href
            } else if type == "application/pdf" {
                currentLinks["pdf"] = href
            }
        } else if elementName == "arxiv:primary_category", let term = attributeDict["term"] {
            // Primary category: <arxiv:primary_category term="cs.LG"/>
            currentPrimaryCategory = term
            if !currentCategories.contains(term) {
                currentCategories.append(term)
            }
        } else if elementName == "category", let term = attributeDict["term"] {
            // Additional categories: <category term="stat.ML"/>
            if !currentCategories.contains(term) {
                currentCategories.append(term)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "entry", var entry = currentEntry {
            // Build SearchResult
            let arxivID = extractArXivID(from: entry.id)
            let year = extractYear(from: entry.published)

            // Build PDF links with source tracking
            var pdfLinks: [PDFLink] = []
            if let pdfURLString = currentLinks["pdf"], let pdfURL = URL(string: pdfURLString) {
                pdfLinks.append(PDFLink(url: pdfURL, type: .preprint, sourceID: "arxiv"))
            }

            // Determine primary category: use explicit primary_category, else first category, else extract from old-style ID
            let primaryCat = currentPrimaryCategory
                ?? currentCategories.first
                ?? (arxivID.flatMap { extractCategoryFromOldID($0) })

            let result = SearchResult(
                id: arxivID ?? entry.id,
                sourceID: "arxiv",
                title: cleanTitle(entry.title),
                authors: currentAuthors,
                year: year,
                venue: "arXiv",
                abstract: entry.summary,
                doi: entry.doi,
                arxivID: arxivID,
                primaryCategory: primaryCat,
                categories: currentCategories.isEmpty ? nil : currentCategories,
                pdfLinks: pdfLinks,
                webURL: currentLinks["web"].flatMap { URL(string: $0) }
            )
            results.append(result)
            currentEntry = nil

        } else if currentEntry != nil {
            switch elementName {
            case "id":
                currentEntry?.id = text
            case "title":
                currentEntry?.title = text
            case "summary":
                currentEntry?.summary = text
            case "published":
                currentEntry?.published = text
            case "name":
                currentAuthors.append(text)
            case "arxiv:doi":
                currentEntry?.doi = text
            default:
                break
            }
        }
    }

    /// Extract category from old-style arXiv ID (e.g., "hep-th/9901001" → "hep-th")
    private func extractCategoryFromOldID(_ arxivID: String) -> String? {
        if arxivID.contains("/") {
            return arxivID.components(separatedBy: "/").first
        }
        return nil
    }

    private func extractArXivID(from idURL: String) -> String? {
        // ID format: http://arxiv.org/abs/2301.12345v1
        if let range = idURL.range(of: #"\d{4}\.\d{4,5}(v\d+)?"#, options: .regularExpression) {
            return String(idURL[range])
        }
        // Old format
        if let range = idURL.range(of: #"[a-z-]+/\d{7}"#, options: .regularExpression) {
            return String(idURL[range])
        }
        return nil
    }

    private func extractYear(from dateString: String) -> Int? {
        // Format: 2023-01-15T12:00:00Z
        if dateString.count >= 4, let year = Int(dateString.prefix(4)) {
            return year
        }
        return nil
    }

    private func cleanTitle(_ title: String) -> String {
        // Remove newlines and extra whitespace
        title.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - BrowserURLProvider Conformance

extension ArXivSource: BrowserURLProvider {

    public static var sourceID: String { "arxiv" }

    /// Return direct arXiv PDF URL for browser access.
    ///
    /// For arXiv papers, we can go directly to the PDF instead of the abstract page.
    /// URL format: https://arxiv.org/pdf/{arxiv_id}.pdf
    ///
    /// - Parameter publication: The publication to find a PDF URL for
    /// - Returns: Direct arXiv PDF URL, or nil if no arXiv ID
    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        guard let arxivID = publication.arxivID, !arxivID.isEmpty else {
            return nil
        }

        // Clean the arXiv ID (remove version suffix for consistent URL)
        let cleanID = arxivID.trimmingCharacters(in: .whitespaces)

        // Build direct PDF URL
        let pdfURL = URL(string: "https://arxiv.org/pdf/\(cleanID).pdf")
        Logger.pdfBrowser.debug("ArXiv: Using direct PDF URL for: \(cleanID)")
        return pdfURL
    }
}
