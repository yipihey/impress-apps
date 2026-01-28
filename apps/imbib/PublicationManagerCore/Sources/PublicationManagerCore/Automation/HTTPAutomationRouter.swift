//
//  HTTPAutomationRouter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-27.
//
//  Route parsing and response handling for HTTP automation API.
//  Implements JSON REST endpoints for browser extension integration.
//

import Foundation
import ImpressAutomation
import OSLog

private let routerLogger = Logger(subsystem: "com.imbib.app", category: "httpRouter")

// MARK: - HTTP Automation Router

/// Routes HTTP requests to appropriate handlers.
///
/// API Endpoints:
/// - `GET /api/status` - Server health and library statistics
/// - `GET /api/search?q=...&limit=...` - Search library
/// - `GET /api/papers/{citeKey}` - Get single paper with BibTeX
/// - `GET /api/export?keys=a,b,c` - Export BibTeX for multiple cite keys
/// - `GET /api/collections` - List all collections
/// - `OPTIONS /*` - CORS preflight
public actor HTTPAutomationRouter: HTTPRouter {

    // MARK: - Dependencies

    private let automationService: AutomationService

    // MARK: - Initialization

    public init(automationService: AutomationService = .shared) {
        self.automationService = automationService
    }

    // MARK: - Routing

    /// Route a request to the appropriate handler.
    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        // Handle CORS preflight
        if request.method == "OPTIONS" {
            return handleCORSPreflight()
        }

        // Only allow GET for now (safe, read-only operations)
        guard request.method == "GET" else {
            return .badRequest("Method not allowed: \(request.method)")
        }

        // Route based on path
        let path = request.path.lowercased()

        if path == "/api/status" {
            return await handleStatus()
        }

        if path == "/api/search" {
            return await handleSearch(request)
        }

        if path.hasPrefix("/api/papers/") {
            let citeKey = String(path.dropFirst("/api/papers/".count))
            return await handleGetPaper(citeKey: citeKey)
        }

        if path == "/api/export" {
            return await handleExport(request)
        }

        if path == "/api/collections" {
            return await handleCollections()
        }

        // Root path - return API info
        if path == "/" || path == "/api" {
            return handleAPIInfo()
        }

        return .notFound("Unknown endpoint: \(request.path)")
    }

    // MARK: - Handlers

    /// GET /api/status
    /// Returns server health and library statistics.
    private func handleStatus() async -> HTTPResponse {
        do {
            // Get library count
            let papers = try await automationService.searchLibrary(query: "", filters: nil)
            let collections = try await automationService.listCollections(libraryID: nil)

            let response: [String: Any] = [
                "status": "ok",
                "version": "1.0.0",
                "libraryCount": papers.count,
                "collectionCount": collections.count,
                "serverPort": await AutomationSettingsStore.shared.settings.httpServerPort
            ]

            return .json(response)

        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    /// GET /api/search?q=...&limit=...&offset=...
    /// Search the library and return matching papers.
    private func handleSearch(_ request: HTTPRequest) async -> HTTPResponse {
        let query = request.queryParams["q"] ?? ""
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 50
        let offset = request.queryParams["offset"].flatMap { Int($0) } ?? 0

        do {
            let filters = SearchFilters(limit: limit, offset: offset)
            let papers = try await automationService.searchLibrary(query: query, filters: filters)

            let paperDicts = papers.map { paperToDict($0) }

            let response: [String: Any] = [
                "status": "ok",
                "query": query,
                "count": papers.count,
                "limit": limit,
                "offset": offset,
                "papers": paperDicts
            ]

            return .json(response)

        } catch AutomationOperationError.unauthorized {
            return .forbidden("Automation API is disabled")
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    /// GET /api/papers/{citeKey}
    /// Get a single paper by cite key.
    private func handleGetPaper(citeKey: String) async -> HTTPResponse {
        guard !citeKey.isEmpty else {
            return .badRequest("Missing cite key")
        }

        // URL decode the cite key
        let decodedKey = citeKey.removingPercentEncoding ?? citeKey

        do {
            let identifier = PaperIdentifier.citeKey(decodedKey)
            guard let paper = try await automationService.getPaper(identifier: identifier) else {
                return .notFound("Paper not found: \(decodedKey)")
            }

            let response: [String: Any] = [
                "status": "ok",
                "paper": paperToDict(paper)
            ]

            return .json(response)

        } catch AutomationOperationError.unauthorized {
            return .forbidden("Automation API is disabled")
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    /// GET /api/export?keys=a,b,c&format=bibtex
    /// Export BibTeX for specified cite keys.
    private func handleExport(_ request: HTTPRequest) async -> HTTPResponse {
        guard let keysParam = request.queryParams["keys"], !keysParam.isEmpty else {
            return .badRequest("Missing 'keys' parameter")
        }

        let keys = keysParam.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let format = request.queryParams["format"] ?? "bibtex"

        guard format == "bibtex" || format == "ris" else {
            return .badRequest("Unsupported format: \(format). Use 'bibtex' or 'ris'.")
        }

        do {
            let identifiers = keys.map { PaperIdentifier.citeKey($0) }

            let exportResult: ExportResult
            if format == "ris" {
                exportResult = try await automationService.exportRIS(identifiers: identifiers)
            } else {
                exportResult = try await automationService.exportBibTeX(identifiers: identifiers)
            }

            let response: [String: Any] = [
                "status": "ok",
                "format": exportResult.format,
                "paperCount": exportResult.paperCount,
                "content": exportResult.content
            ]

            return .json(response)

        } catch AutomationOperationError.unauthorized {
            return .forbidden("Automation API is disabled")
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    /// GET /api/collections
    /// List all collections.
    private func handleCollections() async -> HTTPResponse {
        do {
            let collections = try await automationService.listCollections(libraryID: nil)

            let collectionDicts = collections.map { collection -> [String: Any] in
                [
                    "id": collection.id.uuidString,
                    "name": collection.name,
                    "paperCount": collection.paperCount,
                    "isSmartCollection": collection.isSmartCollection,
                    "libraryID": collection.libraryID?.uuidString as Any,
                    "libraryName": collection.libraryName as Any
                ]
            }

            let response: [String: Any] = [
                "status": "ok",
                "count": collections.count,
                "collections": collectionDicts
            ]

            return .json(response)

        } catch AutomationOperationError.unauthorized {
            return .forbidden("Automation API is disabled")
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    /// CORS preflight response.
    private func handleCORSPreflight() -> HTTPResponse {
        HTTPResponse(
            status: 204,
            statusText: "No Content",
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400"
            ]
        )
    }

    /// Root API info response.
    private func handleAPIInfo() -> HTTPResponse {
        let info: [String: Any] = [
            "name": "imbib HTTP API",
            "version": "1.0.0",
            "endpoints": [
                "GET /api/status": "Server health and library statistics",
                "GET /api/search?q=...": "Search library (params: q, limit, offset)",
                "GET /api/papers/{citeKey}": "Get paper by cite key",
                "GET /api/export?keys=...": "Export BibTeX (params: keys, format)",
                "GET /api/collections": "List all collections"
            ],
            "documentation": "https://github.com/imbib/imbib/wiki/HTTP-API"
        ]
        return .json(info)
    }

    // MARK: - Helpers

    /// Convert a PaperResult to a dictionary for JSON serialization.
    private func paperToDict(_ paper: PaperResult) -> [String: Any] {
        var dict: [String: Any] = [
            "id": paper.id.uuidString,
            "citeKey": paper.citeKey,
            "title": paper.title,
            "authors": paper.authors,
            "isRead": paper.isRead,
            "isStarred": paper.isStarred,
            "hasPDF": paper.hasPDF,
            "bibtex": paper.bibtex,
            "dateAdded": ISO8601DateFormatter().string(from: paper.dateAdded),
            "dateModified": ISO8601DateFormatter().string(from: paper.dateModified)
        ]

        // Optional fields
        if let year = paper.year {
            dict["year"] = year
        }
        if let venue = paper.venue {
            dict["venue"] = venue
        }
        if let abstract = paper.abstract {
            dict["abstract"] = abstract
        }
        if let doi = paper.doi {
            dict["doi"] = doi
        }
        if let arxivID = paper.arxivID {
            dict["arxivID"] = arxivID
        }
        if let bibcode = paper.bibcode {
            dict["bibcode"] = bibcode
        }
        if let pmid = paper.pmid {
            dict["pmid"] = pmid
        }
        if let semanticScholarID = paper.semanticScholarID {
            dict["semanticScholarID"] = semanticScholarID
        }
        if let openAlexID = paper.openAlexID {
            dict["openAlexID"] = openAlexID
        }
        if let citationCount = paper.citationCount {
            dict["citationCount"] = citationCount
        }
        if let webURL = paper.webURL {
            dict["webURL"] = webURL
        }
        if !paper.pdfURLs.isEmpty {
            dict["pdfURLs"] = paper.pdfURLs
        }

        return dict
    }
}

// MARK: - API Response Types

/// Standard API response wrapper.
public struct APIResponse<T: Codable>: Codable, Sendable where T: Sendable {
    public let status: String
    public let data: T?
    public let error: String?

    public init(data: T) {
        self.status = "ok"
        self.data = data
        self.error = nil
    }

    public init(error: String) {
        self.status = "error"
        self.data = nil
        self.error = error
    }
}

/// Status response.
public struct StatusResponse: Codable, Sendable {
    public let version: String
    public let libraryCount: Int
    public let collectionCount: Int
    public let serverPort: UInt16
}

/// Search response.
public struct SearchResponse: Codable, Sendable {
    public let query: String
    public let count: Int
    public let limit: Int
    public let offset: Int
    public let papers: [PaperResult]
}

/// Export response.
public struct ExportResponse: Codable, Sendable {
    public let format: String
    public let paperCount: Int
    public let content: String
}
