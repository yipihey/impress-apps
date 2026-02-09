//
//  OpenAlexSource.swift
//  PublicationManagerCore
//
//  Source plugin for OpenAlex - the open catalog of scholarly works.
//  https://openalex.org
//

import Foundation
import OSLog

// MARK: - OpenAlex Source

/// Source plugin for OpenAlex.
///
/// OpenAlex is an open catalog of 240M+ scholarly works with rich metadata including:
/// - Citation counts and trends
/// - Open access status and PDF locations
/// - Research topics and classifications
/// - Institutional affiliations
/// - Funding information
///
/// ## Authentication
///
/// No API key is required. Email is optional but recommended for higher rate limits:
/// - Without email: 100 requests/day
/// - With email (polite pool): 100,000 requests/day
///
/// ## Rate Limits
///
/// OpenAlex uses a credit-based rate limiting system (as of Feb 2026):
/// - 1 credit per request
/// - 10 credits/second burst
/// - Polite pool: much higher limits
///
public actor OpenAlexSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "openalex",
        name: "OpenAlex",
        description: "Open catalog of 240M+ scholarly works with citations, OA status, and rich metadata",
        rateLimit: RateLimit(requestsPerInterval: 10, intervalSeconds: 1),
        credentialRequirement: .emailOptional,
        registrationURL: nil,  // No registration needed
        deduplicationPriority: 35,
        iconName: "book.pages"
    )

    let rateLimiter: RateLimiter
    let baseURL = "https://api.openalex.org"
    let session: URLSession
    let credentialManager: any CredentialProviding

    // MARK: - Initialization

    public init(
        session: URLSession = .shared,
        credentialManager: any CredentialProviding = CredentialManager()
    ) {
        self.session = session
        self.credentialManager = credentialManager
        self.rateLimiter = RateLimiter(
            rateLimit: RateLimit(requestsPerInterval: 10, intervalSeconds: 1)
        )
    }

    // MARK: - SourcePlugin

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        await rateLimiter.waitIfNeeded()

        // Parse query to separate search text from filters
        let parsed = OpenAlexQueryParser.parse(query)

        var components = URLComponents(string: "\(baseURL)/works")!
        var queryItems: [URLQueryItem] = []

        // Add search text if present
        let hasSearchText = parsed.searchText != nil && !parsed.searchText!.isEmpty
        if hasSearchText {
            queryItems.append(URLQueryItem(name: "search", value: parsed.searchText!))
        }

        // Add filters if present
        if !parsed.filters.isEmpty {
            let filterString = parsed.filters.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "filter", value: filterString))
        }

        queryItems.append(URLQueryItem(name: "per-page", value: "\(min(maxResults, 200))"))

        // Sort by relevance when there's search text, otherwise by citation count
        // (OpenAlex doesn't allow relevance_score sort without a search query)
        let sortOrder = hasSearchText ? "relevance_score:desc" : "cited_by_count:desc"
        queryItems.append(URLQueryItem(name: "sort", value: sortOrder))

        // Add email for polite pool if available
        if let email = await credentialManager.email(for: "openalex") {
            queryItems.append(URLQueryItem(name: "mailto", value: email))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        return try OpenAlexResponseParser.parseSearchResponse(data)
    }

    /// Search with filter parameters.
    public func searchWithFilters(
        query: String? = nil,
        filters: [String: String] = [:],
        maxResults: Int = 50,
        sortBy: String = "relevance_score:desc"
    ) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/works")!
        var queryItems: [URLQueryItem] = []

        // Add search query if provided
        if let query = query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }

        // Build filter string
        if !filters.isEmpty {
            let filterString = filters.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "filter", value: filterString))
        }

        queryItems.append(URLQueryItem(name: "per-page", value: "\(min(maxResults, 200))"))
        queryItems.append(URLQueryItem(name: "sort", value: sortBy))

        // Add email for polite pool
        if let email = await credentialManager.email(for: "openalex") {
            queryItems.append(URLQueryItem(name: "mailto", value: email))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        return try OpenAlexResponseParser.parseSearchResponse(data)
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        // Fetch the full work details
        let work = try await fetchWork(id: result.id)

        guard let entry = OpenAlexResponseParser.generateBibTeX(from: work) else {
            throw SourceError.parseError("Could not generate BibTeX from OpenAlex work")
        }

        return entry
    }

    public nonisolated var supportsRIS: Bool { true }

    public func fetchRIS(for result: SearchResult) async throws -> RISEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        let work = try await fetchWork(id: result.id)

        guard let entry = OpenAlexResponseParser.generateRIS(from: work) else {
            throw SourceError.parseError("Could not generate RIS from OpenAlex work")
        }

        return entry
    }

    public nonisolated func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        var fields = entry.fields

        // Ensure openalex URL is present if we have an ID
        if let openAlexID = fields["openalex"], !openAlexID.hasPrefix("https://") {
            fields["openalex"] = "https://openalex.org/\(openAlexID)"
        }

        return BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            fields: fields,
            rawBibTeX: entry.rawBibTeX
        )
    }

    // MARK: - Work Fetching

    /// Fetch a single work by its OpenAlex ID.
    public func fetchWork(id: String) async throws -> OpenAlexWork {
        Logger.sources.info("OpenAlex: Fetching work \(id)")

        await rateLimiter.waitIfNeeded()

        // Ensure ID is in correct format
        let workID = id.hasPrefix("W") ? id : "W\(id)"

        var components = URLComponents(string: "\(baseURL)/works/\(workID)")!
        var queryItems: [URLQueryItem] = []

        // Add email for polite pool
        if let email = await credentialManager.email(for: "openalex") {
            queryItems.append(URLQueryItem(name: "mailto", value: email))
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        if httpResponse.statusCode == 404 {
            throw SourceError.notFound("Work not found: \(id)")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        return try OpenAlexResponseParser.parseWork(data)
    }

    /// Fetch a work by DOI.
    public func fetchWorkByDOI(_ doi: String) async throws -> OpenAlexWork {
        // OpenAlex accepts DOI as an ID
        let cleanDOI = doi.hasPrefix("https://doi.org/") ? String(doi.dropFirst(16)) : doi
        return try await fetchWork(id: "https://doi.org/\(cleanDOI)")
    }

    // MARK: - Citations & References

    /// Fetch papers that cite this work.
    public func fetchCitations(for workID: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("OpenAlex: Fetching citations for \(workID)")

        await rateLimiter.waitIfNeeded()

        // Ensure ID format
        let fullID = workID.hasPrefix("https://") ? workID : "https://openalex.org/\(workID)"

        var components = URLComponents(string: "\(baseURL)/works")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "cites:\(fullID)"),
            URLQueryItem(name: "per-page", value: "\(min(maxResults, 200))"),
            URLQueryItem(name: "sort", value: "cited_by_count:desc"),
        ]

        if let email = await credentialManager.email(for: "openalex") {
            components.queryItems?.append(URLQueryItem(name: "mailto", value: email))
        }

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let decoder = JSONDecoder()
        let searchResponse = try decoder.decode(OpenAlexSearchResponse.self, from: data)
        let stubs = searchResponse.results.compactMap { OpenAlexResponseParser.convertWorkToPaperStub($0) }

        Logger.sources.info("OpenAlex: Found \(stubs.count) citations for \(workID)")
        return stubs
    }

    /// Fetch papers that this work references (its bibliography).
    public func fetchReferences(for workID: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("OpenAlex: Fetching references for \(workID)")

        // First fetch the work to get its referenced_works list
        let work = try await fetchWork(id: workID)

        guard let referencedWorks = work.referencedWorks, !referencedWorks.isEmpty else {
            return []
        }

        // Fetch details for up to maxResults references
        let workIDs = Array(referencedWorks.prefix(min(maxResults, 50)))  // Batch limit

        return try await fetchWorksBatch(ids: workIDs)
    }

    /// Fetch related works.
    public func fetchRelatedWorks(for workID: String, maxResults: Int = 50) async throws -> [PaperStub] {
        Logger.sources.info("OpenAlex: Fetching related works for \(workID)")

        // First fetch the work to get its related_works list
        let work = try await fetchWork(id: workID)

        guard let relatedWorks = work.relatedWorks, !relatedWorks.isEmpty else {
            return []
        }

        let workIDs = Array(relatedWorks.prefix(min(maxResults, 50)))
        return try await fetchWorksBatch(ids: workIDs)
    }

    /// Fetch multiple works by ID in a single request.
    public func fetchWorksBatch(ids: [String]) async throws -> [PaperStub] {
        guard !ids.isEmpty else { return [] }

        await rateLimiter.waitIfNeeded()

        // Build filter with multiple IDs
        let idFilter = ids.map { OpenAlexResponseParser.extractOpenAlexID(from: $0) }
            .map { "openalex:\($0)" }
            .joined(separator: "|")

        var components = URLComponents(string: "\(baseURL)/works")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: idFilter),
            URLQueryItem(name: "per-page", value: "\(ids.count)"),
        ]

        if let email = await credentialManager.email(for: "openalex") {
            components.queryItems?.append(URLQueryItem(name: "mailto", value: email))
        }

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let decoder = JSONDecoder()
        let searchResponse = try decoder.decode(OpenAlexSearchResponse.self, from: data)
        return searchResponse.results.compactMap { OpenAlexResponseParser.convertWorkToPaperStub($0) }
    }

    // MARK: - Author Works

    /// Fetch works by an author.
    public func fetchAuthorWorks(authorID: String, maxResults: Int = 200) async throws -> [SearchResult] {
        Logger.sources.info("OpenAlex: Fetching works for author \(authorID)")

        await rateLimiter.waitIfNeeded()

        // Ensure ID format
        let fullID = authorID.hasPrefix("https://") ? authorID :
                     authorID.hasPrefix("A") ? "https://openalex.org/\(authorID)" :
                     "https://openalex.org/A\(authorID)"

        var components = URLComponents(string: "\(baseURL)/works")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "authorships.author.id:\(fullID)"),
            URLQueryItem(name: "per-page", value: "\(min(maxResults, 200))"),
            URLQueryItem(name: "sort", value: "cited_by_count:desc"),
        ]

        if let email = await credentialManager.email(for: "openalex") {
            components.queryItems?.append(URLQueryItem(name: "mailto", value: email))
        }

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let results = try OpenAlexResponseParser.parseSearchResponse(data)
        Logger.sources.info("OpenAlex: Found \(results.count) works for author \(authorID)")
        return results
    }

    // MARK: - Autocomplete

    /// Autocomplete for a specific entity type.
    ///
    /// - Parameters:
    ///   - query: The partial text to complete
    ///   - entityType: The type of entity to search for
    /// - Returns: Array of suggestions
    public func autocomplete(
        query: String,
        entityType: OpenAlexEntityType
    ) async throws -> [OpenAlexAutocompleteSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard trimmedQuery.count >= 2 else {
            return []
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/autocomplete/\(entityType.rawValue)")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmedQuery)
        ]

        if let email = await credentialManager.email(for: "openalex") {
            components.queryItems?.append(URLQueryItem(name: "mailto", value: email))
        }

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid autocomplete URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let decoder = JSONDecoder()
        let autocompleteResponse = try decoder.decode(OpenAlexAutocompleteResponse.self, from: data)

        Logger.sources.debug("OpenAlex autocomplete: \(autocompleteResponse.results.count) results for \(entityType.rawValue)")

        return autocompleteResponse.results
    }

    // MARK: - Preview Count

    /// Get the count of results for a query (for query assistance preview).
    public func fetchPreviewCount(query: String) async throws -> Int {
        await rateLimiter.waitIfNeeded()

        // Parse query to separate search text from filters
        let parsed = OpenAlexQueryParser.parse(query)

        var components = URLComponents(string: "\(baseURL)/works")!
        var queryItems: [URLQueryItem] = []

        // Add search text if present
        if let searchText = parsed.searchText, !searchText.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: searchText))
        }

        // Add filters if present
        if !parsed.filters.isEmpty {
            let filterString = parsed.filters.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "filter", value: filterString))
        }

        queryItems.append(URLQueryItem(name: "per-page", value: "1"))  // Just need the count

        if let email = await credentialManager.email(for: "openalex") {
            queryItems.append(URLQueryItem(name: "mailto", value: email))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: nil)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let decoder = JSONDecoder()
        let searchResponse = try decoder.decode(OpenAlexSearchResponse.self, from: data)
        return searchResponse.meta.count
    }
}

// MARK: - BrowserURLProvider Conformance

extension OpenAlexSource: BrowserURLProvider {

    public static var sourceID: String { "openalex" }

    /// Build the best URL to open in browser for interactive PDF fetch.
    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        // Priority 1: DOI resolver
        if let doi = publication.doi, !doi.isEmpty {
            Logger.pdfBrowser.debug("OpenAlex: Using DOI resolver for: \(doi)")
            return URL(string: "https://doi.org/\(doi)")
        }

        // Priority 2: OpenAlex work page
        if let openAlexID = publication.fields["openalex_id"] {
            Logger.pdfBrowser.debug("OpenAlex: Using work page for: \(openAlexID)")
            return URL(string: "https://openalex.org/works/\(openAlexID)")
        }

        // Priority 3: URL field
        if let urlString = publication.url, let url = URL(string: urlString) {
            return url
        }

        return nil
    }
}
