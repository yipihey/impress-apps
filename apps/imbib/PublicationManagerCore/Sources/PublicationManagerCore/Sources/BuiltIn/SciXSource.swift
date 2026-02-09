//
//  SciXSource.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-08.
//

import Foundation
import OSLog

// MARK: - SciX Source

/// Source plugin for SciX (Science Explorer).
/// SciX is the ADS team's expanded portal covering Earth science, planetary science,
/// astrophysics, heliophysics, and NASA-funded biological/physical sciences.
/// Requires API key from https://scixplorer.org/user/settings/token
public actor SciXSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "scix",
        name: "SciX",
        description: "Science Explorer - Earth, planetary, helio, and life sciences",
        rateLimit: RateLimit(requestsPerInterval: 5000, intervalSeconds: 86400),  // 5000/day
        credentialRequirement: .apiKey,
        registrationURL: URL(string: "https://scixplorer.org/user/settings/token"),
        deduplicationPriority: 31,  // Slightly lower than ADS (30) for astro papers
        iconName: "globe"
    )

    let rateLimiter: RateLimiter
    let baseURL = "https://api.adsabs.harvard.edu/v1"  // Same API as ADS
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
            rateLimit: RateLimit(requestsPerInterval: 5000, intervalSeconds: 86400)
        )
    }

    // MARK: - SourcePlugin

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "scix") else {
            throw SourceError.authenticationRequired("scix")
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
            throw SourceError.authenticationRequired("scix")
        }

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        return try parseResponse(data)
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        guard let apiKey = await credentialManager.apiKey(for: "scix") else {
            throw SourceError.authenticationRequired("scix")
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

        // SciX/ADS returns JSON with "export" field containing BibTeX
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

        guard let apiKey = await credentialManager.apiKey(for: "scix") else {
            throw SourceError.authenticationRequired("scix")
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

        // SciX/ADS returns JSON with "export" field containing RIS
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

        // Ensure scixurl is present
        if let bibcode = fields["bibcode"], fields["scixurl"] == nil {
            fields["scixurl"] = "https://scixplorer.org/abs/\(bibcode)"
        }

        return BibTeXEntry(
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            fields: fields,
            rawBibTeX: entry.rawBibTeX
        )
    }

    // MARK: - Response Parsing (Using Rust Core)

    /// Parse SciX search response using Rust core parser (same format as ADS)
    private func parseResponse(_ data: Data) throws -> [SearchResult] {
        guard let json = String(data: data, encoding: .utf8) else {
            throw SourceError.parseError("Invalid UTF-8 encoding in SciX response")
        }

        do {
            let rustResults = try parseAdsSearchResponse(json: json)
            return rustResults.map { rustResult in
                // Convert Rust SearchResult to Swift SearchResult
                // Change source ID from "ads" to "scix" and update URLs
                var swiftResult = rustResult.toSwiftSearchResult()

                // Override source ID and URLs for SciX
                if let bibcode = swiftResult.bibcode {
                    swiftResult = SearchResult(
                        id: swiftResult.id,
                        sourceID: "scix",  // Override to scix
                        title: swiftResult.title,
                        authors: swiftResult.authors,
                        year: swiftResult.year,
                        venue: swiftResult.venue,
                        abstract: swiftResult.abstract,
                        doi: swiftResult.doi,
                        arxivID: swiftResult.arxivID,
                        pmid: swiftResult.pmid,
                        bibcode: swiftResult.bibcode,
                        pdfLinks: swiftResult.pdfLinks.map { link in
                            // Update sourceID in PDF links to scix
                            PDFLink(url: link.url, type: link.type, sourceID: "scix")
                        },
                        webURL: URL(string: "https://scixplorer.org/abs/\(bibcode)"),
                        bibtexURL: URL(string: "https://scixplorer.org/abs/\(bibcode)/exportcitation")
                    )
                }
                return swiftResult
            }
        } catch {
            throw SourceError.parseError("Rust parser error: \(error)")
        }
    }
}

// MARK: - BrowserURLProvider Conformance

extension SciXSource: BrowserURLProvider {

    public static var sourceID: String { "scix" }

    /// Build the best URL to open in browser for interactive PDF fetch.
    ///
    /// Priority order for browser access (targeting published version):
    /// 1. DOI resolver - redirects to publisher where user can authenticate
    /// 2. SciX abstract page - shows all available full text sources
    ///
    /// - Parameter publication: The publication to find a PDF URL for
    /// - Returns: A URL to open in the browser, or nil if this source can't help
    public static func browserPDFURL(for publication: PublicationModel) -> URL? {
        // Priority 1: DOI resolver - always redirects to publisher
        if let doi = publication.doi, !doi.isEmpty {
            Logger.pdfBrowser.debug("SciX: Using DOI resolver for: \(doi)")
            return URL(string: "https://doi.org/\(doi)")
        }

        // Priority 2: SciX abstract page - shows all available full text sources
        if let bibcode = publication.bibcode {
            Logger.pdfBrowser.debug("SciX: Using abstract page for bibcode: \(bibcode)")
            return URL(string: "https://scixplorer.org/abs/\(bibcode)/abstract")
        }

        return nil
    }
}
