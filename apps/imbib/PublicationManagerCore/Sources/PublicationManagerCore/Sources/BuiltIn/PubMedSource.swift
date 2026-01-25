//
//  PubMedSource.swift
//  PublicationManagerCore
//
//  PubMed biomedical literature source plugin.
//  Uses the NCBI E-utilities API.
//

import Foundation
import OSLog

// MARK: - PubMed Source

/// Source plugin for PubMed biomedical literature database.
/// Uses the NCBI E-utilities API (esearch, efetch).
///
/// API Documentation: https://www.ncbi.nlm.nih.gov/books/NBK25497/
///
/// Note: NCBI requests that applications not make more than 3 requests per second.
/// If you have an API key, the limit increases to 10 requests per second.
public actor PubMedSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "pubmed",
        name: "PubMed",
        description: "Biomedical literature from MEDLINE and life science journals",
        rateLimit: RateLimit(requestsPerInterval: 3, intervalSeconds: 1),
        credentialRequirement: .apiKeyOptional,
        registrationURL: URL(string: "https://www.ncbi.nlm.nih.gov/account/"),
        deduplicationPriority: 50,
        iconName: "heart.text.square"
    )

    private let rateLimiter: RateLimiter
    private let baseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
    private let session: URLSession
    private let credentialManager: CredentialManager

    // MARK: - Initialization

    public init(
        credentialManager: CredentialManager = .shared,
        session: URLSession = .shared
    ) {
        self.credentialManager = credentialManager
        self.session = session
        self.rateLimiter = RateLimiter(rateLimit: RateLimit(requestsPerInterval: 3, intervalSeconds: 1))
    }

    // MARK: - SourcePlugin

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        // Step 1: Search for PMIDs
        let pmids = try await searchPMIDs(query: query, maxResults: maxResults)

        if pmids.isEmpty {
            return []
        }

        // Step 2: Fetch summaries for all PMIDs
        return try await fetchSummaries(pmids: pmids)
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        // Extract PMID from result.id (format: "pmid:12345678")
        let pmid: String
        if result.id.hasPrefix("pmid:") {
            pmid = String(result.id.dropFirst(5))
        } else {
            pmid = result.id
        }

        await rateLimiter.waitIfNeeded()

        // Fetch full record using efetch with PubMed XML format
        var components = URLComponents(string: "\(baseURL)/efetch.fcgi")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: pmid),
            URLQueryItem(name: "rettype", value: "xml"),
            URLQueryItem(name: "retmode", value: "xml")
        ]

        // Add API key if available
        if let apiKey = await credentialManager.apiKey(for: "pubmed") {
            queryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL for PMID: \(pmid)")
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

        return try parsePubMedXML(data, pmid: pmid)
    }

    // MARK: - Search

    private func searchPMIDs(query: String, maxResults: Int) async throws -> [String] {
        await rateLimiter.waitIfNeeded()

        let cappedResults = min(maxResults, 10000)

        var components = URLComponents(string: "\(baseURL)/esearch.fcgi")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "retmax", value: "\(cappedResults)"),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "sort", value: "relevance")
        ]

        // Add API key if available
        if let apiKey = await credentialManager.apiKey(for: "pubmed") {
            queryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid search URL")
        }

        Logger.network.httpRequest("GET", url: url)

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SourceError.rateLimited(retryAfter: 60)
            }
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let esearchResult = json?["esearchresult"] as? [String: Any],
              let idList = esearchResult["idlist"] as? [String] else {
            throw SourceError.invalidResponse("Invalid esearch response format")
        }

        return idList
    }

    private func fetchSummaries(pmids: [String]) async throws -> [SearchResult] {
        await rateLimiter.waitIfNeeded()

        var components = URLComponents(string: "\(baseURL)/esummary.fcgi")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: pmids.joined(separator: ",")),
            URLQueryItem(name: "retmode", value: "json")
        ]

        if let apiKey = await credentialManager.apiKey(for: "pubmed") {
            queryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid summary URL")
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

        return try parseSummaryResponse(data, pmids: pmids)
    }

    // MARK: - Parsing

    private func parseSummaryResponse(_ data: Data, pmids: [String]) throws -> [SearchResult] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let result = json?["result"] as? [String: Any] else {
            throw SourceError.invalidResponse("Invalid esummary response format")
        }

        var results: [SearchResult] = []

        for pmid in pmids {
            guard let article = result[pmid] as? [String: Any] else { continue }

            let title = article["title"] as? String ?? "Untitled"
            let source = article["source"] as? String  // Journal name

            // Parse authors
            let authorList = article["authors"] as? [[String: Any]] ?? []
            let authors = authorList.compactMap { $0["name"] as? String }

            // Parse date
            let pubDate = article["pubdate"] as? String
            let year = pubDate.flatMap { Int(String($0.prefix(4))) }

            // DOI from article IDs
            let articleIds = article["articleids"] as? [[String: Any]] ?? []
            let doiItem = articleIds.first { ($0["idtype"] as? String) == "doi" }
            let doi = doiItem?["value"] as? String

            // PMC ID for potential full text
            let pmcItem = articleIds.first { ($0["idtype"] as? String) == "pmc" }
            let pmcId = pmcItem?["value"] as? String

            // Construct PDF URL for PMC articles
            let pdfURL: URL?
            if let pmc = pmcId {
                pdfURL = URL(string: "https://www.ncbi.nlm.nih.gov/pmc/articles/\(pmc)/pdf/")
            } else {
                pdfURL = nil
            }

            results.append(SearchResult(
                id: "pmid:\(pmid)",
                sourceID: "pubmed",
                title: cleanTitle(title),
                authors: authors,
                year: year,
                venue: source,
                doi: doi,
                pmid: pmid,
                pdfURL: pdfURL
            ))
        }

        return results
    }

    private func parsePubMedXML(_ data: Data, pmid: String) throws -> BibTeXEntry {
        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw SourceError.invalidResponse("Invalid XML encoding")
        }

        var fields: [String: String] = [:]

        // Extract title
        if let title = extractXMLValue(from: xmlString, tag: "ArticleTitle") {
            fields["title"] = cleanTitle(title)
        }

        // Extract authors
        let authors = extractAuthors(from: xmlString)
        if !authors.isEmpty {
            fields["author"] = authors.joined(separator: " and ")
        }

        // Extract journal
        if let journal = extractXMLValue(from: xmlString, tag: "Title") {
            fields["journal"] = journal
        } else if let medlineTA = extractXMLValue(from: xmlString, tag: "MedlineTA") {
            fields["journal"] = medlineTA
        }

        // Extract volume, issue, pages
        if let volume = extractXMLValue(from: xmlString, tag: "Volume") {
            fields["volume"] = volume
        }
        if let issue = extractXMLValue(from: xmlString, tag: "Issue") {
            fields["number"] = issue
        }
        if let pagination = extractXMLValue(from: xmlString, tag: "MedlinePgn") {
            fields["pages"] = pagination.replacingOccurrences(of: "-", with: "--")
        }

        // Extract year
        if let pubDate = extractPubDate(from: xmlString) {
            if let year = pubDate.year {
                fields["year"] = "\(year)"
            }
            if let month = pubDate.month {
                fields["month"] = month
            }
        }

        // Extract DOI
        if let doi = extractDOI(from: xmlString) {
            fields["doi"] = doi
            fields["url"] = "https://doi.org/\(doi)"
        }

        // Extract abstract
        if let abstract = extractXMLValue(from: xmlString, tag: "AbstractText") {
            fields["abstract"] = abstract
        }

        // Add PMID
        fields["pmid"] = pmid
        fields["url"] = fields["url"] ?? "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/"

        // Generate cite key
        let firstAuthor = authors.first?.components(separatedBy: ",").first ?? "Unknown"
        let year = fields["year"] ?? "0"
        let firstTitleWord = fields["title"]?
            .components(separatedBy: .whitespaces)
            .first(where: { $0.count > 3 && !["the", "a", "an", "on", "in", "for"].contains($0.lowercased()) })
            ?? "Paper"
        let citeKey = "\(firstAuthor)\(year)\(firstTitleWord)"
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: "article",
            fields: fields,
            rawBibTeX: nil
        )
    }

    // MARK: - XML Extraction Helpers

    private func extractXMLValue(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>([^<]+)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAuthors(from xml: String) -> [String] {
        var authors: [String] = []

        // Pattern for Author blocks
        let authorPattern = "<Author[^>]*>.*?</Author>"
        guard let regex = try? NSRegularExpression(pattern: authorPattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let matches = regex.matches(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml))

        for match in matches {
            guard let range = Range(match.range, in: xml) else { continue }
            let authorXML = String(xml[range])

            let lastName = extractXMLValue(from: authorXML, tag: "LastName")
            let foreName = extractXMLValue(from: authorXML, tag: "ForeName")
            let initials = extractXMLValue(from: authorXML, tag: "Initials")

            if let last = lastName {
                if let first = foreName {
                    authors.append("\(last), \(first)")
                } else if let init_ = initials {
                    authors.append("\(last), \(init_)")
                } else {
                    authors.append(last)
                }
            }
        }

        return authors
    }

    private struct PubDate {
        var year: Int?
        var month: String?
    }

    private func extractPubDate(from xml: String) -> PubDate? {
        // Try PubDate first
        if let pubDateMatch = xml.range(of: "<PubDate>.*?</PubDate>", options: .regularExpression) {
            let pubDateXML = String(xml[pubDateMatch])
            let yearStr = extractXMLValue(from: pubDateXML, tag: "Year")
            let monthStr = extractXMLValue(from: pubDateXML, tag: "Month")
            return PubDate(
                year: yearStr.flatMap { Int($0) },
                month: monthStr
            )
        }

        // Try ArticleDate
        if let articleDateMatch = xml.range(of: "<ArticleDate[^>]*>.*?</ArticleDate>", options: .regularExpression) {
            let articleDateXML = String(xml[articleDateMatch])
            let yearStr = extractXMLValue(from: articleDateXML, tag: "Year")
            let monthStr = extractXMLValue(from: articleDateXML, tag: "Month")
            return PubDate(
                year: yearStr.flatMap { Int($0) },
                month: monthStr
            )
        }

        return nil
    }

    private func extractDOI(from xml: String) -> String? {
        // Look for DOI in ArticleId elements
        let pattern = "<ArticleId IdType=\"doi\">([^<]+)</ArticleId>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanTitle(_ title: String) -> String {
        // Remove trailing period if present
        var cleaned = title
        if cleaned.hasSuffix(".") {
            cleaned = String(cleaned.dropLast())
        }
        return cleaned
    }
}
