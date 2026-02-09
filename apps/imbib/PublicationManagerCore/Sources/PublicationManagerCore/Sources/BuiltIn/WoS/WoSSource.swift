//
//  WoSSource.swift
//  PublicationManagerCore
//
//  Source plugin for Web of Science (WoS) API.
//  Provides search, BibTeX/RIS fetching, citations, references, and related records.
//

import Foundation
import OSLog

// MARK: - Web of Science Source

/// Source plugin for Web of Science.
///
/// Requires API key from https://developer.clarivate.com/apis/wos-starter
///
/// ## Features
/// - Full-text and field-specific search with WoS query syntax
/// - BibTeX and RIS export
/// - Citation and reference retrieval
/// - Related records discovery
///
/// ## Rate Limits
/// WoS Starter API: 5 requests per second
public actor WoSSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "wos",
        name: "Web of Science",
        description: "Comprehensive coverage of peer-reviewed research literature",
        rateLimit: RateLimit(requestsPerInterval: 5, intervalSeconds: 1),
        credentialRequirement: .apiKey,
        registrationURL: URL(string: "https://developer.clarivate.com/apis/wos-starter"),
        deduplicationPriority: 25,  // High priority - authoritative source
        iconName: "globe.americas"
    )

    let rateLimiter: RateLimiter
    let baseURL = "https://wos-api.clarivate.com/api/wos"
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
            rateLimit: RateLimit(requestsPerInterval: 5, intervalSeconds: 1)
        )
    }

    // MARK: - SourcePlugin Protocol

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "wos") else {
            throw SourceError.authenticationRequired("wos")
        }

        await rateLimiter.waitIfNeeded()

        // Build search URL
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "databaseId", value: "WOS"),
            URLQueryItem(name: "usrQuery", value: query),
            URLQueryItem(name: "count", value: "\(min(maxResults, 100))"),  // WoS max per request
            URLQueryItem(name: "firstRecord", value: "1"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-ApiKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        // Handle error responses
        if httpResponse.statusCode == 401 {
            throw SourceError.authenticationRequired("wos")
        }

        if httpResponse.statusCode == 429 {
            throw SourceError.rateLimited(retryAfter: nil)
        }

        if httpResponse.statusCode != 200 {
            if let errorInfo = WoSResponseParser.parseError(from: data) {
                throw SourceError.networkError(NSError(
                    domain: "WoS",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: errorInfo.message]
                ))
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let (results, _) = try WoSResponseParser.parseSearchResults(from: data)
        Logger.sources.info("WoS: Found \(results.count) results for query")
        return results
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        // Fetch full record to generate BibTeX
        let record = try await fetchRecord(ut: result.id)
        return WoSResponseParser.generateBibTeX(from: record)
    }

    public nonisolated var supportsRIS: Bool { true }

    public func fetchRIS(for result: SearchResult) async throws -> RISEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        // Fetch full record to generate RIS
        let record = try await fetchRecord(ut: result.id)
        return WoSResponseParser.generateRIS(from: record)
    }

    public nonisolated func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        var fields = entry.fields

        // Ensure WoS URL is present
        if let ut = fields["wos-ut"], fields["wos-url"] == nil {
            fields["wos-url"] = "https://www.webofscience.com/wos/woscc/full-record/WOS:\(ut)"
        }

        return BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            fields: fields,
            rawBibTeX: entry.rawBibTeX
        )
    }

    // MARK: - Citations & References

    /// Fetch papers that cite this paper.
    ///
    /// - Parameter ut: The WoS UT (Unique Title) identifier
    /// - Parameter maxResults: Maximum number of results (default 100)
    /// - Returns: Array of PaperStub for citing papers
    public func fetchCitations(ut: String, maxResults: Int = 100) async throws -> [PaperStub] {
        Logger.sources.info("WoS: Fetching citations for UT: \(ut)")

        guard let apiKey = await credentialManager.apiKey(for: "wos") else {
            throw SourceError.authenticationRequired("wos")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/citing")!
        components.queryItems = [
            URLQueryItem(name: "databaseId", value: "WOS"),
            URLQueryItem(name: "uniqueId", value: "WOS:\(ut)"),
            URLQueryItem(name: "count", value: "\(min(maxResults, 100))"),
            URLQueryItem(name: "firstRecord", value: "1"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-ApiKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let stubs = try WoSResponseParser.parseCitingArticles(from: data)
        Logger.sources.info("WoS: Found \(stubs.count) citations for \(ut)")
        return stubs
    }

    /// Fetch papers that cite this paper by DOI.
    ///
    /// First resolves the DOI to a WoS UT, then fetches citations.
    public func fetchCitations(doi: String, maxResults: Int = 100) async throws -> [PaperStub] {
        // First, search for the paper by DOI to get its UT
        let results = try await search(query: "DO=\(doi)", maxResults: 1)
        guard let result = results.first else {
            throw SourceError.notFound("Paper with DOI \(doi) not found in WoS")
        }
        return try await fetchCitations(ut: result.id, maxResults: maxResults)
    }

    /// Fetch papers that this paper references.
    ///
    /// - Parameter ut: The WoS UT (Unique Title) identifier
    /// - Parameter maxResults: Maximum number of results (default 100)
    /// - Returns: Array of PaperStub for referenced papers
    public func fetchReferences(ut: String, maxResults: Int = 100) async throws -> [PaperStub] {
        Logger.sources.info("WoS: Fetching references for UT: \(ut)")

        guard let apiKey = await credentialManager.apiKey(for: "wos") else {
            throw SourceError.authenticationRequired("wos")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/references")!
        components.queryItems = [
            URLQueryItem(name: "databaseId", value: "WOS"),
            URLQueryItem(name: "uniqueId", value: "WOS:\(ut)"),
            URLQueryItem(name: "count", value: "\(min(maxResults, 100))"),
            URLQueryItem(name: "firstRecord", value: "1"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-ApiKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let stubs = try WoSResponseParser.parseReferences(from: data)
        Logger.sources.info("WoS: Found \(stubs.count) references for \(ut)")
        return stubs
    }

    /// Fetch papers that this paper references by DOI.
    public func fetchReferences(doi: String, maxResults: Int = 100) async throws -> [PaperStub] {
        let results = try await search(query: "DO=\(doi)", maxResults: 1)
        guard let result = results.first else {
            throw SourceError.notFound("Paper with DOI \(doi) not found in WoS")
        }
        return try await fetchReferences(ut: result.id, maxResults: maxResults)
    }

    /// Fetch papers related to this paper (co-citation analysis).
    ///
    /// - Parameter ut: The WoS UT (Unique Title) identifier
    /// - Parameter maxResults: Maximum number of results (default 100)
    /// - Returns: Array of PaperStub for related papers
    public func fetchRelatedRecords(ut: String, maxResults: Int = 100) async throws -> [PaperStub] {
        Logger.sources.info("WoS: Fetching related records for UT: \(ut)")

        guard let apiKey = await credentialManager.apiKey(for: "wos") else {
            throw SourceError.authenticationRequired("wos")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/related")!
        components.queryItems = [
            URLQueryItem(name: "databaseId", value: "WOS"),
            URLQueryItem(name: "uniqueId", value: "WOS:\(ut)"),
            URLQueryItem(name: "count", value: "\(min(maxResults, 100))"),
            URLQueryItem(name: "firstRecord", value: "1"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-ApiKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let stubs = try WoSResponseParser.parseRelatedRecords(from: data)
        Logger.sources.info("WoS: Found \(stubs.count) related records for \(ut)")
        return stubs
    }

    /// Fetch related records by DOI.
    public func fetchRelatedRecords(doi: String, maxResults: Int = 100) async throws -> [PaperStub] {
        let results = try await search(query: "DO=\(doi)", maxResults: 1)
        guard let result = results.first else {
            throw SourceError.notFound("Paper with DOI \(doi) not found in WoS")
        }
        return try await fetchRelatedRecords(ut: result.id, maxResults: maxResults)
    }

    // MARK: - Helper Methods

    /// Fetch a single record by UT.
    private func fetchRecord(ut: String) async throws -> WoSRecord {
        guard let apiKey = await credentialManager.apiKey(for: "wos") else {
            throw SourceError.authenticationRequired("wos")
        }

        await rateLimiter.waitIfNeeded()

        // Use /id endpoint for single record fetch
        let recordId = ut.hasPrefix("WOS:") ? ut : "WOS:\(ut)"
        var components = URLComponents(string: "\(baseURL)/id/\(recordId)")!
        components.queryItems = [
            URLQueryItem(name: "databaseId", value: "WOS"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-ApiKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        if httpResponse.statusCode == 404 {
            throw SourceError.notFound("Record not found: \(ut)")
        }

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        // Parse the single record response
        let (results, _) = try WoSResponseParser.parseSearchResults(from: data)
        guard let record = results.first else {
            throw SourceError.notFound("No record data for: \(ut)")
        }

        // We need to return the WoSRecord, not SearchResult
        // Re-parse to get the raw WoSRecord
        let decoder = JSONDecoder()
        let searchResponse = try decoder.decode(WoSSearchResponse.self, from: data)
        guard let wosRecord = searchResponse.queryResult.records?.first else {
            throw SourceError.notFound("No record data for: \(ut)")
        }

        return wosRecord
    }

    /// Validate API key by making a minimal request.
    public func validateAPIKey(_ apiKey: String) async throws -> Bool {
        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "databaseId", value: "WOS"),
            URLQueryItem(name: "usrQuery", value: "DO=10.1038/nature"),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "firstRecord", value: "1"),
        ]

        guard let url = components.url else {
            return false
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-ApiKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - EnrichmentPlugin Conformance

extension WoSSource: EnrichmentPlugin {

    public nonisolated var enrichmentCapabilities: EnrichmentCapabilities {
        [.citationCount, .references, .citations, .venue]
    }

    public func enrich(
        identifiers: [IdentifierType: String],
        existingData: EnrichmentData?
    ) async throws -> EnrichmentResult {
        Logger.sources.info("WoS: Enriching publication")

        // Try to find the paper by DOI first, then by other identifiers
        var ut: String?

        if let doi = identifiers[.doi] {
            let results = try await search(query: "DO=\(doi)", maxResults: 1)
            ut = results.first?.id
        }

        guard let foundUT = ut else {
            throw EnrichmentError.notFound
        }

        // Fetch the full record
        let record = try await fetchRecord(ut: foundUT)

        // Build enrichment data
        let data = EnrichmentData(
            citationCount: record.citations?.count,
            venue: record.source?.sourceTitle,
            source: .wos,  // Note: Need to add .wos to EnrichmentSource enum
            fetchedAt: Date()
        )

        return EnrichmentResult(data: data)
    }
}

// MARK: - BrowserURLProvider Conformance

extension WoSSource: BrowserURLProvider {

    public static var sourceID: String { "wos" }

    /// Build the best URL to open in browser for WoS record.
    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        // WoS doesn't provide direct PDF access, but we can link to the record
        // which shows all available full text options

        // Try DOI first
        if let doi = publication.doi, !doi.isEmpty {
            return URL(string: "https://doi.org/\(doi)")
        }

        // Try WoS UT from fields
        if let ut = publication.fields["wos-ut"] {
            return URL(string: "https://www.webofscience.com/wos/woscc/full-record/WOS:\(ut)")
        }

        return nil
    }
}
