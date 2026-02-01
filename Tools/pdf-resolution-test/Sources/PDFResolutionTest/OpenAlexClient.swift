//
//  OpenAlexClient.swift
//  PDFResolutionTest
//
//  Simple OpenAlex client for fetching OA locations.
//

import Foundation

// MARK: - OpenAlex Client

/// Simple client for fetching OA locations from OpenAlex.
public actor OpenAlexClient {

    private let session: URLSession
    private let baseURL = "https://api.openalex.org"
    private var email: String?

    public init(session: URLSession? = nil, email: String? = nil) {
        self.email = email

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.httpAdditionalHeaders = [
                "User-Agent": "PDFResolutionTest/1.0 (https://github.com/example/imbib)"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    /// Set email for polite pool access (higher rate limits)
    public func setEmail(_ email: String?) {
        self.email = email
    }

    // MARK: - OA Location Lookup

    /// Fetch OA locations for a DOI.
    public func fetchOALocations(doi: String) async throws -> OpenAlexLookupResult {
        // Clean DOI
        let cleanDOI = doi.hasPrefix("https://doi.org/") ? String(doi.dropFirst(16)) : doi

        var components = URLComponents(string: "\(baseURL)/works/https://doi.org/\(cleanDOI)")!

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "id,doi,open_access,locations,best_oa_location")
        ]

        if let email = email {
            queryItems.append(URLQueryItem(name: "mailto", value: email))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw OpenAlexError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAlexError.badResponse
        }

        if httpResponse.statusCode == 404 {
            return OpenAlexLookupResult(doi: cleanDOI, locations: [], bestPDFURL: nil, oaStatus: nil)
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw OpenAlexError.rateLimited
            }
            throw OpenAlexError.httpError(httpResponse.statusCode)
        }

        return try parseOAResponse(data, doi: cleanDOI)
    }

    /// Batch fetch OA locations for multiple DOIs.
    public func fetchOALocationsBatch(dois: [String]) async throws -> [String: OpenAlexLookupResult] {
        guard !dois.isEmpty else { return [:] }

        // OpenAlex supports up to 50 IDs per request
        let cleanDOIs = dois.map { doi in
            doi.hasPrefix("https://doi.org/") ? String(doi.dropFirst(16)) : doi
        }

        let filter = cleanDOIs.map { "doi:https://doi.org/\($0)" }.joined(separator: "|")

        var components = URLComponents(string: "\(baseURL)/works")!

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "select", value: "id,doi,open_access,locations,best_oa_location"),
            URLQueryItem(name: "per-page", value: "\(min(dois.count, 50))")
        ]

        if let email = email {
            queryItems.append(URLQueryItem(name: "mailto", value: email))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw OpenAlexError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAlexError.badResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw OpenAlexError.rateLimited
            }
            throw OpenAlexError.httpError(httpResponse.statusCode)
        }

        return try parseBatchResponse(data)
    }

    // MARK: - Response Parsing

    private func parseOAResponse(_ data: Data, doi: String) throws -> OpenAlexLookupResult {
        let decoder = JSONDecoder()
        let work = try decoder.decode(OpenAlexWorkSlim.self, from: data)

        let locations = work.locations?.compactMap { convertLocation($0) } ?? []
        let bestPDFURL = work.bestOaLocation?.pdfUrl.flatMap { URL(string: $0) }
        let oaStatus = work.openAccess?.oaStatus

        return OpenAlexLookupResult(
            doi: doi,
            locations: locations,
            bestPDFURL: bestPDFURL,
            oaStatus: oaStatus
        )
    }

    private func parseBatchResponse(_ data: Data) throws -> [String: OpenAlexLookupResult] {
        let decoder = JSONDecoder()
        let response = try decoder.decode(OpenAlexSearchResponseSlim.self, from: data)

        var results: [String: OpenAlexLookupResult] = [:]

        for work in response.results {
            guard let doi = work.doi?.replacingOccurrences(of: "https://doi.org/", with: "") else {
                continue
            }

            let locations = work.locations?.compactMap { convertLocation($0) } ?? []
            let bestPDFURL = work.bestOaLocation?.pdfUrl.flatMap { URL(string: $0) }
            let oaStatus = work.openAccess?.oaStatus

            results[doi] = OpenAlexLookupResult(
                doi: doi,
                locations: locations,
                bestPDFURL: bestPDFURL,
                oaStatus: oaStatus
            )
        }

        return results
    }

    private func convertLocation(_ location: OpenAlexLocationSlim) -> OpenAlexOALocation {
        OpenAlexOALocation(
            isOA: location.isOa ?? false,
            pdfURL: location.pdfUrl.flatMap { URL(string: $0) },
            landingPageURL: location.landingPageUrl.flatMap { URL(string: $0) },
            sourceName: location.source?.displayName,
            version: location.version,
            license: location.license
        )
    }
}

// MARK: - OpenAlex Errors

public enum OpenAlexError: Error, LocalizedError {
    case invalidURL
    case badResponse
    case rateLimited
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OpenAlex URL"
        case .badResponse:
            return "Bad response from OpenAlex"
        case .rateLimited:
            return "Rate limited by OpenAlex"
        case .httpError(let code):
            return "HTTP error \(code) from OpenAlex"
        }
    }
}

// MARK: - Slim Response Types

/// Minimal OpenAlex work response for OA lookup
private struct OpenAlexWorkSlim: Decodable {
    let id: String?
    let doi: String?
    let openAccess: OpenAlexOASlim?
    let locations: [OpenAlexLocationSlim]?
    let bestOaLocation: OpenAlexLocationSlim?

    enum CodingKeys: String, CodingKey {
        case id, doi
        case openAccess = "open_access"
        case locations
        case bestOaLocation = "best_oa_location"
    }
}

private struct OpenAlexSearchResponseSlim: Decodable {
    let results: [OpenAlexWorkSlim]
}

private struct OpenAlexOASlim: Decodable {
    let isOa: Bool?
    let oaStatus: String?

    enum CodingKeys: String, CodingKey {
        case isOa = "is_oa"
        case oaStatus = "oa_status"
    }
}

private struct OpenAlexLocationSlim: Decodable {
    let isOa: Bool?
    let pdfUrl: String?
    let landingPageUrl: String?
    let source: OpenAlexSourceSlim?
    let version: String?
    let license: String?

    enum CodingKeys: String, CodingKey {
        case isOa = "is_oa"
        case pdfUrl = "pdf_url"
        case landingPageUrl = "landing_page_url"
        case source, version, license
    }
}

private struct OpenAlexSourceSlim: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}
