//
//  CrossrefSource.swift
//  PublicationManagerCore
//
//  Crossref DOI registration agency source plugin.
//  Uses the Crossref REST API.
//

import Foundation
import OSLog

// MARK: - Crossref Source

/// Source plugin for Crossref DOI registration agency.
/// Uses the Crossref REST API for searching and metadata retrieval.
///
/// API Documentation: https://api.crossref.org/swagger-ui/index.html
///
/// Note: Crossref has a "polite pool" that provides faster responses when
/// an email is provided in the mailto parameter.
public actor CrossrefSource: SourcePlugin {

    // MARK: - Properties

    public nonisolated let metadata = SourceMetadata(
        id: "crossref",
        name: "Crossref",
        description: "DOI registration agency with broad scholarly coverage",
        rateLimit: RateLimit(requestsPerInterval: 50, intervalSeconds: 1),
        credentialRequirement: .emailOptional,
        registrationURL: nil,
        deduplicationPriority: 40,  // High priority - authoritative DOI source
        iconName: "link"
    )

    private let rateLimiter: RateLimiter
    private let baseURL = "https://api.crossref.org"
    private let session: URLSession
    private let credentialManager: CredentialManager

    // MARK: - Initialization

    public init(
        credentialManager: CredentialManager = .shared,
        session: URLSession = .shared
    ) {
        self.credentialManager = credentialManager
        self.session = session
        self.rateLimiter = RateLimiter(rateLimit: RateLimit(requestsPerInterval: 50, intervalSeconds: 1))
    }

    // MARK: - SourcePlugin

    public func search(query: String, maxResults: Int = 50) async throws -> [SearchResult] {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        await rateLimiter.waitIfNeeded()

        // Cap results to API limits
        let cappedResults = min(maxResults, 1000)

        // Build search URL
        var components = URLComponents(string: "\(baseURL)/works")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "rows", value: "\(cappedResults)"),
            URLQueryItem(name: "sort", value: "relevance"),
            URLQueryItem(name: "order", value: "desc")
        ]

        // Add email for polite pool access (faster rate limits)
        if let email = await credentialManager.email(for: "crossref") {
            queryItems.append(URLQueryItem(name: "mailto", value: email))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("imbib/1.0 (https://github.com/imbib/imbib; mailto:contact@imbib.app)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

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

        return try parseSearchResults(data)
    }

    public func fetchBibTeX(for result: SearchResult) async throws -> BibTeXEntry {
        Logger.sources.entering()
        defer { Logger.sources.exiting() }

        // Extract DOI from result
        guard let doi = result.doi else {
            throw SourceError.invalidResponse("No DOI available for this result")
        }

        await rateLimiter.waitIfNeeded()

        // Fetch work metadata by DOI
        var components = URLComponents(string: "\(baseURL)/works/\(doi)")!

        // Add email for polite pool
        if let email = await credentialManager.email(for: "crossref") {
            components.queryItems = [URLQueryItem(name: "mailto", value: email)]
        }

        guard let url = components.url else {
            throw SourceError.invalidRequest("Invalid URL for DOI: \(doi)")
        }

        Logger.network.httpRequest("GET", url: url)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("imbib/1.0 (https://github.com/imbib/imbib; mailto:contact@imbib.app)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        Logger.network.httpResponse(httpResponse.statusCode, url: url, bytes: data.count)

        guard httpResponse.statusCode == 200 else {
            throw SourceError.networkError(URLError(.badServerResponse))
        }

        return try parseSingleWork(data, doi: doi)
    }

    // MARK: - Parsing

    private func parseSearchResults(_ data: Data) throws -> [SearchResult] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = json?["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else {
            throw SourceError.invalidResponse("Invalid Crossref response format")
        }

        return items.compactMap { item -> SearchResult? in
            parseWorkItem(item)
        }
    }

    private func parseWorkItem(_ item: [String: Any]) -> SearchResult? {
        guard let doi = item["DOI"] as? String else { return nil }

        // Extract title
        let titleArray = item["title"] as? [String]
        let title = titleArray?.first ?? "Untitled"

        // Extract authors
        let authorArray = item["author"] as? [[String: Any]] ?? []
        let authors = authorArray.compactMap { author -> String? in
            let given = author["given"] as? String ?? ""
            let family = author["family"] as? String ?? ""
            if !family.isEmpty {
                return given.isEmpty ? family : "\(given) \(family)"
            }
            return nil
        }

        // Extract year
        let publishedPrint = item["published-print"] as? [String: Any]
        let publishedOnline = item["published-online"] as? [String: Any]
        let issued = item["issued"] as? [String: Any]
        let dateParts = (publishedPrint?["date-parts"] as? [[Int]])?.first
                     ?? (publishedOnline?["date-parts"] as? [[Int]])?.first
                     ?? (issued?["date-parts"] as? [[Int]])?.first
        let year = dateParts?.first

        // Extract journal/container
        let containerArray = item["container-title"] as? [String]
        let journal = containerArray?.first

        // Extract abstract
        let abstract = item["abstract"] as? String

        // Get PDF link if available
        let links = item["link"] as? [[String: Any]] ?? []
        let pdfLink = links.first { ($0["content-type"] as? String)?.contains("pdf") == true }
        let pdfURL = (pdfLink?["URL"] as? String).flatMap { URL(string: $0) }

        return SearchResult(
            id: doi,
            sourceID: "crossref",
            title: cleanHTMLTags(title),
            authors: authors,
            year: year,
            venue: journal,
            abstract: abstract.map { cleanHTMLTags($0) },
            doi: doi,
            pdfURL: pdfURL
        )
    }

    private func parseSingleWork(_ data: Data, doi: String) throws -> BibTeXEntry {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = json?["message"] as? [String: Any] else {
            throw SourceError.invalidResponse("Invalid Crossref work response")
        }

        // Determine entry type
        let crossrefType = message["type"] as? String ?? "misc"
        let entryType = mapCrossrefType(crossrefType)

        // Build fields
        var fields: [String: String] = [:]

        // Title
        if let titleArray = message["title"] as? [String], let title = titleArray.first {
            fields["title"] = cleanHTMLTags(title)
        }

        // Authors
        let authorArray = message["author"] as? [[String: Any]] ?? []
        let authorStrings = authorArray.compactMap { author -> String? in
            let given = author["given"] as? String ?? ""
            let family = author["family"] as? String ?? ""
            if !family.isEmpty {
                return given.isEmpty ? family : "\(family), \(given)"
            }
            return nil
        }
        if !authorStrings.isEmpty {
            fields["author"] = authorStrings.joined(separator: " and ")
        }

        // Year
        let publishedPrint = message["published-print"] as? [String: Any]
        let publishedOnline = message["published-online"] as? [String: Any]
        let issued = message["issued"] as? [String: Any]
        let dateParts = (publishedPrint?["date-parts"] as? [[Int]])?.first
                     ?? (publishedOnline?["date-parts"] as? [[Int]])?.first
                     ?? (issued?["date-parts"] as? [[Int]])?.first

        if let year = dateParts?.first {
            fields["year"] = "\(year)"
        }
        if dateParts?.count ?? 0 >= 2, let month = dateParts?[1] {
            fields["month"] = "\(month)"
        }

        // Journal/Book title
        if let containerArray = message["container-title"] as? [String], let container = containerArray.first {
            if entryType == "inproceedings" || entryType == "incollection" {
                fields["booktitle"] = container
            } else {
                fields["journal"] = container
            }
        }

        // Volume, Issue, Pages
        if let volume = message["volume"] as? String {
            fields["volume"] = volume
        }
        if let issue = message["issue"] as? String {
            fields["number"] = issue
        }
        if let page = message["page"] as? String {
            fields["pages"] = page.replacingOccurrences(of: "-", with: "--")
        }

        // DOI
        fields["doi"] = doi

        // Publisher
        if let publisher = message["publisher"] as? String {
            fields["publisher"] = publisher
        }

        // ISSN
        if let issnArray = message["ISSN"] as? [String], let issn = issnArray.first {
            fields["issn"] = issn
        }

        // ISBN
        if let isbnArray = message["ISBN"] as? [String], let isbn = isbnArray.first {
            fields["isbn"] = isbn
        }

        // Abstract
        if let abstract = message["abstract"] as? String {
            fields["abstract"] = cleanHTMLTags(abstract)
        }

        // URL (DOI URL)
        fields["url"] = "https://doi.org/\(doi)"

        // Generate cite key: AuthorYearFirstWord
        let firstAuthor = authorArray.first?["family"] as? String ?? "Unknown"
        let year = dateParts?.first ?? 0
        let firstTitleWord = fields["title"]?
            .components(separatedBy: .whitespaces)
            .first(where: { $0.count > 3 && !["the", "a", "an", "on", "in", "for"].contains($0.lowercased()) })
            ?? "Paper"
        let citeKey = "\(firstAuthor)\(year)\(firstTitleWord)"
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: entryType,
            fields: fields,
            rawBibTeX: nil
        )
    }

    // MARK: - Helpers

    private func mapCrossrefType(_ crossrefType: String) -> String {
        switch crossrefType {
        case "journal-article": return "article"
        case "book": return "book"
        case "book-chapter": return "incollection"
        case "proceedings-article": return "inproceedings"
        case "dissertation": return "phdthesis"
        case "report": return "techreport"
        case "dataset": return "misc"
        case "posted-content": return "unpublished"
        default: return "misc"
        }
    }

    /// Remove JATS/HTML tags commonly found in Crossref abstracts
    private func cleanHTMLTags(_ text: String) -> String {
        var result = text

        // Remove JATS namespace prefixes
        result = result.replacingOccurrences(of: "<jats:", with: "<")
        result = result.replacingOccurrences(of: "</jats:", with: "</")

        // Remove common HTML tags
        let tagPattern = "<[^>]+>"
        if let regex = try? NSRegularExpression(pattern: tagPattern, options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Decode HTML entities
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
