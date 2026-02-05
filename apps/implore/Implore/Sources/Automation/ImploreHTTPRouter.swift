//
//  ImploreHTTPRouter.swift
//  implore
//
//  HTTP API router for implore automation and MCP integration.
//  Provides endpoints for datasets, figures, and figure export.
//

import Foundation
import ImploreCore
import ImpressAutomation
import ImpressLogging
import OSLog

private let routerLogger = Logger(subsystem: "com.implore.app", category: "httpRouter")

// MARK: - HTTP Automation Router

/// Routes HTTP requests to appropriate handlers for implore.
///
/// API Endpoints (GET):
/// - `GET /api/status` - Server health and app state
/// - `GET /api/datasets` - List open datasets
/// - `GET /api/datasets/{id}` - Get dataset details
/// - `GET /api/figures` - List all figures
/// - `GET /api/figures/{id}` - Get figure details
/// - `GET /api/figures/{id}/export` - Export figure (params: format, width, height, scale)
/// - `GET /api/logs` - Query log entries
///
/// API Endpoints (POST):
/// - `POST /api/figures` - Create a new figure
///
/// API Endpoints (PATCH):
/// - `PATCH /api/figures/{id}` - Update a figure
///
/// API Endpoints (DELETE):
/// - `DELETE /api/figures/{id}` - Delete a figure
///
/// - `OPTIONS /*` - CORS preflight
public actor ImploreHTTPRouter: HTTPRouter {

    // MARK: - Configuration

    /// Default HTTP server port
    public static let defaultPort: UInt16 = 23124

    // MARK: - Initialization

    public init() {}

    // MARK: - Routing

    /// Route a request to the appropriate handler.
    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        // Handle CORS preflight
        if request.method == "OPTIONS" {
            return handleCORSPreflight()
        }

        let path = request.path.lowercased()
        let originalPath = request.path

        switch request.method {
        case "GET":
            return await routeGET(path: path, originalPath: originalPath, request: request)
        case "POST":
            return await routePOST(path: path, request: request)
        case "PATCH":
            return await routePATCH(path: path, originalPath: originalPath, request: request)
        case "DELETE":
            return await routeDELETE(path: path, originalPath: originalPath, request: request)
        default:
            return .badRequest("Method not allowed: \(request.method)")
        }
    }

    // MARK: - GET Routes

    private func routeGET(path: String, originalPath: String, request: HTTPRequest) async -> HTTPResponse {
        if path == "/api/status" {
            return await handleStatus()
        }

        if path == "/api/datasets" {
            return await handleListDatasets()
        }

        // GET /api/datasets/{id}
        if path.hasPrefix("/api/datasets/") && !path.contains("/export") {
            let id = String(originalPath.dropFirst("/api/datasets/".count))
            return await handleGetDataset(id: id)
        }

        if path == "/api/figures" {
            return await handleListFigures(request)
        }

        // GET /api/figures/{id}/export
        if path.hasPrefix("/api/figures/") && path.hasSuffix("/export") {
            let id = String(originalPath.dropFirst("/api/figures/".count).dropLast("/export".count))
            return await handleExportFigure(id: id, request: request)
        }

        // GET /api/figures/{id}
        if path.hasPrefix("/api/figures/") {
            let id = String(originalPath.dropFirst("/api/figures/".count))
            return await handleGetFigure(id: id)
        }

        if path == "/api/logs" {
            return await LogEndpointHandler.handle(request)
        }

        // Root path - return API info
        if path == "/" || path == "/api" {
            return handleAPIInfo()
        }

        return .notFound("Unknown endpoint: \(request.path)")
    }

    // MARK: - POST Routes

    private func routePOST(path: String, request: HTTPRequest) async -> HTTPResponse {
        if path == "/api/figures" {
            return await handleCreateFigure(request)
        }

        return .notFound("Unknown POST endpoint: \(path)")
    }

    // MARK: - PATCH Routes

    private func routePATCH(path: String, originalPath: String, request: HTTPRequest) async -> HTTPResponse {
        // PATCH /api/figures/{id}
        if path.hasPrefix("/api/figures/") {
            let id = String(originalPath.dropFirst("/api/figures/".count))
            return await handleUpdateFigure(id: id, request: request)
        }

        return .notFound("Unknown PATCH endpoint: \(path)")
    }

    // MARK: - DELETE Routes

    private func routeDELETE(path: String, originalPath: String, request: HTTPRequest) async -> HTTPResponse {
        // DELETE /api/figures/{id}
        if path.hasPrefix("/api/figures/") {
            let id = String(originalPath.dropFirst("/api/figures/".count))
            return await handleDeleteFigure(id: id)
        }

        return .notFound("Unknown DELETE endpoint: \(path)")
    }

    // MARK: - Status Handler

    /// GET /api/status
    @MainActor
    private func handleStatus() async -> HTTPResponse {
        let library = LibraryManager.shared.library

        let response: [String: Any] = [
            "status": "ok",
            "app": "implore",
            "version": "1.0.0",
            "port": Int(Self.defaultPort),
            "openDatasets": 0, // TODO: Track open datasets when dataset loading is implemented
            "figureCount": library.figures.count,
            "folderCount": library.folders.count
        ]

        return .json(response)
    }

    // MARK: - Dataset Handlers

    /// GET /api/datasets
    private func handleListDatasets() async -> HTTPResponse {
        // For now, return empty - datasets are session-based and not yet fully integrated
        let response: [String: Any] = [
            "status": "ok",
            "count": 0,
            "datasets": [] as [[String: Any]]
        ]
        return .json(response)
    }

    /// GET /api/datasets/{id}
    private func handleGetDataset(id: String) async -> HTTPResponse {
        // For now, return not found - datasets are session-based
        return .notFound("Dataset not found: \(id)")
    }

    // MARK: - Figure Handlers

    /// GET /api/figures
    @MainActor
    private func handleListFigures(_ request: HTTPRequest) async -> HTTPResponse {
        let datasetFilter = request.queryParams["dataset"]

        let library = LibraryManager.shared.library
        var figures = library.figures

        // Filter by dataset if specified
        if let datasetId = datasetFilter {
            figures = figures.filter { $0.sessionId == datasetId }
        }

        let figureDicts = figures.map { figureToDict($0) }

        let response: [String: Any] = [
            "status": "ok",
            "count": figures.count,
            "figures": figureDicts
        ]

        return .json(response)
    }

    /// GET /api/figures/{id}
    @MainActor
    private func handleGetFigure(id: String) async -> HTTPResponse {
        let figure = LibraryManager.shared.figure(id: id)

        guard let figure = figure else {
            return .notFound("Figure not found: \(id)")
        }

        let response: [String: Any] = [
            "status": "ok",
            "figure": figureToDict(figure)
        ]

        return .json(response)
    }

    /// POST /api/figures
    @MainActor
    private func handleCreateFigure(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }

        guard let datasetId = json["datasetId"] as? String else {
            return .badRequest("Missing required field: datasetId")
        }

        guard let typeString = json["type"] as? String else {
            return .badRequest("Missing required field: type")
        }

        let name = json["name"] as? String ?? "Untitled Figure"
        let title = json["title"] as? String
        let xColumn = json["xColumn"] as? String
        let yColumn = json["yColumn"] as? String
        let colorColumn = json["colorColumn"] as? String
        let width = json["width"] as? Int ?? 800
        let height = json["height"] as? Int ?? 600

        // Create a minimal view state JSON
        var viewState: [String: Any] = [
            "type": typeString,
            "width": width,
            "height": height
        ]
        if let x = xColumn { viewState["xColumn"] = x }
        if let y = yColumn { viewState["yColumn"] = y }
        if let color = colorColumn { viewState["colorColumn"] = color }
        if let t = title { viewState["title"] = t }

        guard let viewStateData = try? JSONSerialization.data(withJSONObject: viewState),
              let viewStateJson = String(data: viewStateData, encoding: .utf8) else {
            return .serverError("Failed to serialize view state")
        }

        let now = ISO8601DateFormatter().string(from: Date())

        // Create the figure using ImploreCore types
        let figure = LibraryFigure(
            id: UUID().uuidString,
            title: name,
            thumbnail: nil,
            sessionId: datasetId,
            viewStateSnapshot: viewStateJson,
            datasetSource: .inMemory(format: "generated"),
            imprintLinks: [],
            tags: [],
            folderId: nil,
            createdAt: now,
            modifiedAt: now
        )

        LibraryManager.shared.addFigure(figure)

        routerLogger.info("Created figure: \(figure.id)")

        let response: [String: Any] = [
            "status": "ok",
            "figure": figureToDict(figure)
        ]

        return .json(response, status: 201)
    }

    /// PATCH /api/figures/{id}
    @MainActor
    private func handleUpdateFigure(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }

        guard var figure = LibraryManager.shared.figure(id: id) else {
            return .notFound("Figure not found: \(id)")
        }

        // Update mutable fields
        if let name = json["name"] as? String {
            figure.title = name
        }

        // Parse and update view state if needed
        if var viewState = try? JSONSerialization.jsonObject(with: Data(figure.viewStateSnapshot.utf8)) as? [String: Any] {
            var updated = false

            if let type = json["type"] as? String {
                viewState["type"] = type
                updated = true
            }
            if let xColumn = json["xColumn"] as? String {
                viewState["xColumn"] = xColumn
                updated = true
            }
            if let yColumn = json["yColumn"] as? String {
                viewState["yColumn"] = yColumn
                updated = true
            }
            if let colorColumn = json["colorColumn"] as? String {
                viewState["colorColumn"] = colorColumn
                updated = true
            }
            if let title = json["title"] as? String {
                viewState["title"] = title
                updated = true
            }
            if let width = json["width"] as? Int {
                viewState["width"] = width
                updated = true
            }
            if let height = json["height"] as? Int {
                viewState["height"] = height
                updated = true
            }

            if updated {
                if let data = try? JSONSerialization.data(withJSONObject: viewState),
                   let jsonString = String(data: data, encoding: .utf8) {
                    figure.viewStateSnapshot = jsonString
                }
            }
        }

        figure.modifiedAt = ISO8601DateFormatter().string(from: Date())

        LibraryManager.shared.updateFigure(figure)

        let response: [String: Any] = [
            "status": "ok",
            "figure": figureToDict(figure)
        ]

        return .json(response)
    }

    /// DELETE /api/figures/{id}
    @MainActor
    private func handleDeleteFigure(id: String) async -> HTTPResponse {
        let exists = LibraryManager.shared.figure(id: id) != nil

        if !exists {
            return .notFound("Figure not found: \(id)")
        }

        LibraryManager.shared.removeFigure(id: id)

        routerLogger.info("Deleted figure: \(id)")

        let response: [String: Any] = [
            "status": "ok",
            "deleted": true
        ]

        return .json(response)
    }

    /// GET /api/figures/{id}/export
    @MainActor
    private func handleExportFigure(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let _ = LibraryManager.shared.figure(id: id) else {
            return .notFound("Figure not found: \(id)")
        }

        let format = request.queryParams["format"] ?? "png"
        let width = request.queryParams["width"].flatMap { Int($0) } ?? 800
        let height = request.queryParams["height"].flatMap { Int($0) } ?? 600
        let scale = request.queryParams["scale"].flatMap { Double($0) } ?? 1.0

        guard ["png", "svg", "pdf"].contains(format) else {
            return .badRequest("Unsupported format: \(format). Use 'png', 'svg', or 'pdf'.")
        }

        // For now, return a placeholder response indicating export capability
        // Full implementation would render the figure using Metal/Core Graphics
        let response: [String: Any] = [
            "status": "ok",
            "id": id,
            "format": format,
            "width": Int(Double(width) * scale),
            "height": Int(Double(height) * scale),
            "data": "" // TODO: Generate actual export data
        ]

        routerLogger.info("Export requested for figure \(id) as \(format)")

        return .json(response)
    }

    // MARK: - CORS Handler

    /// CORS preflight response.
    private func handleCORSPreflight() -> HTTPResponse {
        HTTPResponse(
            status: 204,
            statusText: "No Content",
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400"
            ]
        )
    }

    // MARK: - API Info

    /// Root API info response.
    private func handleAPIInfo() -> HTTPResponse {
        let info: [String: Any] = [
            "name": "implore HTTP API",
            "version": "1.0.0",
            "endpoints": [
                // GET endpoints
                "GET /api/status": "Server health and app state",
                "GET /api/datasets": "List open datasets",
                "GET /api/datasets/{id}": "Get dataset details with columns",
                "GET /api/figures": "List all figures (params: dataset)",
                "GET /api/figures/{id}": "Get figure configuration",
                "GET /api/figures/{id}/export": "Export figure (params: format, width, height, scale)",
                "GET /api/logs": "Query log entries (params: limit, level, category, search, after)",
                // POST endpoints
                "POST /api/figures": "Create a figure (body: datasetId, type, xColumn?, yColumn?, ...)",
                // PATCH endpoints
                "PATCH /api/figures/{id}": "Update a figure",
                // DELETE endpoints
                "DELETE /api/figures/{id}": "Delete a figure"
            ],
            "documentation": "https://github.com/yipihey/impress-apps/wiki/implore-HTTP-API"
        ]
        return .json(info)
    }

    // MARK: - Helpers

    /// Parse JSON body from an HTTP request.
    nonisolated private func parseJSONBody(_ request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body, !body.isEmpty,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Convert a LibraryFigure to a dictionary for JSON serialization.
    nonisolated private func figureToDict(_ figure: LibraryFigure) -> [String: Any] {
        var viewState: [String: Any] = [:]
        if let data = figure.viewStateSnapshot.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            viewState = parsed
        }

        var dict: [String: Any] = [
            "id": figure.id,
            "name": figure.title,
            "datasetId": figure.sessionId,
            "type": viewState["type"] as? String ?? "custom",
            "width": viewState["width"] as? Int ?? 800,
            "height": viewState["height"] as? Int ?? 600,
            "createdAt": figure.createdAt,
            "modifiedAt": figure.modifiedAt
        ]

        if let xColumn = viewState["xColumn"] as? String {
            dict["xColumn"] = xColumn
        }
        if let yColumn = viewState["yColumn"] as? String {
            dict["yColumn"] = yColumn
        }
        if let colorColumn = viewState["colorColumn"] as? String {
            dict["colorColumn"] = colorColumn
        }
        if let title = viewState["title"] as? String {
            dict["title"] = title
        }
        if !figure.tags.isEmpty {
            dict["tags"] = figure.tags
        }
        if let folderId = figure.folderId {
            dict["folderId"] = folderId
        }

        return dict
    }
}
