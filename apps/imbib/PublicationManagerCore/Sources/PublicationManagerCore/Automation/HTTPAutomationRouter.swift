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
/// API Endpoints (GET):
/// - `GET /api/status` - Server health and library statistics
/// - `GET /api/search?q=...&limit=...` - Search library
/// - `GET /api/papers/{citeKey}` - Get single paper with BibTeX
/// - `GET /api/export?keys=a,b,c` - Export BibTeX for multiple cite keys
/// - `GET /api/collections` - List all collections
/// - `GET /api/libraries` - List all libraries
/// - `GET /api/collections/{id}/papers` - List papers in a collection
/// - `GET /api/tags` - List tags
/// - `GET /api/tags/tree` - Get tag tree
/// - `GET /api/logs` - Query log entries
/// - `GET /api/libraries/{id}/participants` - List library participants
/// - `GET /api/libraries/{id}/activity` - Get library activity feed
/// - `GET /api/papers/{citeKey}/comments` - List comments for a paper
/// - `GET /api/papers/{citeKey}/assignments` - List assignments for a paper
/// - `GET /api/papers/{citeKey}/annotations` - List PDF annotations for a paper
/// - `GET /api/papers/{citeKey}/notes` - Get publication notes
/// - `GET /api/libraries/{id}/assignments` - List assignments in a library
///
/// API Endpoints (POST):
/// - `POST /api/papers/add` - Add papers by identifier
/// - `POST /api/collections` - Create a collection
/// - `POST /api/papers/download-pdfs` - Download PDFs
/// - `POST /api/papers/{citeKey}/comments` - Add comment to a paper
/// - `POST /api/papers/{citeKey}/annotations` - Add PDF annotation
/// - `POST /api/assignments` - Create an assignment
/// - `POST /api/libraries/{id}/share` - Share a library
///
/// API Endpoints (PUT):
/// - `PUT /api/papers/read` - Mark papers read/unread
/// - `PUT /api/papers/star` - Toggle star
/// - `PUT /api/papers/tags` - Add/remove tags
/// - `PUT /api/papers/flag` - Set/clear flags
/// - `PUT /api/papers/{citeKey}/notes` - Update publication notes
/// - `PUT /api/collections/{id}/papers` - Add/remove papers from collection
/// - `PUT /api/libraries/{id}/participants/{participantID}` - Set participant permission
///
/// API Endpoints (DELETE):
/// - `DELETE /api/papers` - Delete papers
/// - `DELETE /api/collections/{id}` - Delete a collection
/// - `DELETE /api/comments/{id}` - Delete a comment
/// - `DELETE /api/annotations/{id}` - Delete a PDF annotation
/// - `DELETE /api/assignments/{id}` - Delete an assignment
/// - `DELETE /api/libraries/{id}/share` - Unshare a library
///
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

        let path = request.path.lowercased()
        let originalPath = request.path

        switch request.method {
        case "GET":
            return await routeGET(path: path, originalPath: originalPath, request: request)
        case "POST":
            return await routePOST(path: path, request: request)
        case "PUT":
            return await routePUT(path: path, originalPath: originalPath, request: request)
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

        if path == "/api/search" {
            return await handleSearch(request)
        }

        if path == "/api/search/external" {
            return await handleSearchExternal(request)
        }

        // GET /api/papers/{citeKey}/comments
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/comments") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/comments".count))
            return await handleListComments(citeKey: citeKey)
        }

        // GET /api/papers/{citeKey}/assignments
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/assignments") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/assignments".count))
            return await handleListPaperAssignments(citeKey: citeKey)
        }

        // GET /api/papers/{citeKey}/annotations
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/annotations") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/annotations".count))
            return await handleListAnnotations(citeKey: citeKey, request: request)
        }

        // GET /api/papers/{citeKey}/notes
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/notes") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/notes".count))
            return await handleGetNotes(citeKey: citeKey)
        }

        if path.hasPrefix("/api/papers/") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count))
            return await handleGetPaper(citeKey: citeKey)
        }

        if path == "/api/export" {
            return await handleExport(request)
        }

        if path == "/api/collections" {
            return await handleCollections()
        }

        // GET /api/collections/{id}/papers
        if path.hasPrefix("/api/collections/") && path.hasSuffix("/papers") {
            let segment = String(originalPath.dropFirst("/api/collections/".count).dropLast("/papers".count))
            guard let collectionID = UUID(uuidString: segment) else {
                return .badRequest("Invalid collection ID")
            }
            return await handleCollectionPapers(collectionID: collectionID, request: request)
        }

        // GET /api/libraries/{id}/participants
        if path.hasPrefix("/api/libraries/") && path.hasSuffix("/participants") {
            let segment = String(originalPath.dropFirst("/api/libraries/".count).dropLast("/participants".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleListParticipants(libraryID: libraryID)
        }

        // GET /api/libraries/{id}/activity
        if path.hasPrefix("/api/libraries/") && path.hasSuffix("/activity") {
            let segment = String(originalPath.dropFirst("/api/libraries/".count).dropLast("/activity".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleLibraryActivity(libraryID: libraryID, request: request)
        }

        // GET /api/libraries/{id}/assignments
        if path.hasPrefix("/api/libraries/") && path.hasSuffix("/assignments") {
            let segment = String(originalPath.dropFirst("/api/libraries/".count).dropLast("/assignments".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleListLibraryAssignments(libraryID: libraryID)
        }

        if path == "/api/libraries" {
            return await handleListLibraries()
        }

        if path == "/api/tags/tree" {
            return await handleTagTree()
        }

        if path == "/api/tags" {
            return await handleListTags(request)
        }

        if path == "/api/logs" {
            return await LogEndpointHandler.handle(request)
        }

        if path == "/api/commands" {
            return handleCommands()
        }

        // Root path - return API info
        if path == "/" || path == "/api" {
            return handleAPIInfo()
        }

        return .notFound("Unknown endpoint: \(request.path)")
    }

    // MARK: - POST Routes

    private func routePOST(path: String, request: HTTPRequest) async -> HTTPResponse {
        if path == "/api/papers/add" {
            return await handleAddPapers(request)
        }

        if path == "/api/libraries" {
            return await handleCreateLibrary(request)
        }

        if path == "/api/collections" {
            return await handleCreateCollection(request)
        }

        if path == "/api/libraries/add-papers" {
            return await handleAddToLibrary(request)
        }

        if path == "/api/collections/add-papers" {
            return await handleAddToCollection(request)
        }

        if path == "/api/papers/download-pdfs" {
            return await handleDownloadPDFs(request)
        }

        if path == "/api/assignments" {
            return await handleCreateAssignment(request)
        }

        // POST /api/papers/{citeKey}/comments
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/comments") {
            let citeKey = String(request.path.dropFirst("/api/papers/".count).dropLast("/comments".count))
            return await handleAddComment(citeKey: citeKey, request: request)
        }

        // POST /api/papers/{citeKey}/annotations
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/annotations") {
            let citeKey = String(request.path.dropFirst("/api/papers/".count).dropLast("/annotations".count))
            return await handleAddAnnotation(citeKey: citeKey, request: request)
        }

        // POST /api/libraries/{id}/share
        if path.hasPrefix("/api/libraries/") && path.hasSuffix("/share") {
            let segment = String(request.path.dropFirst("/api/libraries/".count).dropLast("/share".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleShareLibrary(libraryID: libraryID)
        }

        return .notFound("Unknown POST endpoint: \(path)")
    }

    // MARK: - PUT Routes

    private func routePUT(path: String, originalPath: String, request: HTTPRequest) async -> HTTPResponse {
        if path == "/api/papers/read" {
            return await handleMarkRead(request)
        }

        if path == "/api/papers/star" {
            return await handleToggleStar(request)
        }

        if path == "/api/papers/tags" {
            return await handleUpdateTags(request)
        }

        if path == "/api/papers/flag" {
            return await handleUpdateFlag(request)
        }

        // PUT /api/papers/{citeKey}/notes
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/notes") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/notes".count))
            return await handleUpdateNotes(citeKey: citeKey, request: request)
        }

        // PUT /api/collections/{id}/papers
        if path.hasPrefix("/api/collections/") && path.hasSuffix("/papers") {
            let segment = String(originalPath.dropFirst("/api/collections/".count).dropLast("/papers".count))
            guard let collectionID = UUID(uuidString: segment) else {
                return .badRequest("Invalid collection ID")
            }
            return await handleUpdateCollectionPapers(collectionID: collectionID, request: request)
        }

        // PUT /api/libraries/{id}/participants/{participantID}
        if path.hasPrefix("/api/libraries/") && path.contains("/participants/") {
            // Extract library ID and participant ID
            let withoutPrefix = String(originalPath.dropFirst("/api/libraries/".count))
            let parts = withoutPrefix.components(separatedBy: "/participants/")
            guard parts.count == 2,
                  let libraryID = UUID(uuidString: parts[0]),
                  !parts[1].isEmpty else {
                return .badRequest("Invalid library or participant ID")
            }
            let participantID = parts[1]
            return await handleSetParticipantPermission(libraryID: libraryID, participantID: participantID, request: request)
        }

        return .notFound("Unknown PUT endpoint: \(path)")
    }

    // MARK: - DELETE Routes

    private func routeDELETE(path: String, originalPath: String, request: HTTPRequest) async -> HTTPResponse {
        if path == "/api/papers" {
            return await handleDeletePapers(request)
        }

        // DELETE /api/comments/{id}
        if path.hasPrefix("/api/comments/") {
            let segment = String(originalPath.dropFirst("/api/comments/".count))
            guard let commentID = UUID(uuidString: segment) else {
                return .badRequest("Invalid comment ID")
            }
            return await handleDeleteComment(commentID: commentID)
        }

        // DELETE /api/annotations/{id}
        if path.hasPrefix("/api/annotations/") {
            let segment = String(originalPath.dropFirst("/api/annotations/".count))
            guard let annotationID = UUID(uuidString: segment) else {
                return .badRequest("Invalid annotation ID")
            }
            return await handleDeleteAnnotation(annotationID: annotationID)
        }

        // DELETE /api/assignments/{id}
        if path.hasPrefix("/api/assignments/") {
            let segment = String(originalPath.dropFirst("/api/assignments/".count))
            guard let assignmentID = UUID(uuidString: segment) else {
                return .badRequest("Invalid assignment ID")
            }
            return await handleDeleteAssignment(assignmentID: assignmentID)
        }

        // DELETE /api/libraries/{id}/share
        if path.hasPrefix("/api/libraries/") && path.hasSuffix("/share") {
            let segment = String(originalPath.dropFirst("/api/libraries/".count).dropLast("/share".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleUnshareLibrary(libraryID: libraryID, request: request)
        }

        // DELETE /api/collections/{id}
        if path.hasPrefix("/api/collections/") {
            let segment = String(originalPath.dropFirst("/api/collections/".count))
            guard let collectionID = UUID(uuidString: segment) else {
                return .badRequest("Invalid collection ID")
            }
            return await handleDeleteCollection(collectionID: collectionID)
        }

        return .notFound("Unknown DELETE endpoint: \(path)")
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

    /// GET /api/search?q=...&limit=...&offset=...&tag=...&flag=...&read=...&collection=...&library=...
    /// Search the library and return matching papers.
    private func handleSearch(_ request: HTTPRequest) async -> HTTPResponse {
        let query = request.queryParams["q"] ?? ""
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 50
        let offset = request.queryParams["offset"].flatMap { Int($0) } ?? 0

        // Parse extended filter params
        let tags: [String]? = request.queryParams["tag"].map {
            $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let flagColor = request.queryParams["flag"]
        let isRead: Bool? = request.queryParams["read"].map { $0 == "true" }
        let collection: [UUID]? = request.queryParams["collection"].flatMap { UUID(uuidString: $0) }.map { [$0] }
        let library: [UUID]? = request.queryParams["library"].flatMap { UUID(uuidString: $0) }.map { [$0] }

        let iso8601 = ISO8601DateFormatter()
        let addedAfter = request.queryParams["addedAfter"].flatMap { iso8601.date(from: $0) }
        let addedBefore = request.queryParams["addedBefore"].flatMap { iso8601.date(from: $0) }

        do {
            let filters = SearchFilters(
                isRead: isRead,
                collections: collection,
                libraries: library,
                limit: limit,
                offset: offset,
                tags: tags,
                flagColor: flagColor,
                addedAfter: addedAfter,
                addedBefore: addedBefore
            )
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

    /// GET /api/search/external?q=...&source=...&limit=...
    /// Search external sources (ADS, arXiv, Crossref, etc.) for papers.
    private func handleSearchExternal(_ request: HTTPRequest) async -> HTTPResponse {
        guard let query = request.queryParams["q"], !query.isEmpty else {
            return .badRequest("Missing required 'q' parameter")
        }
        let source = request.queryParams["source"]
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 20

        do {
            let results = try await automationService.searchExternal(query: query, source: source, maxResults: limit)

            let resultDicts: [[String: Any]] = results.map { r in
                var dict: [String: Any] = [
                    "title": r.title,
                    "authors": r.authors,
                    "venue": r.venue,
                    "abstract": r.abstract,
                    "sourceID": r.sourceID,
                    "identifier": r.bestIdentifier,
                ]
                if let year = r.year { dict["year"] = year }
                if let doi = r.doi { dict["doi"] = doi }
                if let arxiv = r.arxivID { dict["arxivID"] = arxiv }
                if let bib = r.bibcode { dict["bibcode"] = bib }
                return dict
            }

            let response: [String: Any] = [
                "status": "ok",
                "query": query,
                "source": source ?? "all",
                "count": results.count,
                "results": resultDicts
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
                "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400"
            ]
        )
    }

    /// GET /api/commands
    /// Returns available commands for the universal command palette.
    private func handleCommands() -> HTTPResponse {
        let shortcuts = KeyboardShortcutsSettings.defaults.bindings
        var commands: [[String: Any]] = []

        for binding in shortcuts {
            let command: [String: Any] = [
                "id": "imbib.\(binding.id)",
                "name": binding.displayName,
                "category": binding.category.displayName,
                "app": "imbib",
                "shortcut": binding.displayShortcut,
                "icon": iconForCategory(binding.category),
                "isEnabled": true,
                "uri": "impress://imbib/command/\(binding.notificationName)"
            ]
            commands.append(command)
        }

        let response: [String: Any] = [
            "status": "ok",
            "app": "imbib",
            "version": "3.0.0",
            "commands": commands
        ]

        return .json(response)
    }

    private func iconForCategory(_ category: ShortcutCategory) -> String {
        switch category {
        case .navigation: return "arrow.up.arrow.down"
        case .views: return "rectangle.3.group"
        case .focus: return "scope"
        case .paperActions: return "doc.text"
        case .clipboard: return "doc.on.clipboard"
        case .filtering: return "line.3.horizontal.decrease.circle"
        case .inboxTriage: return "tray"
        case .pdfViewer: return "doc.richtext"
        case .fileOperations: return "folder"
        case .app: return "app"
        }
    }

    /// Root API info response.
    private func handleAPIInfo() -> HTTPResponse {
        let info: [String: Any] = [
            "name": "imbib HTTP API",
            "version": "3.0.0",
            "endpoints": [
                // GET endpoints
                "GET /api/status": "Server health and library statistics",
                "GET /api/search?q=...": "Search library (params: q, limit, offset, tag, flag, read, collection, library, addedAfter, addedBefore)",
                "GET /api/search/external?q=...": "Search external sources like ADS, arXiv, Crossref (params: q, source, limit)",
                "GET /api/papers/{citeKey}": "Get paper by cite key",
                "GET /api/export?keys=...": "Export BibTeX (params: keys, format)",
                "GET /api/collections": "List all collections",
                "GET /api/collections/{id}/papers": "List papers in a collection (params: limit, offset)",
                "GET /api/libraries": "List all libraries with sharing info",
                "GET /api/tags": "List tags (params: prefix, limit)",
                "GET /api/tags/tree": "Get formatted tag tree",
                "GET /api/logs": "Query in-app log entries (params: limit, level, category, search, after)",
                "GET /api/commands": "List available commands for universal command palette",
                // Collaboration GET endpoints
                "GET /api/libraries/{id}/participants": "List library participants",
                "GET /api/libraries/{id}/activity": "Get library activity feed (params: limit)",
                "GET /api/libraries/{id}/assignments": "List assignments in a library",
                "GET /api/papers/{citeKey}/comments": "List comments for a paper",
                "GET /api/papers/{citeKey}/assignments": "List assignments for a paper",
                "GET /api/papers/{citeKey}/annotations": "List annotations for a paper (params: page)",
                "GET /api/papers/{citeKey}/notes": "Get notes for a paper",
                // POST endpoints
                "POST /api/papers/add": "Add papers by identifier (body: identifiers, collection?, library?, downloadPDFs?)",
                "POST /api/libraries/add-papers": "Add existing papers to a library (body: libraryID, identifiers)",
                "POST /api/collections/add-papers": "Add existing papers to a collection (body: collectionID, identifiers)",
                "POST /api/collections": "Create a collection (body: name, libraryID?, isSmartCollection?, predicate?)",
                "POST /api/papers/download-pdfs": "Download PDFs (body: identifiers)",
                "POST /api/papers/{citeKey}/comments": "Add comment to paper (body: text, parentCommentID?)",
                "POST /api/assignments": "Create assignment (body: citeKey|identifier, assigneeName, libraryID, note?, dueDate?)",
                "POST /api/libraries/{id}/share": "Share a library",
                "POST /api/papers/{citeKey}/annotations": "Add annotation (body: type, pageNumber, contents?, selectedText?, color?)",
                // PUT endpoints
                "PUT /api/papers/read": "Mark papers read/unread (body: identifiers, read)",
                "PUT /api/papers/star": "Toggle star (body: identifiers)",
                "PUT /api/papers/tags": "Add/remove tags (body: identifiers, action, tag)",
                "PUT /api/papers/flag": "Set/clear flag (body: identifiers, color|null, style?, length?)",
                "PUT /api/collections/{id}/papers": "Add/remove papers (body: action, identifiers)",
                "PUT /api/libraries/{id}/participants/{participantID}": "Set participant permission (body: permission)",
                "PUT /api/papers/{citeKey}/notes": "Update notes (body: notes)",
                // DELETE endpoints
                "DELETE /api/papers": "Delete papers (body: identifiers)",
                "DELETE /api/collections/{id}": "Delete a collection",
                "DELETE /api/comments/{id}": "Delete a comment",
                "DELETE /api/assignments/{id}": "Delete an assignment",
                "DELETE /api/libraries/{id}/share": "Unshare a library (body: keepCopy?)",
                "DELETE /api/annotations/{id}": "Delete an annotation"
            ],
            "documentation": "https://github.com/yipihey/impress-apps/wiki/HTTP-API"
        ]
        return .json(info)
    }

    // MARK: - POST Handlers

    /// POST /api/papers/add
    private func handleAddPapers(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }

        let collectionID = (json["collection"] as? String).flatMap { UUID(uuidString: $0) }
        let libraryID = (json["library"] as? String).flatMap { UUID(uuidString: $0) }
        let downloadPDFs = json["downloadPDFs"] as? Bool ?? false

        do {
            let result = try await automationService.addPapers(
                identifiers: identifiers,
                collection: collectionID,
                library: libraryID,
                downloadPDFs: downloadPDFs
            )

            let response: [String: Any] = [
                "status": "ok",
                "added": result.added.map { paperToDict($0) },
                "duplicates": result.duplicates,
                "failed": result.failed
            ]
            return .json(response, status: 201)
        } catch {
            return mapError(error)
        }
    }

    /// POST /api/collections
    /// POST /api/libraries
    private func handleCreateLibrary(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            return .badRequest("Missing 'name' field")
        }

        do {
            let library = try await automationService.createLibrary(name: name)
            let response: [String: Any] = [
                "status": "ok",
                "library": [
                    "id": library.id.uuidString,
                    "name": library.name,
                    "paperCount": library.paperCount,
                    "collectionCount": library.collectionCount,
                    "isDefault": library.isDefault
                ]
            ]
            return .json(response, status: 201)
        } catch {
            return mapError(error)
        }
    }

    private func handleCreateCollection(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            return .badRequest("Missing 'name' field")
        }

        let libraryID = (json["libraryID"] as? String).flatMap { UUID(uuidString: $0) }
        let isSmartCollection = json["isSmartCollection"] as? Bool ?? false
        let predicate = json["predicate"] as? String

        do {
            let collection = try await automationService.createCollection(
                name: name,
                libraryID: libraryID,
                isSmartCollection: isSmartCollection,
                predicate: predicate
            )

            let response: [String: Any] = [
                "status": "ok",
                "collection": [
                    "id": collection.id.uuidString,
                    "name": collection.name,
                    "paperCount": collection.paperCount,
                    "isSmartCollection": collection.isSmartCollection,
                    "libraryID": collection.libraryID?.uuidString as Any,
                    "libraryName": collection.libraryName as Any
                ]
            ]
            return .json(response, status: 201)
        } catch {
            return mapError(error)
        }
    }

    /// POST /api/libraries/add-papers
    private func handleAddToLibrary(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let libraryIDStr = json["libraryID"] as? String,
              let libraryID = UUID(uuidString: libraryIDStr) else {
            return .badRequest("Missing or invalid 'libraryID' field")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }

        do {
            let result = try await automationService.addPapersToLibrary(
                identifiers: identifiers,
                libraryID: libraryID
            )
            return .json([
                "status": "ok",
                "assigned": result.assigned,
                "notFound": result.notFound
            ])
        } catch {
            return mapError(error)
        }
    }

    /// POST /api/collections/add-papers
    private func handleAddToCollection(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let collectionIDStr = json["collectionID"] as? String,
              let collectionID = UUID(uuidString: collectionIDStr) else {
            return .badRequest("Missing or invalid 'collectionID' field")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }

        do {
            let result = try await automationService.addPapersToCollection(
                identifiers: identifiers,
                collectionID: collectionID
            )
            return .json([
                "status": "ok",
                "assigned": result.assigned,
                "notFound": result.notFound
            ])
        } catch {
            return mapError(error)
        }
    }

    /// POST /api/papers/download-pdfs
    private func handleDownloadPDFs(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }

        do {
            let result = try await automationService.downloadPDFs(identifiers: identifiers)
            let response: [String: Any] = [
                "status": "ok",
                "downloaded": result.downloaded,
                "alreadyHad": result.alreadyHad,
                "failed": result.failed
            ]
            return .json(response)
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Collaboration POST Handlers

    /// POST /api/papers/{citeKey}/comments
    private func handleAddComment(citeKey: String, request: HTTPRequest) async -> HTTPResponse {
        guard !citeKey.isEmpty else {
            return .badRequest("Missing cite key")
        }
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let text = json["text"] as? String, !text.isEmpty else {
            return .badRequest("Missing 'text' field")
        }

        let decodedKey = citeKey.removingPercentEncoding ?? citeKey
        let identifier = PaperIdentifier.citeKey(decodedKey)
        let parentCommentID = (json["parentCommentID"] as? String).flatMap { UUID(uuidString: $0) }

        do {
            let comment = try await automationService.addComment(
                text: text,
                publicationIdentifier: identifier,
                parentCommentID: parentCommentID
            )
            return .json([
                "status": "ok",
                "comment": commentToDict(comment)
            ], status: 201)
        } catch {
            return mapError(error)
        }
    }

    /// POST /api/assignments
    private func handleCreateAssignment(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let assigneeName = json["assigneeName"] as? String, !assigneeName.isEmpty else {
            return .badRequest("Missing 'assigneeName' field")
        }
        guard let libraryIDString = json["libraryID"] as? String,
              let libraryID = UUID(uuidString: libraryIDString) else {
            return .badRequest("Missing or invalid 'libraryID' field")
        }

        // Get paper identifier - can be citeKey, DOI, etc.
        let identifier: PaperIdentifier
        if let citeKey = json["citeKey"] as? String, !citeKey.isEmpty {
            identifier = .citeKey(citeKey)
        } else if let id = json["identifier"] as? String, !id.isEmpty {
            identifier = PaperIdentifier.fromString(id)
        } else {
            return .badRequest("Missing paper identifier (provide 'citeKey' or 'identifier')")
        }

        let note = json["note"] as? String
        let dueDate: Date?
        if let dueDateString = json["dueDate"] as? String {
            let iso8601 = ISO8601DateFormatter()
            dueDate = iso8601.date(from: dueDateString)
        } else {
            dueDate = nil
        }

        do {
            let assignment = try await automationService.createAssignment(
                publicationIdentifier: identifier,
                assigneeName: assigneeName,
                libraryID: libraryID,
                note: note,
                dueDate: dueDate
            )
            return .json([
                "status": "ok",
                "assignment": assignmentToDict(assignment)
            ], status: 201)
        } catch {
            return mapError(error)
        }
    }

    /// POST /api/libraries/{id}/share
    private func handleShareLibrary(libraryID: UUID) async -> HTTPResponse {
        do {
            let result = try await automationService.shareLibrary(libraryID: libraryID)
            var response: [String: Any] = [
                "status": "ok",
                "libraryID": result.libraryID.uuidString,
                "isShared": result.isShared
            ]
            if let shareURL = result.shareURL {
                response["shareURL"] = shareURL
            }
            return .json(response, status: 201)
        } catch {
            return mapError(error)
        }
    }

    // MARK: - PUT Handlers

    /// PUT /api/papers/read
    private func handleMarkRead(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }
        guard let read = json["read"] as? Bool else {
            return .badRequest("Missing 'read' boolean field")
        }

        do {
            let count: Int
            if read {
                count = try await automationService.markAsRead(identifiers: identifiers)
            } else {
                count = try await automationService.markAsUnread(identifiers: identifiers)
            }
            return .json(["status": "ok", "updated": count])
        } catch {
            return mapError(error)
        }
    }

    /// PUT /api/papers/star
    private func handleToggleStar(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }

        do {
            let count = try await automationService.toggleStar(identifiers: identifiers)
            return .json(["status": "ok", "updated": count])
        } catch {
            return mapError(error)
        }
    }

    /// PUT /api/papers/tags
    private func handleUpdateTags(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }
        guard let action = json["action"] as? String, (action == "add" || action == "remove") else {
            return .badRequest("Missing or invalid 'action' field (use 'add' or 'remove')")
        }
        guard let tag = json["tag"] as? String, !tag.isEmpty else {
            return .badRequest("Missing 'tag' field")
        }

        do {
            let count: Int
            if action == "add" {
                count = try await automationService.addTag(path: tag, to: identifiers)
            } else {
                count = try await automationService.removeTag(path: tag, from: identifiers)
            }
            return .json(["status": "ok", "updated": count])
        } catch {
            return mapError(error)
        }
    }

    /// PUT /api/papers/flag
    private func handleUpdateFlag(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }

        do {
            let count: Int
            // color == null or missing means clear flag
            if let color = json["color"] as? String {
                let style = json["style"] as? String
                let length = json["length"] as? String
                count = try await automationService.setFlag(
                    color: color,
                    style: style,
                    length: length,
                    papers: identifiers
                )
            } else {
                count = try await automationService.clearFlag(papers: identifiers)
            }
            return .json(["status": "ok", "updated": count])
        } catch {
            return mapError(error)
        }
    }

    /// PUT /api/collections/{id}/papers
    private func handleUpdateCollectionPapers(collectionID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }
        guard let action = json["action"] as? String, (action == "add" || action == "remove") else {
            return .badRequest("Missing or invalid 'action' field (use 'add' or 'remove')")
        }

        do {
            let count: Int
            if action == "add" {
                count = try await automationService.addToCollection(papers: identifiers, collectionID: collectionID)
            } else {
                count = try await automationService.removeFromCollection(papers: identifiers, collectionID: collectionID)
            }
            return .json(["status": "ok", "updated": count])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Collaboration PUT Handlers

    /// PUT /api/libraries/{id}/participants/{participantID}
    private func handleSetParticipantPermission(libraryID: UUID, participantID: String, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let permission = json["permission"] as? String,
              (permission == "readOnly" || permission == "readWrite") else {
            return .badRequest("Missing or invalid 'permission' field (use 'readOnly' or 'readWrite')")
        }

        do {
            try await automationService.setParticipantPermission(
                libraryID: libraryID,
                participantID: participantID,
                permission: permission
            )
            return .json(["status": "ok", "updated": true])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - DELETE Handlers

    /// DELETE /api/papers
    private func handleDeletePapers(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifiers = parseIdentifiers(json) else {
            return .badRequest("Missing or invalid 'identifiers' array")
        }

        do {
            let count = try await automationService.deletePapers(identifiers: identifiers)
            return .json(["status": "ok", "deleted": count])
        } catch {
            return mapError(error)
        }
    }

    /// DELETE /api/collections/{id}
    private func handleDeleteCollection(collectionID: UUID) async -> HTTPResponse {
        do {
            let deleted = try await automationService.deleteCollection(collectionID: collectionID)
            return .json(["status": "ok", "deleted": deleted])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Collaboration DELETE Handlers

    /// DELETE /api/comments/{id}
    private func handleDeleteComment(commentID: UUID) async -> HTTPResponse {
        do {
            try await automationService.deleteComment(commentID: commentID)
            return .json(["status": "ok", "deleted": true])
        } catch {
            return mapError(error)
        }
    }

    /// DELETE /api/assignments/{id}
    private func handleDeleteAssignment(assignmentID: UUID) async -> HTTPResponse {
        do {
            try await automationService.deleteAssignment(assignmentID: assignmentID)
            return .json(["status": "ok", "deleted": true])
        } catch {
            return mapError(error)
        }
    }

    /// DELETE /api/libraries/{id}/share
    private func handleUnshareLibrary(libraryID: UUID, request: HTTPRequest) async -> HTTPResponse {
        let json = parseJSONBody(request)
        let keepCopy = json?["keepCopy"] as? Bool ?? true

        do {
            try await automationService.leaveShare(libraryID: libraryID, keepCopy: keepCopy)
            return .json(["status": "ok", "unshared": true])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Additional GET Handlers

    /// GET /api/libraries
    private func handleListLibraries() async -> HTTPResponse {
        do {
            let libraries = try await automationService.listLibraries()
            let libraryDicts = libraries.map { library -> [String: Any] in
                [
                    "id": library.id.uuidString,
                    "name": library.name,
                    "paperCount": library.paperCount,
                    "collectionCount": library.collectionCount,
                    "isDefault": library.isDefault,
                    "isInbox": library.isInbox,
                    "isShared": library.isShared,
                    "isShareOwner": library.isShareOwner,
                    "participantCount": library.participantCount,
                    "canEdit": library.canEdit
                ]
            }
            return .json([
                "status": "ok",
                "count": libraries.count,
                "libraries": libraryDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    /// GET /api/collections/{id}/papers
    private func handleCollectionPapers(collectionID: UUID, request: HTTPRequest) async -> HTTPResponse {
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 50
        let offset = request.queryParams["offset"].flatMap { Int($0) } ?? 0

        do {
            let result = try await automationService.listPapersInCollection(
                collectionID: collectionID,
                limit: limit,
                offset: offset
            )
            let paperDicts = result.papers.map { paperToDict($0) }
            return .json([
                "status": "ok",
                "collectionID": collectionID.uuidString,
                "count": result.totalCount,
                "limit": limit,
                "offset": offset,
                "papers": paperDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    /// GET /api/tags
    private func handleListTags(_ request: HTTPRequest) async -> HTTPResponse {
        let prefix = request.queryParams["prefix"]
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 100

        do {
            let tags = try await automationService.listTags(matching: prefix, limit: limit)
            let tagDicts = tags.map { tag -> [String: Any] in
                var dict: [String: Any] = [
                    "id": tag.id.uuidString,
                    "name": tag.name,
                    "canonicalPath": tag.canonicalPath,
                    "useCount": tag.useCount,
                    "publicationCount": tag.publicationCount
                ]
                if let parentPath = tag.parentPath {
                    dict["parentPath"] = parentPath
                }
                return dict
            }
            return .json([
                "status": "ok",
                "count": tags.count,
                "tags": tagDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    /// GET /api/tags/tree
    private func handleTagTree() async -> HTTPResponse {
        do {
            let tree = try await automationService.getTagTree()
            return .json([
                "status": "ok",
                "tree": tree
            ])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Collaboration GET Handlers

    /// GET /api/libraries/{id}/participants
    private func handleListParticipants(libraryID: UUID) async -> HTTPResponse {
        do {
            let participants = try await automationService.listParticipants(libraryID: libraryID)
            let participantDicts = participants.map { p -> [String: Any] in
                var dict: [String: Any] = [
                    "id": p.id,
                    "permission": p.permission,
                    "isOwner": p.isOwner,
                    "status": p.status
                ]
                if let displayName = p.displayName {
                    dict["displayName"] = displayName
                }
                if let email = p.email {
                    dict["email"] = email
                }
                return dict
            }
            return .json([
                "status": "ok",
                "libraryID": libraryID.uuidString,
                "count": participants.count,
                "participants": participantDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    /// GET /api/libraries/{id}/activity
    private func handleLibraryActivity(libraryID: UUID, request: HTTPRequest) async -> HTTPResponse {
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 50

        do {
            let activities = try await automationService.recentActivity(libraryID: libraryID, limit: limit)
            let iso8601 = ISO8601DateFormatter()
            let activityDicts = activities.map { a -> [String: Any] in
                var dict: [String: Any] = [
                    "id": a.id.uuidString,
                    "activityType": a.activityType,
                    "date": iso8601.string(from: a.date)
                ]
                if let name = a.actorDisplayName {
                    dict["actorDisplayName"] = name
                }
                if let title = a.targetTitle {
                    dict["targetTitle"] = title
                }
                if let targetID = a.targetID {
                    dict["targetID"] = targetID.uuidString
                }
                if let detail = a.detail {
                    dict["detail"] = detail
                }
                return dict
            }
            return .json([
                "status": "ok",
                "libraryID": libraryID.uuidString,
                "count": activities.count,
                "activities": activityDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    /// GET /api/papers/{citeKey}/comments
    private func handleListComments(citeKey: String) async -> HTTPResponse {
        guard !citeKey.isEmpty else {
            return .badRequest("Missing cite key")
        }

        let decodedKey = citeKey.removingPercentEncoding ?? citeKey
        let identifier = PaperIdentifier.citeKey(decodedKey)

        do {
            let comments = try await automationService.listComments(publicationIdentifier: identifier)
            let commentDicts = comments.map { commentToDict($0) }
            return .json([
                "status": "ok",
                "citeKey": decodedKey,
                "count": comments.count,
                "comments": commentDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    /// GET /api/papers/{citeKey}/assignments
    private func handleListPaperAssignments(citeKey: String) async -> HTTPResponse {
        guard !citeKey.isEmpty else {
            return .badRequest("Missing cite key")
        }

        let decodedKey = citeKey.removingPercentEncoding ?? citeKey
        let identifier = PaperIdentifier.citeKey(decodedKey)

        do {
            let assignments = try await automationService.listAssignmentsForPublication(publicationIdentifier: identifier)
            let assignmentDicts = assignments.map { assignmentToDict($0) }
            return .json([
                "status": "ok",
                "citeKey": decodedKey,
                "count": assignments.count,
                "assignments": assignmentDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    /// GET /api/libraries/{id}/assignments
    private func handleListLibraryAssignments(libraryID: UUID) async -> HTTPResponse {
        do {
            let assignments = try await automationService.listAssignments(libraryID: libraryID)
            let assignmentDicts = assignments.map { assignmentToDict($0) }
            return .json([
                "status": "ok",
                "libraryID": libraryID.uuidString,
                "count": assignments.count,
                "assignments": assignmentDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Annotation GET Handlers

    /// GET /api/papers/{citeKey}/annotations?page=N
    private func handleListAnnotations(citeKey: String, request: HTTPRequest) async -> HTTPResponse {
        guard !citeKey.isEmpty else {
            return .badRequest("Missing cite key")
        }

        let decodedKey = citeKey.removingPercentEncoding ?? citeKey
        let identifier = PaperIdentifier.citeKey(decodedKey)
        let pageNumber = request.queryParams["page"].flatMap { Int($0) }

        do {
            let annotations = try await automationService.listAnnotations(
                publicationIdentifier: identifier,
                pageNumber: pageNumber
            )
            let annotationDicts = annotations.map { annotationToDict($0) }
            return .json([
                "status": "ok",
                "citeKey": decodedKey,
                "count": annotations.count,
                "annotations": annotationDicts
            ])
        } catch {
            return mapError(error)
        }
    }

    /// GET /api/papers/{citeKey}/notes
    private func handleGetNotes(citeKey: String) async -> HTTPResponse {
        guard !citeKey.isEmpty else {
            return .badRequest("Missing cite key")
        }

        let decodedKey = citeKey.removingPercentEncoding ?? citeKey
        let identifier = PaperIdentifier.citeKey(decodedKey)

        do {
            let notes = try await automationService.getNotes(publicationIdentifier: identifier)
            return .json([
                "status": "ok",
                "citeKey": decodedKey,
                "notes": notes as Any
            ])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Annotation POST Handlers

    /// POST /api/papers/{citeKey}/annotations
    private func handleAddAnnotation(citeKey: String, request: HTTPRequest) async -> HTTPResponse {
        guard !citeKey.isEmpty else {
            return .badRequest("Missing cite key")
        }
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let type = json["type"] as? String else {
            return .badRequest("Missing 'type' field")
        }
        guard let pageNumber = json["pageNumber"] as? Int else {
            return .badRequest("Missing 'pageNumber' field")
        }

        let decodedKey = citeKey.removingPercentEncoding ?? citeKey
        let identifier = PaperIdentifier.citeKey(decodedKey)
        let contents = json["contents"] as? String
        let selectedText = json["selectedText"] as? String
        let color = json["color"] as? String

        do {
            let annotation = try await automationService.addAnnotation(
                publicationIdentifier: identifier,
                type: type,
                pageNumber: pageNumber,
                contents: contents,
                selectedText: selectedText,
                color: color
            )
            return .json([
                "status": "ok",
                "annotation": annotationToDict(annotation)
            ], status: 201)
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Notes PUT Handler

    /// PUT /api/papers/{citeKey}/notes
    private func handleUpdateNotes(citeKey: String, request: HTTPRequest) async -> HTTPResponse {
        guard !citeKey.isEmpty else {
            return .badRequest("Missing cite key")
        }
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }

        let decodedKey = citeKey.removingPercentEncoding ?? citeKey
        let identifier = PaperIdentifier.citeKey(decodedKey)

        // notes can be a string or null to clear
        let notes: String?
        if let notesValue = json["notes"] {
            if notesValue is NSNull {
                notes = nil
            } else if let notesString = notesValue as? String {
                notes = notesString.isEmpty ? nil : notesString
            } else {
                return .badRequest("'notes' must be a string or null")
            }
        } else {
            return .badRequest("Missing 'notes' field")
        }

        do {
            try await automationService.updateNotes(publicationIdentifier: identifier, notes: notes)
            return .json([
                "status": "ok",
                "citeKey": decodedKey,
                "notes": notes as Any
            ])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Annotation DELETE Handler

    /// DELETE /api/annotations/{id}
    private func handleDeleteAnnotation(annotationID: UUID) async -> HTTPResponse {
        do {
            try await automationService.deleteAnnotation(annotationID: annotationID)
            return .json(["status": "ok", "deleted": true])
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Helpers

    /// Parse JSON body from an HTTP request.
    private func parseJSONBody(_ request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body, !body.isEmpty,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Parse paper identifiers from a JSON dictionary.
    private func parseIdentifiers(_ json: [String: Any], key: String = "identifiers") -> [PaperIdentifier]? {
        guard let rawIdentifiers = json[key] as? [String], !rawIdentifiers.isEmpty else {
            return nil
        }
        return rawIdentifiers.map { PaperIdentifier.fromString($0) }
    }

    /// Map an error to an appropriate HTTP response.
    private func mapError(_ error: Error) -> HTTPResponse {
        if let automationError = error as? AutomationOperationError {
            switch automationError {
            case .unauthorized:
                return .forbidden("Automation API is disabled")
            case .paperNotFound(let id):
                return .notFound("Paper not found: \(id)")
            case .collectionNotFound(let id):
                return .notFound("Collection not found: \(id.uuidString)")
            case .libraryNotFound(let id):
                return .notFound("Library not found: \(id.uuidString)")
            case .commentNotFound(let id):
                return .notFound("Comment not found: \(id.uuidString)")
            case .assignmentNotFound(let id):
                return .notFound("Assignment not found: \(id.uuidString)")
            case .participantNotFound(let id):
                return .notFound("Participant not found: \(id)")
            case .sharingUnavailable:
                return .badRequest("Sharing is not available (CloudKit not configured)")
            case .notShared:
                return .badRequest("Library is not shared")
            case .notShareOwner:
                return .forbidden("Only the share owner can perform this operation")
            case .rateLimited:
                return .json(["status": "error", "error": "Rate limited"], status: 429)
            case .annotationNotFound(let id):
                return .notFound("Annotation not found: \(id.uuidString)")
            case .linkedFileNotFound(let citeKey):
                return .notFound("No PDF attached to paper: \(citeKey)")
            default:
                return .serverError(automationError.localizedDescription ?? "Unknown error")
            }
        }
        return .serverError(error.localizedDescription)
    }

    /// Convert a CommentResult to a dictionary for JSON serialization.
    private func commentToDict(_ comment: CommentResult) -> [String: Any] {
        let iso8601 = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": comment.id.uuidString,
            "text": comment.text,
            "dateCreated": iso8601.string(from: comment.dateCreated),
            "dateModified": iso8601.string(from: comment.dateModified),
            "replies": comment.replies.map { commentToDict($0) }
        ]
        if let name = comment.authorDisplayName {
            dict["authorDisplayName"] = name
        }
        if let identifier = comment.authorIdentifier {
            dict["authorIdentifier"] = identifier
        }
        if let parentID = comment.parentCommentID {
            dict["parentCommentID"] = parentID.uuidString
        }
        return dict
    }

    /// Convert an AssignmentResult to a dictionary for JSON serialization.
    private func assignmentToDict(_ assignment: AssignmentResult) -> [String: Any] {
        let iso8601 = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": assignment.id.uuidString,
            "publicationID": assignment.publicationID.uuidString,
            "dateCreated": iso8601.string(from: assignment.dateCreated)
        ]
        if let title = assignment.publicationTitle {
            dict["publicationTitle"] = title
        }
        if let citeKey = assignment.publicationCiteKey {
            dict["publicationCiteKey"] = citeKey
        }
        if let name = assignment.assigneeName {
            dict["assigneeName"] = name
        }
        if let name = assignment.assignedByName {
            dict["assignedByName"] = name
        }
        if let note = assignment.note {
            dict["note"] = note
        }
        if let dueDate = assignment.dueDate {
            dict["dueDate"] = iso8601.string(from: dueDate)
        }
        if let libraryID = assignment.libraryID {
            dict["libraryID"] = libraryID.uuidString
        }
        return dict
    }

    /// Convert an AnnotationResult to a dictionary for JSON serialization.
    private func annotationToDict(_ annotation: AnnotationResult) -> [String: Any] {
        let iso8601 = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": annotation.id.uuidString,
            "type": annotation.type,
            "pageNumber": annotation.pageNumber,
            "color": annotation.color,
            "dateCreated": iso8601.string(from: annotation.dateCreated),
            "dateModified": iso8601.string(from: annotation.dateModified)
        ]
        if let contents = annotation.contents {
            dict["contents"] = contents
        }
        if let selectedText = annotation.selectedText {
            dict["selectedText"] = selectedText
        }
        if let author = annotation.author {
            dict["author"] = author
        }
        return dict
    }

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
            "dateModified": ISO8601DateFormatter().string(from: paper.dateModified),
            "tags": paper.tags,
            "collectionIDs": paper.collectionIDs.map { $0.uuidString },
            "libraryIDs": paper.libraryIDs.map { $0.uuidString }
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
        if let flag = paper.flag {
            dict["flag"] = [
                "color": flag.color,
                "style": flag.style,
                "length": flag.length
            ]
        }
        if let notes = paper.notes {
            dict["notes"] = notes
        }
        if paper.annotationCount > 0 {
            dict["annotationCount"] = paper.annotationCount
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
