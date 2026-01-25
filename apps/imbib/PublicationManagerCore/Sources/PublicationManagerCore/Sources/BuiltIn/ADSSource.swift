//
//  ADSSource.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - NASA ADS Source

/// Source plugin for NASA Astrophysics Data System.
/// Requires API key from https://ui.adsabs.harvard.edu/user/settings/token
public actor ADSSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "ads",
        name: "NASA ADS",
        description: "Astrophysics Data System for astronomy and physics",
        rateLimit: RateLimit(requestsPerInterval: 5, intervalSeconds: 1),  // 5/sec burst (5000/day total)
        credentialRequirement: .apiKey,
        registrationURL: URL(string: "https://ui.adsabs.harvard.edu/user/settings/token"),
        deduplicationPriority: 30,
        iconName: "sparkles"
    )

    let rateLimiter: RateLimiter
    let baseURL = "https://api.adsabs.harvard.edu/v1"
    let session: URLSession
    let credentialManager: any CredentialProviding

    // MARK: - Initialization

    public init(
        session: URLSession = .shared,
        credentialManager: any CredentialProviding = CredentialManager()
    ) {
        self.session = session
        self.credentialManager = credentialManager
        // Use burst-friendly rate: 5 requests/second
        // ADS allows 5000/day but doesn't specify per-second limit
        // 200ms between requests is conservative for interactive use
        self.rateLimiter = RateLimiter(
            rateLimit: RateLimit(requestsPerInterval: 5, intervalSeconds: 1)
        )
    }

    // MARK: - SourcePlugin

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/search/query")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fl", value: "bibcode,title,author,year,pub,abstract,doi,identifier,doctype,esources"),
            URLQueryItem(name: "rows", value: "\(maxResults)"),
            URLQueryItem(name: "sort", value: "score desc"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        if httpResponse.statusCode == 401 {
            throw SourceError.authenticationRequired("ads")
        }

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        return try parseResponse(data)
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        guard let bibcode = result.bibcode else {
            throw SourceError.notFound("No bibcode")
        }

        await rateLimiter.waitIfNeeded()

        let url = URL(string: "\(baseURL)/export/bibtex")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["bibcode": [bibcode]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.network.httpRequest("POST", url: url)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            throw SourceError.notFound("Could not fetch BibTeX")
        }

        // ADS returns JSON with "export" field containing BibTeX
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bibtexString = json["export"] as? String else {
            throw SourceError.parseError("Invalid BibTeX response")
        }

        let parser = BibTeXParserFactory.createParser()
        let entries = try parser.parseEntries(bibtexString)

        guard let entry = entries.first else {
            throw SourceError.parseError("No entry in BibTeX response")
        }

        return entry
    }

    /// Fetch BibTeX for a paper by its ADS bibcode.
    ///
    /// This is a convenience method for importing papers from the citation explorer.
    public func fetchBibTeX(bibcode: String) async throws -> BibTeXEntry {
        Logger.sources.info("ADS: Fetching BibTeX for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        await rateLimiter.waitIfNeeded()

        let url = URL(string: "\(baseURL)/export/bibtex")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["bibcode": [bibcode]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.network.httpRequest("POST", url: url)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            throw SourceError.notFound("Could not fetch BibTeX for \(bibcode)")
        }

        // ADS returns JSON with "export" field containing BibTeX
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bibtexString = json["export"] as? String else {
            throw SourceError.parseError("Invalid BibTeX response")
        }

        let parser = BibTeXParserFactory.createParser()
        let entries = try parser.parseEntries(bibtexString)

        guard let entry = entries.first else {
            throw SourceError.parseError("No entry in BibTeX response")
        }

        return entry
    }

    public nonisolated var supportsRIS: Bool { true }

    public func fetchRIS(for result: SearchResult) async throws -> RISEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        guard let bibcode = result.bibcode else {
            throw SourceError.notFound("No bibcode")
        }

        await rateLimiter.waitIfNeeded()

        let url = URL(string: "\(baseURL)/export/ris")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["bibcode": [bibcode]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.network.httpRequest("POST", url: url)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            throw SourceError.notFound("Could not fetch RIS")
        }

        // ADS returns JSON with "export" field containing RIS
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let risString = json["export"] as? String else {
            throw SourceError.parseError("Invalid RIS response")
        }

        let parser = RISParserFactory.createParser()
        let entries = try parser.parse(risString)

        guard let entry = entries.first else {
            throw SourceError.parseError("No entry in RIS response")
        }

        return entry
    }

    public nonisolated func normalize(_ entry: BibTeXEntry) -> BibTeXEntry {
        var fields = entry.fields

        // Ensure adsurl is present
        if let bibcode = fields["bibcode"], fields["adsurl"] == nil {
            fields["adsurl"] = "https://ui.adsabs.harvard.edu/abs/\(bibcode)"
        }

        return BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            fields: fields,
            rawBibTeX: entry.rawBibTeX
        )
    }

    // MARK: - References & Citations

    /// Fetch papers that this paper references (papers it cites).
    ///
    /// Uses ADS query syntax `references(bibcode:XXXX)` to get full paper metadata
    /// for all papers referenced by the given bibcode.
    ///
    /// - Parameter bibcode: The ADS bibcode of the paper whose references to fetch
    /// - Parameter maxResults: Maximum number of results to return (default 200)
    /// - Returns: Array of PaperStub objects with full metadata
    public func fetchReferences(bibcode: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("ADS: Fetching references for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/search/query")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "references(bibcode:\(bibcode))"),
            URLQueryItem(name: "fl", value: "bibcode,title,author,year,pub,doi,identifier,citation_count,property,abstract,reference"),
            URLQueryItem(name: "rows", value: "\(maxResults)"),
            URLQueryItem(name: "sort", value: "citation_count desc"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        if httpResponse.statusCode == 401 {
            throw SourceError.authenticationRequired("ads")
        }

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let stubs = try parsePaperStubsResponse(data)
        Logger.sources.info("ADS: Found \(stubs.count) references for \(bibcode)")
        return stubs
    }

    /// Fetch papers that cite this paper.
    ///
    /// Uses ADS query syntax `citations(bibcode:XXXX)` to get full paper metadata
    /// for all papers that cite the given bibcode.
    ///
    /// - Parameter bibcode: The ADS bibcode of the paper whose citations to fetch
    /// - Parameter maxResults: Maximum number of results to return (default 200)
    /// - Returns: Array of PaperStub objects with full metadata
    public func fetchCitations(bibcode: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("ADS: Fetching citations for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/search/query")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "citations(bibcode:\(bibcode))"),
            URLQueryItem(name: "fl", value: "bibcode,title,author,year,pub,doi,identifier,citation_count,property,abstract,reference"),
            URLQueryItem(name: "rows", value: "\(maxResults)"),
            URLQueryItem(name: "sort", value: "citation_count desc"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        if httpResponse.statusCode == 401 {
            throw SourceError.authenticationRequired("ads")
        }

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let stubs = try parsePaperStubsResponse(data)
        Logger.sources.info("ADS: Found \(stubs.count) citations for \(bibcode)")
        return stubs
    }

    /// Fetch papers similar to this one by content.
    /// Uses ADS `similar(bibcode:XXXX)` operator.
    public func fetchSimilar(bibcode: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("ADS: Fetching similar papers for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/search/query")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "similar(bibcode:\(bibcode))"),
            URLQueryItem(name: "fl", value: "bibcode,title,author,year,pub,doi,identifier,citation_count,property,abstract,reference"),
            URLQueryItem(name: "rows", value: "\(maxResults)"),
            URLQueryItem(name: "sort", value: "score desc"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        if httpResponse.statusCode == 401 {
            throw SourceError.authenticationRequired("ads")
        }

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let stubs = try parsePaperStubsResponse(data)
        Logger.sources.info("ADS: Found \(stubs.count) similar papers for \(bibcode)")
        return stubs
    }

    /// Fetch papers frequently co-read with this one.
    /// Uses ADS `trending(bibcode:XXXX)` operator.
    public func fetchCoReads(bibcode: String, maxResults: Int = 200) async throws -> [PaperStub] {
        Logger.sources.info("ADS: Fetching co-reads for bibcode: \(bibcode)")

        guard let apiKey = await credentialManager.apiKey(for: "ads") else {
            throw SourceError.authenticationRequired("ads")
        }

        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/search/query")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "trending(bibcode:\(bibcode))"),
            URLQueryItem(name: "fl", value: "bibcode,title,author,year,pub,doi,identifier,citation_count,property,abstract,reference"),
            URLQueryItem(name: "rows", value: "\(maxResults)"),
            URLQueryItem(name: "sort", value: "score desc"),
        ]

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        if httpResponse.statusCode == 401 {
            throw SourceError.authenticationRequired("ads")
        }

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let stubs = try parsePaperStubsResponse(data)
        Logger.sources.info("ADS: Found \(stubs.count) co-reads for \(bibcode)")
        return stubs
    }

    // MARK: - Response Parsing (Using Rust Core)

    /// Parse ADS search response using Rust core parser
    private func parseResponse(_ data: Data) throws -> [SearchResult] {
        guard let json = String(data: data, encoding: .utf8) else {
            throw SourceError.parseError("Invalid UTF-8 encoding in ADS response")
        }

        do {
            let rustResults = try parseAdsSearchResponse(json: json)
            return rustResults.map { rustResult in
                // Convert Rust SearchResult to Swift SearchResult
                // Add ADS-specific URLs that Rust doesn't generate
                var swiftResult = rustResult.toSwiftSearchResult()

                // Add bibtex URL if we have a bibcode
                if let bibcode = swiftResult.bibcode {
                    swiftResult = SearchResult(
                        id: swiftResult.id,
                        sourceID: swiftResult.sourceID,
                        title: swiftResult.title,
                        authors: swiftResult.authors,
                        year: swiftResult.year,
                        venue: swiftResult.venue,
                        abstract: swiftResult.abstract,
                        doi: swiftResult.doi,
                        arxivID: swiftResult.arxivID,
                        pmid: swiftResult.pmid,
                        bibcode: swiftResult.bibcode,
                        pdfLinks: swiftResult.pdfLinks,
                        webURL: swiftResult.webURL ?? URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)"),
                        bibtexURL: URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)/exportcitation")
                    )
                }
                return swiftResult
            }
        } catch {
            throw SourceError.parseError("Rust parser error: \(error)")
        }
    }

    /// Static method to build PDF links from ADS esources field.
    /// Used by both ADSSource (search) and ADSEnrichment (enrichment).
    ///
    /// - Parameters:
    ///   - esources: Array of esource strings from ADS API (e.g., "EPRINT_PDF", "ADS_SCAN")
    ///   - doi: Paper DOI if available
    ///   - arxivID: arXiv ID if available
    ///   - bibcode: ADS bibcode for the paper
    /// - Returns: Array of PDFLink objects
    static func buildPDFLinks(
        esources: [String],
        doi: String?,
        arxivID: String?,
        bibcode: String
    ) -> [PDFLink] {
        var links: [PDFLink] = []

        // Track what we have
        var hasPreprint = false
        var hasPublisher = false

        // Map ADS esource types to our PDFLinkType
        for esource in esources {
            let upper = esource.uppercased()

            if upper == "EPRINT_PDF" {
                // Preprint/arXiv PDF - use direct arXiv URL
                if let arxivID = arxivID,
                   let url = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf") {
                    links.append(PDFLink(url: url, type: .preprint, sourceID: "ads"))
                    hasPreprint = true
                }
            } else if upper == "PUB_PDF" || upper == "PUB_HTML" {
                // Publisher PDF - use DOI resolver (much more reliable than link_gateway)
                if let doi = doi, !doi.isEmpty,
                   let url = URL(string: "https://doi.org/\(doi)") {
                    links.append(PDFLink(url: url, type: .publisher, sourceID: "ads"))
                    hasPublisher = true
                }
            } else if upper == "ADS_PDF" || upper == "ADS_SCAN" {
                // ADS-hosted scans - use direct URL (more reliable than link_gateway)
                // Format: https://articles.adsabs.harvard.edu/pdf/{bibcode}
                if let url = URL(string: "https://articles.adsabs.harvard.edu/pdf/\(bibcode)") {
                    links.append(PDFLink(url: url, type: .adsScan, sourceID: "ads"))
                }
            }
            // Note: We skip AUTHOR_PDF as link_gateway for it is unreliable
        }

        // If no esources but we have arXiv ID, add preprint link
        if !hasPreprint, let arxivID = arxivID,
           let url = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf") {
            links.append(PDFLink(url: url, type: .preprint, sourceID: "ads"))
        }

        // If no publisher link but we have DOI, add it
        if !hasPublisher, let doi = doi, !doi.isEmpty,
           let url = URL(string: "https://doi.org/\(doi)") {
            links.append(PDFLink(url: url, type: .publisher, sourceID: "ads"))
        }

        return links
    }

    /// Parse ADS response into PaperStub array for references/citations queries (using Rust core parser)
    private func parsePaperStubsResponse(_ data: Data) throws -> [PaperStub] {
        guard let json = String(data: data, encoding: .utf8) else {
            throw SourceError.parseError("Invalid UTF-8 encoding in ADS response")
        }

        do {
            let rustStubs = try parseAdsPaperStubsResponse(json: json)
            return rustStubs.toSwiftPaperStubs()
        } catch {
            throw SourceError.parseError("Rust parser error: \(error)")
        }
    }
}

// MARK: - BrowserURLProvider Conformance

extension ADSSource: BrowserURLProvider {

    public static var sourceID: String { "ads" }

    /// Build the best URL to open in browser for interactive PDF fetch.
    ///
    /// Priority order for browser access (targeting published version):
    /// 1. Direct publisher PDF URLs from pdfLinks (e.g., article-pdf URLs)
    /// 2. DOI resolver - redirects to publisher where user can authenticate
    /// 3. ADS abstract page - shows all available full text sources
    ///
    /// Note: We prefer direct PDF URLs over DOI resolver because:
    /// - Direct URLs load the PDF immediately without extra clicks
    /// - DOI resolver goes to landing pages that require navigation
    /// - ADS link_gateway URLs are avoided (they often return 404)
    ///
    /// - Parameter publication: The publication to find a PDF URL for
    /// - Returns: A URL to open in the browser, or nil if this source can't help
    public static func browserPDFURL(for publication: CDPublication) -> URL? {
        // Priority 1: Direct publisher PDF URLs (not gateway URLs)
        // These load the PDF directly without going through landing pages
        for link in publication.pdfLinks {
            if link.type == .publisher,
               isDirectPDFURL(link.url),
               !isGatewayURL(link.url) {
                Logger.pdfBrowser.debug("ADS: Using direct publisher PDF: \(link.url.absoluteString)")
                return link.url
            }
        }

        // Priority 2: DOI resolver - redirects to publisher
        // User will need to navigate from landing page to PDF
        if let doi = publication.doi, !doi.isEmpty {
            Logger.pdfBrowser.debug("ADS: Using DOI resolver for: \(doi)")
            return URL(string: "https://doi.org/\(doi)")
        }

        // Priority 3: ADS abstract page - shows all available full text sources
        // This always works and lets user choose from available links
        if let bibcode = publication.bibcode {
            Logger.pdfBrowser.debug("ADS: Using abstract page for bibcode: \(bibcode)")
            return URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)/abstract")
        }

        return nil
    }

    /// Check if URL appears to be a direct PDF link
    private static func isDirectPDFURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""

        // Direct PDF file extensions
        if path.hasSuffix(".pdf") { return true }

        // Known direct PDF hosts
        if host.contains("arxiv.org") && path.contains("/pdf/") { return true }
        if host.contains("article-pdf") { return true }  // OUP, etc.

        return false
    }

    /// Check if URL is a gateway/redirect URL (often unreliable)
    private static func isGatewayURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()

        // ADS link_gateway URLs are notoriously unreliable
        if urlString.contains("link_gateway") { return true }

        // Generic gateway patterns
        if urlString.contains("/gateway/") { return true }
        if urlString.contains("/redirect/") { return true }

        return false
    }
}
