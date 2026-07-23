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
import CryptoKit
import ImpressAutomation
import ImpressKit
import ImpressLogging
import ImprintCore
import OSLog

nonisolated(unsafe) private let routerLogger = Logger(subsystem: "com.imbib.app", category: "httpRouter")

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
/// - `GET /api/artifacts` - List/search artifacts (params: type, query, limit, offset)
/// - `GET /api/artifacts/{id}` - Get single artifact
///
/// API Endpoints (POST):
/// - `POST /api/papers/add` - Add papers by identifier
/// - `POST /api/collections` - Create a collection
/// - `POST /api/papers/download-pdfs` - Download PDFs
/// - `POST /api/papers/{citeKey}/comments` - Add comment to a paper
/// - `POST /api/papers/{citeKey}/annotations` - Add PDF annotation
/// - `POST /api/assignments` - Create an assignment
/// - `POST /api/libraries/{id}/share` - Share a library
/// - `POST /api/artifacts` - Create artifact (JSON body)
/// - `POST /api/artifacts/{id}/link` - Link artifact to publication
///
/// API Endpoints (PUT):
/// - `PUT /api/papers/read` - Mark papers read/unread
/// - `PUT /api/papers/star` - Toggle star
/// - `PUT /api/papers/tags` - Add/remove tags
/// - `PUT /api/papers/flag` - Set/clear flags
/// - `PUT /api/papers/{citeKey}/notes` - Update publication notes
/// - `PUT /api/collections/{id}/papers` - Add/remove papers from collection
/// - `PUT /api/libraries/{id}/participants/{participantID}` - Set participant permission
/// - `PUT /api/artifacts/{id}/tags` - Add tag to artifact
///
/// API Endpoints (DELETE):
/// - `DELETE /api/papers` - Delete papers
/// - `DELETE /api/collections/{id}` - Delete a collection
/// - `DELETE /api/libraries/{id}` - Delete a single library (papers unlinked, undoable)
/// - `DELETE /api/libraries` - Batch delete libraries (body: `{"identifiers":[UUID,…],"deleteFiles":false}`)
/// - `DELETE /api/comments/{id}` - Delete a comment
/// - `DELETE /api/annotations/{id}` - Delete a PDF annotation
/// - `DELETE /api/assignments/{id}` - Delete an assignment
/// - `DELETE /api/libraries/{id}/share` - Unshare a library
/// - `DELETE /api/artifacts/{id}` - Delete artifact
/// - `DELETE /api/artifacts/{id}/tags/{tag}` - Remove tag from artifact
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

        // PerfMetrics: every request lands in the "http" bucket (budget
        // breaches self-flag in the Console); surfaced at GET /api/performance.
        switch request.method {
        case "GET":
            return await PerfMetrics.shared.measureAsync(PerfBucket.http, detail: path) {
                await routeGET(path: path, originalPath: originalPath, request: request)
            }
        case "POST":
            return await PerfMetrics.shared.measureAsync(PerfBucket.http, detail: path) {
                await routePOST(path: path, request: request)
            }
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
            return await PerfMetrics.shared.measureAsync(PerfBucket.search, detail: "http") {
                await handleSearch(request)
            }
        }

        // GET /api/manuscripts — list manuscripts (id, title, format, status).
        if path == "/api/manuscripts" {
            let rows = await MainActor.run { RustStoreAdapter.shared.queryManuscripts() }
            let payload: [[String: Any]] = rows.map { row in
                [
                    "id": row.id,
                    "title": row.title,
                    "format": row.format,
                    "status": row.status,
                ]
            }
            return .json(["status": "ok", "manuscripts": payload, "count": payload.count])
        }

        // Saved plot specs: list / fetch one.
        if path == "/api/plot/specs" {
            let (body, status) = await PlotAutomationHandler.listSpecs()
            return .json(body.merging(["status": "ok"]) { a, _ in a }, status: status)
        }
        if path.hasPrefix("/api/plot/specs/") {
            let idString = String(originalPath.dropFirst("/api/plot/specs/".count))
            guard let id = UUID(uuidString: idString) else {
                return .badRequest("Invalid spec UUID")
            }
            let (body, status) = await PlotAutomationHandler.getSpec(id: id)
            return .json(body.merging(["status": status == 200 ? "ok" : "error"]) { a, _ in a }, status: status)
        }

        if path == "/api/search/external" {
            return await handleSearchExternal(request)
        }

        // GET /api/papers/{citeKey}/comments
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/comments") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/comments".count))
            return await handleListComments(citeKey: citeKey)
        }

        // GET /api/items/{id}/comments — comments for any item
        if path.hasPrefix("/api/items/") && path.hasSuffix("/comments") {
            let segment = String(originalPath.dropFirst("/api/items/".count).dropLast("/comments".count))
            guard let itemID = UUID(uuidString: segment) else {
                return .badRequest("Invalid item ID")
            }
            return await handleListItemComments(itemID: itemID)
        }

        // GET /api/artifacts/{id}/comments — comments for an artifact
        if path.hasPrefix("/api/artifacts/") && path.hasSuffix("/comments") {
            let segment = String(originalPath.dropFirst("/api/artifacts/".count).dropLast("/comments".count))
            guard let artifactID = UUID(uuidString: segment) else {
                return .badRequest("Invalid artifact ID")
            }
            return await handleListItemComments(itemID: artifactID)
        }

        // GET /api/sync/status — sync status
        if path == "/api/sync/status" {
            return await handleSyncStatus()
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

        // ===== Phase D additions: specific /api/papers/* routes (must come
        // BEFORE the /api/papers/{citeKey} catch-all below) =====

        // GET /api/papers/recent
        if path == "/api/papers/recent" {
            return await handleQueryRecent(request)
        }

        // GET /api/papers/starred
        if path == "/api/papers/starred" {
            return await handleQueryStarred(request)
        }

        // GET /api/papers/count/unread|starred|flagged|by-tag
        if path == "/api/papers/count/unread" {
            return await handleCountUnread(request)
        }
        if path == "/api/papers/count/starred" {
            return await handleCountStarred(request)
        }
        if path == "/api/papers/count/flagged" {
            return await handleCountFlagged(request)
        }
        if path == "/api/papers/count/by-tag" {
            return await handleCountByTag(request)
        }

        // GET /api/papers/{citeKey}/files
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/files") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/files".count))
            return await handleListLinkedFilesForPaper(citeKey: citeKey)
        }
        // GET /api/papers/{citeKey}/files/count
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/files/count") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/files/count".count))
            return await handleCountPdfsForPaper(citeKey: citeKey)
        }
        // GET /api/papers/{citeKey}/dismissed — check if dismissed
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/dismissed") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count).dropLast("/dismissed".count))
            return await handleIsPaperDismissedByCiteKey(citeKey: citeKey)
        }

        if path.hasPrefix("/api/papers/") {
            let citeKey = String(originalPath.dropFirst("/api/papers/".count))
            return await handleGetPaper(citeKey: citeKey)
        }

        // ===== Phase D additions (continued, after /api/papers/* block) =====

        // GET /api/dismissed-papers
        if path == "/api/dismissed-papers" {
            return await handleListDismissedPapers(request)
        }
        // GET /api/dismissed-papers/check
        if path == "/api/dismissed-papers/check" {
            return await handleIsPaperDismissed(request)
        }

        // GET /api/muted-items
        if path == "/api/muted-items" {
            return await handleListMutedItems(request)
        }

        // GET /api/libraries/default
        if path == "/api/libraries/default" {
            return await handleGetDefaultLibrary()
        }
        // GET /api/libraries/inbox
        if path == "/api/libraries/inbox" {
            return await handleGetInboxLibrary()
        }
        // GET /api/libraries/{id}/export-bibtex
        if path.hasPrefix("/api/libraries/") && path.hasSuffix("/export-bibtex") {
            let segment = String(originalPath.dropFirst("/api/libraries/".count).dropLast("/export-bibtex".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleExportAllBibTeXForLibrary(libraryID: libraryID)
        }

        // GET /api/smart-searches
        if path == "/api/smart-searches" {
            return await handleListSmartSearches(request)
        }
        // GET /api/smart-searches/{id}
        if path.hasPrefix("/api/smart-searches/") {
            let segment = String(originalPath.dropFirst("/api/smart-searches/".count))
            guard let id = UUID(uuidString: segment) else {
                return .badRequest("Invalid smart-search ID")
            }
            return await handleGetSmartSearch(id: id)
        }

        // GET /api/files/{linkedFileId}/annotations
        if path.hasPrefix("/api/files/") && path.hasSuffix("/annotations") {
            let segment = String(originalPath.dropFirst("/api/files/".count).dropLast("/annotations".count))
            guard let fileID = UUID(uuidString: segment) else {
                return .badRequest("Invalid linked-file ID")
            }
            return await handleListAnnotationsForFile(linkedFileID: fileID, request: request)
        }
        // GET /api/files/{linkedFileId}/annotations/count
        if path.hasPrefix("/api/files/") && path.hasSuffix("/annotations/count") {
            let segment = String(originalPath.dropFirst("/api/files/".count).dropLast("/annotations/count".count))
            guard let fileID = UUID(uuidString: segment) else {
                return .badRequest("Invalid linked-file ID")
            }
            return await handleCountAnnotationsForFile(linkedFileID: fileID)
        }

        // GET /api/items/{uuid} — generic item lookup for HTTP-client ID translation
        if path.hasPrefix("/api/items/") && !path.hasSuffix("/comments") {
            let segment = String(originalPath.dropFirst("/api/items/".count))
            guard let itemID = UUID(uuidString: segment) else {
                return .badRequest("Invalid item ID")
            }
            return await handleGetItemByUUID(itemID: itemID)
        }

        // GET /api/scix-libraries
        if path == "/api/scix-libraries" {
            return await handleListScixLibraries()
        }
        // GET /api/scix-libraries/{id}
        if path.hasPrefix("/api/scix-libraries/") && !path.contains("/papers") {
            let segment = String(originalPath.dropFirst("/api/scix-libraries/".count))
            guard let id = UUID(uuidString: segment) else {
                return .badRequest("Invalid scix-library ID")
            }
            return await handleGetScixLibrary(id: id)
        }
        // GET /api/scix-libraries/{id}/papers
        if path.hasPrefix("/api/scix-libraries/") && path.hasSuffix("/papers") {
            let segment = String(originalPath.dropFirst("/api/scix-libraries/".count).dropLast("/papers".count))
            guard let id = UUID(uuidString: segment) else {
                return .badRequest("Invalid scix-library ID")
            }
            return await handleQueryScixLibraryPapers(scixLibraryID: id, request: request)
        }
        // GET /api/scix-libraries/{id}/papers/count
        if path.hasPrefix("/api/scix-libraries/") && path.hasSuffix("/papers/count") {
            let segment = String(originalPath.dropFirst("/api/scix-libraries/".count).dropLast("/papers/count".count))
            guard let id = UUID(uuidString: segment) else {
                return .badRequest("Invalid scix-library ID")
            }
            return await handleCountScixLibraryPapers(scixLibraryID: id)
        }

        // GET /api/undo/recent
        if path == "/api/undo/recent" {
            return await handleRecentUndoGroups(request)
        }

        // GET /api/artifacts/{id}/relations — must come before /api/artifacts/{id} below
        if path.hasPrefix("/api/artifacts/") && path.hasSuffix("/relations") {
            let segment = String(originalPath.dropFirst("/api/artifacts/".count).dropLast("/relations".count))
            guard let artifactID = UUID(uuidString: segment) else {
                return .badRequest("Invalid artifact ID")
            }
            return await handleGetArtifactRelations(id: artifactID)
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

        if path == "/api/store-timings" {
            return handleStoreTimings(request)
        }

        if path == "/api/store-timings/reset" {
            return handleResetStoreTimings()
        }

        if path == "/api/performance" {
            return handlePerformance()
        }

        if path == "/api/layout" {
            return await handleGetLayout()
        }

        if path == "/api/appearance" {
            return await handleGetAppearance()
        }

        if path == "/api/commands" {
            return handleCommands()
        }

        // GET /api/artifacts/{id}
        if path.hasPrefix("/api/artifacts/") {
            let segment = String(originalPath.dropFirst("/api/artifacts/".count))
            guard let artifactID = UUID(uuidString: segment) else {
                return .badRequest("Invalid artifact ID")
            }
            return await handleGetArtifact(id: artifactID)
        }

        // GET /api/artifacts (list/search)
        if path == "/api/artifacts" {
            return await handleListArtifacts(request)
        }

        // Root path - return API info
        if path == "/" || path == "/api" {
            return handleAPIInfo()
        }

        return .notFound("Unknown endpoint: \(request.path)")
    }

    // MARK: - POST Routes

    /// Parse a request's JSON object body (nil on absent/invalid).
    static func jsonBody(_ request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body, let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func routePOST(path: String, request: HTTPRequest) async -> HTTPResponse {
        if path == "/api/papers/add" {
            return await handleAddPapers(request)
        }

        // Native plotting (agent-drivable): render a spec to SVG.
        if path == "/api/plot/render" {
            guard let json = Self.jsonBody(request) else {
                return .badRequest("Invalid JSON body")
            }
            // {specId} renders a saved spec from the store.
            if let idString = json["specId"] as? String {
                guard let id = UUID(uuidString: idString) else {
                    return .badRequest("Invalid specId")
                }
                let (body, status) = await PlotAutomationHandler.renderSaved(id: id)
                return .json(body.merging(["status": status == 200 ? "ok" : "error"]) { a, _ in a }, status: status)
            }
            let (body, status) = PlotAutomationHandler.renderPlot(json: json)
            return .json(body.merging(["status": status == 200 ? "ok" : "error"]) { a, _ in a }, status: status)
        }

        // Saved plot specs: create.
        if path == "/api/plot/specs" {
            guard let json = Self.jsonBody(request) else {
                return .badRequest("Invalid JSON body")
            }
            let (body, status) = await PlotAutomationHandler.saveSpec(json: json)
            return .json(body.merging(["status": status == 200 ? "ok" : "error"]) { a, _ in a }, status: status)
        }

        // Native plotting: save a spec's raster as a manuscript figure.
        // POST /api/manuscripts/{uuid}/plot-figure
        if path.hasPrefix("/api/manuscripts/") && path.hasSuffix("/plot-figure") {
            let idString = String(
                request.path.dropFirst("/api/manuscripts/".count).dropLast("/plot-figure".count))
            guard let manuscriptID = UUID(uuidString: idString) else {
                return .badRequest("Invalid manuscript UUID: \(idString)")
            }
            guard let json = Self.jsonBody(request) else {
                return .badRequest("Invalid JSON body")
            }
            let (body, status) = PlotAutomationHandler.saveFigure(json: json, manuscriptID: manuscriptID)
            return .json(body.merging(["status": status == 200 ? "ok" : "error"]) { a, _ in a }, status: status)
        }

        // POST /api/manuscripts — create a manuscript.
        // Body: {title, body?, format?, authors?}
        if path == "/api/manuscripts" {
            guard let json = Self.jsonBody(request) else {
                return .badRequest("Invalid JSON body")
            }
            guard let title = json["title"] as? String, !title.isEmpty else {
                return .badRequest("Missing 'title'")
            }
            let bodyText = json["body"] as? String ?? ""
            let format = json["format"] as? String ?? "typst"
            let authors = json["authors"] as? [String] ?? []
            guard let row = await MainActor.run(body: {
                RustStoreAdapter.shared.createManuscript(
                    title: title, format: format, body: bodyText, authors: authors)
            }) else {
                return .json(["status": "error", "reason": "createManuscript failed"], status: 500)
            }
            return .json(["status": "ok", "id": row.id, "title": row.title], status: 201)
        }

        // POST /api/manuscripts/{uuid}/compile — stateless Typst compile with
        // the store-backed virtual bibliography (@citeKey → library BibTeX).
        // The agent-drivable twin of the editor's Preview: verifies the whole
        // citation pipeline headlessly. Returns byte counts + key resolution,
        // not the PDF itself (pass "include_pdf": true for base64 data).
        if path.hasPrefix("/api/manuscripts/") && path.hasSuffix("/compile") {
            let idString = String(
                request.path.dropFirst("/api/manuscripts/".count).dropLast("/compile".count))
            guard let manuscriptID = UUID(uuidString: idString) else {
                return .badRequest("Invalid manuscript UUID: \(idString)")
            }
            let includePDF = (Self.jsonBody(request)?["include_pdf"] as? Bool) ?? false
            return await Self.compileManuscript(id: manuscriptID, includePDF: includePDF)
        }

        if path == "/api/performance/reset" {
            PerfMetrics.shared.reset()
            return .json(["status": "ok"])
        }

        if path == "/api/layout" {
            return await handleSetLayout(request)
        }

        if path == "/api/layout/apply" {
            return await handleApplyLayout(request)
        }

        if path == "/api/layout/save" {
            return await handleSaveLayout(request)
        }

        if path == "/api/appearance" {
            return await handleSetAppearance(request)
        }

        if path == "/api/papers/resolve" {
            return await handleResolvePaper(request)
        }

        // ===== Phase D: new POST routes =====

        // POST /api/papers/import-batch — accepts our PaperImport array shape
        if path == "/api/papers/import-batch" {
            return await handleImportPapersBatch(request)
        }
        // POST /api/papers/import-bibtex — accepts raw BibTeX text + library_id
        if path == "/api/papers/import-bibtex" {
            return await handleImportBibTeX(request)
        }
        // POST /api/papers/move
        if path == "/api/papers/move" {
            return await handleMovePublications(request)
        }
        // POST /api/papers/duplicate
        if path == "/api/papers/duplicate" {
            return await handleDuplicatePublications(request)
        }
        // POST /api/papers/find-by-identifiers
        if path == "/api/papers/find-by-identifiers" {
            return await handleFindByIdentifiers(request)
        }
        // POST /api/libraries/{id}/set-default
        if path.hasPrefix("/api/libraries/") && path.hasSuffix("/set-default") {
            let segment = String(path.dropFirst("/api/libraries/".count).dropLast("/set-default".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleSetLibraryDefault(libraryID: libraryID)
        }
        // POST /api/libraries/{id}/deduplicate
        if path.hasPrefix("/api/libraries/") && path.hasSuffix("/deduplicate") {
            let segment = String(path.dropFirst("/api/libraries/".count).dropLast("/deduplicate".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleDeduplicateLibrary(libraryID: libraryID)
        }
        // POST /api/collections/{id}/purge-dismissed
        if path.hasPrefix("/api/collections/") && path.hasSuffix("/purge-dismissed") {
            let segment = String(path.dropFirst("/api/collections/".count).dropLast("/purge-dismissed".count))
            guard let collectionID = UUID(uuidString: segment) else {
                return .badRequest("Invalid collection ID")
            }
            return await handlePurgeDismissedFromCollection(collectionID: collectionID)
        }
        // POST /api/dismissed-papers — body has identifiers
        if path == "/api/dismissed-papers" {
            return await handleDismissPaper(request)
        }
        // POST /api/muted-items
        if path == "/api/muted-items" {
            return await handleCreateMutedItem(request)
        }
        // POST /api/tags
        if path == "/api/tags" {
            return await handleCreateTag(request)
        }
        // POST /api/smart-searches
        if path == "/api/smart-searches" {
            return await handleCreateSmartSearch(request)
        }
        // POST /api/papers/{citeKey}/files
        if path.hasPrefix("/api/papers/") && path.hasSuffix("/files") {
            let citeKey = String(path.dropFirst("/api/papers/".count).dropLast("/files".count))
            return await handleAddLinkedFile(citeKey: citeKey, request: request)
        }
        // POST /api/files/{linkedFileId}/annotations
        if path.hasPrefix("/api/files/") && path.hasSuffix("/annotations") {
            let segment = String(path.dropFirst("/api/files/".count).dropLast("/annotations".count))
            guard let fileID = UUID(uuidString: segment) else {
                return .badRequest("Invalid linked-file ID")
            }
            return await handleCreateAnnotationForFile(linkedFileID: fileID, request: request)
        }
        // POST /api/scix-libraries
        if path == "/api/scix-libraries" {
            return await handleCreateScixLibrary(request)
        }
        // POST /api/scix-libraries/{id}/papers — add publications
        if path.hasPrefix("/api/scix-libraries/") && path.hasSuffix("/papers") {
            let segment = String(path.dropFirst("/api/scix-libraries/".count).dropLast("/papers".count))
            guard let id = UUID(uuidString: segment) else {
                return .badRequest("Invalid scix-library ID")
            }
            return await handleAddToScixLibrary(scixLibraryID: id, request: request)
        }
        // POST /api/undo/operation/{id}
        if path.hasPrefix("/api/undo/operation/") {
            let opID = String(path.dropFirst("/api/undo/operation/".count))
            return await handleUndoOperation(operationID: opID)
        }
        // POST /api/undo/batch/{id}
        if path.hasPrefix("/api/undo/batch/") {
            let batchID = String(path.dropFirst("/api/undo/batch/".count))
            return await handleUndoBatch(batchID: batchID)
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

        // POST /api/items/{id}/comments — add comment to any item
        if path.hasPrefix("/api/items/") && path.hasSuffix("/comments") {
            let segment = String(request.path.dropFirst("/api/items/".count).dropLast("/comments".count))
            guard let itemID = UUID(uuidString: segment) else {
                return .badRequest("Invalid item ID")
            }
            return await handleAddItemComment(itemID: itemID, request: request)
        }

        // POST /api/artifacts/{id}/comments — add comment to artifact
        if path.hasPrefix("/api/artifacts/") && path.hasSuffix("/comments") {
            let segment = String(request.path.dropFirst("/api/artifacts/".count).dropLast("/comments".count))
            guard let artifactID = UUID(uuidString: segment) else {
                return .badRequest("Invalid artifact ID")
            }
            return await handleAddItemComment(itemID: artifactID, request: request)
        }

        // POST /api/sync/comments — trigger comment sync
        if path == "/api/sync/comments" {
            return await handleTriggerCommentSync()
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

        // POST /api/artifacts/{id}/link
        if path.hasPrefix("/api/artifacts/") && path.hasSuffix("/link") {
            let segment = String(request.path.dropFirst("/api/artifacts/".count).dropLast("/link".count))
            guard let artifactID = UUID(uuidString: segment) else {
                return .badRequest("Invalid artifact ID")
            }
            return await handleLinkArtifact(artifactID: artifactID, request: request)
        }

        // POST /api/artifacts
        if path == "/api/artifacts" {
            return await handleCreateArtifact(request)
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

        // PUT /api/comments/{id} — edit comment
        if path.hasPrefix("/api/comments/") && !path.contains("/tags") {
            let segment = String(originalPath.dropFirst("/api/comments/".count))
            guard let commentID = UUID(uuidString: segment) else {
                return .badRequest("Invalid comment ID")
            }
            return await handleEditComment(commentID: commentID, request: request)
        }

        // ===== Phase D: tag CRUD + artifact update =====
        // PUT /api/tags/{path}/rename
        if path.hasPrefix("/api/tags/") && path.hasSuffix("/rename") {
            let raw = String(originalPath.dropFirst("/api/tags/".count).dropLast("/rename".count))
            let tagPath = raw.removingPercentEncoding ?? raw
            return await handleRenameTag(oldPath: tagPath, request: request)
        }
        // PUT /api/tags/{path} — color update
        if path.hasPrefix("/api/tags/") && !path.hasSuffix("/rename") {
            let raw = String(originalPath.dropFirst("/api/tags/".count))
            let tagPath = raw.removingPercentEncoding ?? raw
            return await handleUpdateTag(path: tagPath, request: request)
        }
        // PUT /api/artifacts/{id} (NOT /tags) — update fields
        if path.hasPrefix("/api/artifacts/")
            && !path.hasSuffix("/tags")
            && !path.contains("/tags/")
        {
            let segment = String(originalPath.dropFirst("/api/artifacts/".count))
            guard let artifactID = UUID(uuidString: segment) else {
                return .badRequest("Invalid artifact ID")
            }
            return await handleUpdateArtifact(artifactID: artifactID, request: request)
        }

        // PUT /api/artifacts/{id}/tags
        if path.hasPrefix("/api/artifacts/") && path.hasSuffix("/tags") {
            let segment = String(originalPath.dropFirst("/api/artifacts/".count).dropLast("/tags".count))
            guard let artifactID = UUID(uuidString: segment) else {
                return .badRequest("Invalid artifact ID")
            }
            return await handleAddArtifactTag(artifactID: artifactID, request: request)
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

        // ===== Phase D additions: tag delete, scix-library remove =====
        // DELETE /api/tags/{path}
        if path.hasPrefix("/api/tags/") {
            let raw = String(originalPath.dropFirst("/api/tags/".count))
            let tagPath = raw.removingPercentEncoding ?? raw
            return await handleDeleteTag(path: tagPath)
        }
        // DELETE /api/scix-libraries/{id}/papers — remove publications
        if path.hasPrefix("/api/scix-libraries/") && path.hasSuffix("/papers") {
            let segment = String(originalPath.dropFirst("/api/scix-libraries/".count).dropLast("/papers".count))
            guard let id = UUID(uuidString: segment) else {
                return .badRequest("Invalid scix-library ID")
            }
            return await handleRemoveFromScixLibrary(scixLibraryID: id, request: request)
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

        // DELETE /api/artifacts/{id}/tags/{tag}
        if path.hasPrefix("/api/artifacts/") && path.contains("/tags/") {
            let withoutPrefix = String(originalPath.dropFirst("/api/artifacts/".count))
            let parts = withoutPrefix.components(separatedBy: "/tags/")
            guard parts.count == 2,
                  let artifactID = UUID(uuidString: parts[0]),
                  !parts[1].isEmpty else {
                return .badRequest("Invalid artifact ID or tag")
            }
            let tag = parts[1].removingPercentEncoding ?? parts[1]
            return await handleRemoveArtifactTag(artifactID: artifactID, tag: tag)
        }

        // DELETE /api/artifacts/{id}
        if path.hasPrefix("/api/artifacts/") {
            let segment = String(originalPath.dropFirst("/api/artifacts/".count))
            guard let artifactID = UUID(uuidString: segment) else {
                return .badRequest("Invalid artifact ID")
            }
            return await handleDeleteArtifact(id: artifactID)
        }

        // DELETE /api/collections/{id}
        if path.hasPrefix("/api/collections/") {
            let segment = String(originalPath.dropFirst("/api/collections/".count))
            guard let collectionID = UUID(uuidString: segment) else {
                return .badRequest("Invalid collection ID")
            }
            return await handleDeleteCollection(collectionID: collectionID)
        }

        // DELETE /api/libraries (batch — must precede single-id route)
        if path == "/api/libraries" {
            return await handleDeleteLibrariesBatch(request)
        }

        // DELETE /api/libraries/{id}
        if path.hasPrefix("/api/libraries/") {
            let segment = String(originalPath.dropFirst("/api/libraries/".count))
            guard let libraryID = UUID(uuidString: segment) else {
                return .badRequest("Invalid library ID")
            }
            return await handleDeleteLibrary(libraryID: libraryID, request: request)
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

    // MARK: - Store Timings (Phase 0 measurement endpoint)

    /// Returns a JSON snapshot of store call counters.
    /// Query parameter: `?top=N` limits the per-caller list (default 20).
    private func handleStoreTimings(_ request: HTTPRequest) -> HTTPResponse {
        let top = Int(request.queryParams["top"] ?? "20") ?? 20
        let snap = StoreTimings.shared.snapshot(topCallerCount: top)

        let callers: [[String: Any]] = snap.topCallers.map { stat in
            [
                "caller": stat.caller,
                "count": stat.count,
                "mainThreadCount": stat.mainThreadCount,
                "meanMillis": round(stat.meanMillis * 1000) / 1000,
                "maxMillis": round(stat.maxMillis * 1000) / 1000,
                "totalNanos": stat.totalNanos
            ]
        }

        let payload: [String: Any] = [
            "status": "ok",
            "capturedAt": ISO8601DateFormatter().string(from: snap.capturedAt),
            "totalCalls": snap.totalCalls,
            "mainThreadCalls": snap.mainThreadCalls,
            "backgroundCalls": snap.backgroundCalls,
            "mainThreadShare": round(snap.mainThreadShare * 10000) / 10000,
            "totalMainThreadMillis": round(snap.totalMainThreadMillis * 1000) / 1000,
            "slowestMainThreadCaller": snap.slowestMainThreadCaller,
            "slowestMainThreadMillis": round(snap.slowestMainThreadMillis * 1000) / 1000,
            "topCallers": callers
        ]
        return .json(payload)
    }

    /// Resets all store timing counters. Useful to measure a specific interaction in isolation.
    private func handleResetStoreTimings() -> HTTPResponse {
        StoreTimings.shared.reset()
        return .json(["status": "ok", "reset": true])
    }

    // MARK: - Performance (PerfMetrics)

    /// GET /api/performance — PerfMetrics snapshot (same shape as imprint's).
    private func handlePerformance() -> HTTPResponse {
        let snap = PerfMetrics.shared.snapshot()
        let buckets: [[String: Any]] = snap.buckets.map { b in
            var dict: [String: Any] = [
                "name": b.name,
                "count": b.count,
                "mainThreadCount": b.mainThreadCount,
                "mainThreadShare": round(b.mainThreadShare * 10000) / 10000,
                "minMillis": round(b.minMillis * 1000) / 1000,
                "meanMillis": round(b.meanMillis * 1000) / 1000,
                "p50Millis": round(b.p50Millis * 1000) / 1000,
                "p95Millis": round(b.p95Millis * 1000) / 1000,
                "maxMillis": round(b.maxMillis * 1000) / 1000,
                "breachCount": b.breachCount,
                "totalNanos": b.totalNanos
            ]
            if let budget = b.budgetMillis {
                dict["budgetMillis"] = round(budget * 1000) / 1000
            }
            return dict
        }
        return .json([
            "status": "ok",
            "capturedAt": ISO8601DateFormatter().string(from: snap.capturedAt),
            "bucketCount": snap.buckets.count,
            "buckets": buckets
        ])
    }

    // MARK: - Layout & Appearance (declarative pane-layout system)

    private func layoutStateDict(_ state: PaneLayoutState) -> [String: Any] {
        [
            "sidebarVisible": state.sidebarVisible,
            "detailPaneVisible": state.detailPaneVisible,
            "detailTab": state.detailTab,
            "appAppearance": state.appAppearance,
            "pdfDarkMode": state.pdfDarkMode
        ]
    }

    /// GET /api/layout — live pane arrangement + saved layouts.
    private func handleGetLayout() async -> HTTPResponse {
        let (current, layouts) = await MainActor.run {
            (PaneLayoutStore.shared.current,
             PaneLayoutStore.shared.layouts)
        }
        return .json([
            "status": "ok",
            "current": layoutStateDict(current),
            "layouts": layouts.map { ["name": $0.name, "state": layoutStateDict($0.state)] }
        ])
    }

    /// POST /api/layout — set any subset of the live pane arrangement.
    /// Body: {"sidebarVisible"?, "detailPaneVisible"?, "detailTab"?,
    ///        "appAppearance"?, "pdfDarkMode"?}
    private func handleSetLayout(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Expected JSON object body")
        }
        // Extract Sendable values before hopping to the MainActor.
        let sidebar = json["sidebarVisible"] as? Bool
        let detailPane = json["detailPaneVisible"] as? Bool
        let tab = json["detailTab"] as? String
        let app = json["appAppearance"] as? String
        let pdfDark = json["pdfDarkMode"] as? Bool
        let keys = json.keys.sorted().joined(separator: ",")

        let updated = await MainActor.run {
            let store = PaneLayoutStore.shared
            var state = store.current
            if let v = sidebar { state.sidebarVisible = v }
            if let v = detailPane { state.detailPaneVisible = v }
            if let v = tab { state.detailTab = v }
            if let v = app { state.appAppearance = v }
            if let v = pdfDark { state.pdfDarkMode = v }
            store.current = state
            if app != nil || pdfDark != nil {
                store.pushAppearance()
            }
            return state
        }
        logInfo("HTTP layout update: \(keys)", category: "layout")
        return .json(["status": "ok", "current": layoutStateDict(updated)])
    }

    /// POST /api/layout/apply {"name": "Reading"} — apply a saved layout.
    private func handleApplyLayout(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request), let name = json["name"] as? String else {
            return .badRequest("Expected {\"name\": ...}")
        }
        let (applied, current) = await MainActor.run {
            (PaneLayoutStore.shared.applyLayout(named: name),
             PaneLayoutStore.shared.current)
        }
        guard applied else { return .notFound("No saved layout named '\(name)'") }
        return .json(["status": "ok", "applied": name, "current": layoutStateDict(current)])
    }

    /// POST /api/layout/save {"name": "My Setup"} — save the live arrangement.
    private func handleSaveLayout(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request), let name = json["name"] as? String,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .badRequest("Expected {\"name\": ...}")
        }
        let names = await MainActor.run {
            PaneLayoutStore.shared.saveCurrent(named: name)
            return PaneLayoutStore.shared.layouts.map(\.name)
        }
        return .json(["status": "ok", "saved": name, "layouts": names])
    }

    /// GET /api/appearance — per-surface appearance (authoritative stores).
    private func handleGetAppearance() async -> HTTPResponse {
        let app = await ThemeSettingsStore.shared.settings.appearanceMode.rawValue
        let pdfDark = await PDFSettingsStore.shared.settings.darkModeEnabled
        return .json(["status": "ok", "appAppearance": app, "pdfDarkMode": pdfDark])
    }

    /// POST /api/appearance {"appAppearance"?: "system|light|dark", "pdfDarkMode"?: bool}
    private func handleSetAppearance(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Expected JSON object body")
        }
        if let raw = json["appAppearance"] as? String {
            guard let mode = AppearanceMode(rawValue: raw) else {
                return .badRequest("appAppearance must be system|light|dark")
            }
            await ThemeSettingsStore.shared.updateAppearanceMode(mode)
            await MainActor.run { PaneLayoutStore.shared.current.appAppearance = raw }
        }
        if let dark = json["pdfDarkMode"] as? Bool {
            await PDFSettingsStore.shared.updateDarkMode(enabled: dark)
            await MainActor.run { PaneLayoutStore.shared.current.pdfDarkMode = dark }
        }
        return await handleGetAppearance()
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
                // Artifact endpoints
                "GET /api/artifacts": "List/search artifacts (params: type, query, limit, offset)",
                "GET /api/artifacts/{id}": "Get single artifact by ID",
                "POST /api/artifacts": "Create artifact (body: type, title, sourceURL?, notes?, tags?)",
                "DELETE /api/artifacts/{id}": "Delete an artifact",
                "PUT /api/artifacts/{id}/tags": "Add tag to artifact (body: tag)",
                "DELETE /api/artifacts/{id}/tags/{tag}": "Remove tag from artifact",
                "POST /api/artifacts/{id}/link": "Link artifact to publication (body: citeKey)",
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

    /// POST /api/papers/resolve
    /// Atomic citation resolution for agents. Two request shapes:
    ///
    /// **Free-text** (original):
    /// `{"query": "...", "bibtex"?: "...", "library"?: "<uuid>", "download_pdfs"?: false}`
    /// Cascade: extract identifier → local lookup → import → local text
    /// search → external all-sources fan-out.
    ///
    /// **Structured** (new — for callers with parsed bibliographic fields):
    /// `{"citation": {"authors": [...], "title": "...", "year": Y,
    /// "journal": "...", "volume": "...", "pages": "...", "doi"?: "...",
    /// "arxiv"?: "...", "bibcode"?: "...", "rawBibtex"?: "...",
    /// "freeText"?: "...", "preferredDatabase"?: "astronomy"|"physics"|"all"},
    /// "library"?: "<uuid>", "download_pdfs"?: false}`
    /// Cascade: identifier → local → import → structured ADS search via
    /// `SearchFormQueryBuilder` + relevance scoring → auto-accept if
    /// confidence ≥ 0.85 → ranked candidates → all-sources fallback.
    ///
    /// Response shape (both paths): `{"status": "ok", "via": "<path>",
    /// "paper": {...}?, "candidates": [...]?, "reason": "..."?}`. The
    /// structured path's candidates include a `confidence` field (0.0–1.0).
    private func handleResolvePaper(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        let query = (json["query"] as? String) ?? ""
        let bibtex = (json["bibtex"] as? String) ?? ""
        let libraryID = (json["library"] as? String).flatMap { UUID(uuidString: $0) }
        let downloadPDFs = json["download_pdfs"] as? Bool ?? false

        // Structured-citation path — a caller (e.g. imprint with a parsed
        // LaTeX `\bibitem`) may pass `citation: {...}` with all the fields
        // the classic-form query builder needs. This skips the free-text
        // cascade below and delegates to `resolveStructuredCitation`.
        if let citationDict = json["citation"] as? [String: Any] {
            return await handleStructuredResolve(
                citationDict: citationDict,
                library: libraryID,
                downloadPDFs: downloadPDFs
            )
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !bibtex.isEmpty else {
            return .badRequest("Provide at least 'query', 'bibtex', or 'citation'")
        }

        // Step 1: try to extract an identifier from the inputs.
        let identifier: PaperIdentifier? = Self.extractIdentifier(query: trimmed, bibtex: bibtex)

        do {
            // Step 2: local lookup by identifier (fast path).
            if let id = identifier {
                if let paper = try await automationService.getPaper(identifier: id) {
                    return .json([
                        "status": "ok",
                        "via": "local-identifier",
                        "paper": paperToDict(paper)
                    ])
                }
            }

            // Step 3: local text search — sometimes the query is a cite key
            // or title and the paper is already imported.
            if !trimmed.isEmpty {
                let filters = SearchFilters(limit: 5)
                let hits = try await automationService.searchLibrary(query: trimmed, filters: filters)
                if hits.count == 1 {
                    return .json([
                        "status": "ok",
                        "via": "local-search",
                        "paper": paperToDict(hits[0])
                    ])
                } else if hits.count > 1 {
                    return .json([
                        "status": "ok",
                        "via": "local-search-ambiguous",
                        "candidates": hits.map { paperToDict($0) },
                        "reason": "\(hits.count) library papers matched; caller should pick one"
                    ])
                }
            }

            // Step 4: if we have a strong identifier, import it.
            if let id = identifier {
                let result = try await automationService.addPapers(
                    identifiers: [id],
                    collection: nil,
                    library: libraryID,
                    downloadPDFs: downloadPDFs
                )
                if let added = result.added.first {
                    return .json([
                        "status": "ok",
                        "via": "imported-identifier",
                        "paper": paperToDict(added),
                        "identifier": ["kind": id.typeName, "value": id.value]
                    ])
                }
                if !result.duplicates.isEmpty {
                    return .json([
                        "status": "ok",
                        "via": "duplicate",
                        "duplicates": result.duplicates,
                        "reason": "imbib reports the paper is already present"
                    ])
                }
            }

            // Step 5: external search for human-readable queries.
            if !trimmed.isEmpty {
                let external = try await automationService.searchExternal(query: trimmed, source: nil, maxResults: 10)
                if external.isEmpty {
                    return .json([
                        "status": "ok",
                        "via": "not-found",
                        "reason": "No local or external matches for '\(trimmed)'"
                    ])
                }
                let candidates: [[String: Any]] = external.map { r in
                    var dict: [String: Any] = [
                        "title": r.title,
                        "authors": r.authors,
                        "venue": r.venue,
                        "abstract": r.abstract,
                        "sourceID": r.sourceID,
                        "identifier": r.bestIdentifier
                    ]
                    if let year = r.year { dict["year"] = year }
                    if let doi = r.doi { dict["doi"] = doi }
                    if let arxiv = r.arxivID { dict["arxivID"] = arxiv }
                    if let bib = r.bibcode { dict["bibcode"] = bib }
                    return dict
                }
                return .json([
                    "status": "ok",
                    "via": "external-candidates",
                    "candidates": candidates,
                    "reason": "\(candidates.count) external match(es); caller should pick an identifier and call /api/papers/add"
                ])
            }

            return .json([
                "status": "ok",
                "via": "not-found",
                "reason": "No identifier extracted and no query provided"
            ])
        } catch {
            return mapError(error)
        }
    }

    /// Serve the structured-citation branch of `/api/papers/resolve`.
    ///
    /// Input JSON mirrors `CitationInput` from AutomationTypes. Output is
    /// the same shape as the rest of `handleResolvePaper`: `via`, `paper`,
    /// `candidates`, `reason`.
    private func handleStructuredResolve(
        citationDict: [String: Any],
        library: UUID?,
        downloadPDFs: Bool
    ) async -> HTTPResponse {
        // Decode JSON dict → CitationInput manually so we tolerate missing /
        // mistyped fields and return structured errors rather than crashing.
        let authors: [String] = {
            if let arr = citationDict["authors"] as? [String] { return arr }
            if let s = citationDict["authors"] as? String {
                return s.components(separatedBy: CharacterSet(charactersIn: ",;&\n"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            return []
        }()
        let input = CitationInput(
            authors: authors,
            title: citationDict["title"] as? String,
            year: citationDict["year"] as? Int,
            journal: citationDict["journal"] as? String,
            volume: citationDict["volume"] as? String,
            pages: citationDict["pages"] as? String,
            doi: citationDict["doi"] as? String,
            arxiv: citationDict["arxiv"] as? String,
            bibcode: citationDict["bibcode"] as? String,
            rawBibtex: citationDict["rawBibtex"] as? String ?? citationDict["bibtex"] as? String,
            freeText: citationDict["freeText"] as? String,
            preferredDatabase: citationDict["preferredDatabase"] as? String
        )
        // Tolerance: if the citation is completely empty, don't 400 —
        // return a friendly `not-found` 200 so the client's picker can
        // show "No candidates" instead of an HTTP error toast. Callers
        // like imprint call this for every cited paper; a transient
        // parse miss shouldn't look like a hard failure.
        if input.authors.isEmpty
            && (input.title ?? "").isEmpty
            && !input.hasIdentifier
            && (input.rawBibtex ?? "").isEmpty
            && (input.freeText ?? "").isEmpty {
            Logger.sources.warningCapture(
                "resolveStructured: empty citation input — returning not-found 200 instead of 400",
                category: "citations"
            )
            return .json([
                "status": "ok",
                "via": "not-found",
                "reason": "Citation had no authors, title, identifier, rawBibtex, or freeText — nothing to search with"
            ])
        }

        do {
            let resolved = try await automationService.resolveStructuredCitation(
                input,
                library: library,
                downloadPDFs: downloadPDFs
            )

            var response: [String: Any] = [
                "status": "ok",
                "via": resolved.via
            ]
            if let paper = resolved.paper {
                response["paper"] = paperToDict(paper)
            }
            if let candidates = resolved.candidates {
                response["candidates"] = candidates.map { candidate in
                    Self.rankedCandidateToDict(candidate)
                }
            }
            if let reason = resolved.reason {
                response["reason"] = reason
            }
            return .json(response)
        } catch {
            return mapError(error)
        }
    }

    private static func rankedCandidateToDict(_ candidate: RankedCandidate) -> [String: Any] {
        let r = candidate.result
        var dict: [String: Any] = [
            "title": r.title,
            "authors": r.authors,
            "venue": r.venue,
            "abstract": r.abstract,
            "sourceID": r.sourceID,
            "identifier": r.bestIdentifier,
            "confidence": candidate.confidence
        ]
        if let year = r.year { dict["year"] = year }
        if let doi = r.doi { dict["doi"] = doi }
        if let arxiv = r.arxivID { dict["arxivID"] = arxiv }
        if let bib = r.bibcode { dict["bibcode"] = bib }
        return dict
    }

    /// Extract a paper identifier (DOI / arXiv / bibcode / PMID) from a
    /// free-form query string or a BibTeX fragment. Returns the strongest
    /// match found, or `nil`. Consistent with imprint's `CitationResolver`.
    private static func extractIdentifier(query: String, bibtex: String) -> PaperIdentifier? {
        // Direct parse of the query first.
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let candidate = PaperIdentifier.fromString(q)
            switch candidate {
            case .doi, .arxiv, .bibcode, .pmid:
                return candidate
            default:
                break
            }
        }
        // Fall back to scanning the BibTeX fragment.
        guard !bibtex.isEmpty else { return nil }
        if let doi = firstMatch(in: bibtex, pattern: #"(?i)\bdoi\s*=\s*[{"]?\s*(?:https?://(?:dx\.)?doi\.org/)?(10\.[^\s",}]+)"#) {
            return .doi(doi)
        }
        if let doi = firstMatch(in: bibtex, pattern: #"(?i)https?://(?:dx\.)?doi\.org/(10\.[^\s",}]+)"#) {
            return .doi(doi)
        }
        let archiveIsArxiv = bibtex.range(of: #"(?i)archivePrefix\s*=\s*[{"]?\s*arxiv"#, options: .regularExpression) != nil
        if let eprint = firstMatch(in: bibtex, pattern: #"(?i)\beprint\s*=\s*[{"]?\s*([^\s",}]+)"#) {
            let looksLikeArxiv = eprint.range(of: #"^(\d{4}\.\d{4,5}|[a-z\-]+/\d{7})$"#, options: .regularExpression) != nil
            if archiveIsArxiv || looksLikeArxiv {
                return .arxiv(eprint)
            }
        }
        if let arxiv = firstMatch(in: bibtex, pattern: #"(?i)https?://arxiv\.org/abs/([^\s",}]+)"#) {
            return .arxiv(arxiv)
        }
        if let bibcode = firstMatch(in: bibtex, pattern: #"(?i)\bbibcode\s*=\s*[{"]?\s*([0-9]{4}[A-Za-z0-9.&]{14,19})"#) {
            return .bibcode(bibcode)
        }
        if let pmid = firstMatch(in: bibtex, pattern: #"(?i)\bpmid\s*=\s*[{"]?\s*(\d+)"#) {
            return .pmid(pmid)
        }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}\""))
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

    /// DELETE /api/libraries/{id}
    /// Optional query: `?deleteFiles=true` removes the library's file container
    /// alongside the store record. Default false (safer; just unlinks).
    private func handleDeleteLibrary(libraryID: UUID, request: HTTPRequest) async -> HTTPResponse {
        let deleteFiles = (request.queryParams["deleteFiles"]?.lowercased() == "true")
        do {
            let deleted = try await automationService.deleteLibrary(id: libraryID, deleteFiles: deleteFiles)
            return .json(["status": "ok", "deleted": deleted])
        } catch {
            return mapError(error)
        }
    }

    /// DELETE /api/libraries  (batch)
    /// Body: `{"identifiers": [UUID, …], "deleteFiles": false}`. Returns the
    /// count of libraries deleted. Each delete is independently undoable; the
    /// batch fires one consolidated mutation event.
    private func handleDeleteLibrariesBatch(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let identifierStrings = json["identifiers"] as? [String] else {
            return .badRequest("Missing or invalid 'identifiers' array (expected [UUID-string, …])")
        }
        let ids = identifierStrings.compactMap { UUID(uuidString: $0) }
        guard ids.count == identifierStrings.count else {
            return .badRequest("One or more 'identifiers' entries is not a valid UUID")
        }
        let deleteFiles = (json["deleteFiles"] as? Bool) ?? false
        do {
            let count = try await automationService.deleteLibraries(ids: ids, deleteFiles: deleteFiles)
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

    // MARK: - Generalized Comment Handlers

    /// GET /api/items/{id}/comments — list comments for any item
    private func handleListItemComments(itemID: UUID) async -> HTTPResponse {
        let comments = await MainActor.run { RustStoreAdapter.shared.commentsForItem(itemID) }

        let topLevel = comments.filter { $0.parentCommentID == nil }
        let formatter = ISO8601DateFormatter()
        let commentDicts: [[String: Any]] = topLevel.map { comment in
            let replies = comments.filter { $0.parentCommentID == comment.id }
            return [
                "id": comment.id.uuidString,
                "text": comment.text,
                "authorDisplayName": comment.authorDisplayName as Any,
                "authorIdentifier": comment.authorIdentifier as Any,
                "dateCreated": formatter.string(from: comment.dateCreated),
                "dateModified": formatter.string(from: comment.dateModified),
                "parentCommentID": comment.parentCommentID?.uuidString as Any,
                "parentSchema": comment.parentSchema as Any,
                "replies": replies.map { reply in
                    [
                        "id": reply.id.uuidString,
                        "text": reply.text,
                        "authorDisplayName": reply.authorDisplayName as Any,
                        "authorIdentifier": reply.authorIdentifier as Any,
                        "dateCreated": formatter.string(from: reply.dateCreated),
                        "dateModified": formatter.string(from: reply.dateModified),
                        "parentCommentID": reply.parentCommentID?.uuidString as Any,
                    ] as [String: Any]
                }
            ]
        }

        return .json(["status": "ok", "comments": commentDicts, "total": comments.count])
    }

    /// POST /api/items/{id}/comments — add comment to any item
    private func handleAddItemComment(itemID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let text = json["text"] as? String, !text.isEmpty else {
            return .badRequest("Missing or empty 'text' field")
        }
        let parentCommentIDStr = json["parentCommentID"] as? String
        let parentCommentID = parentCommentIDStr.flatMap { UUID(uuidString: $0) }

        await MainActor.run {
            RustStoreAdapter.shared.addCommentToItem(
                text: text,
                itemID: itemID,
                authorDisplayName: CurrentDeviceAuthor.displayName,
                parentCommentID: parentCommentID
            )
        }

        // Fetch the latest comment for the response
        let comments = await MainActor.run { RustStoreAdapter.shared.commentsForItem(itemID) }
        let latest = comments.last

        return .json([
            "status": "ok",
            "comment": [
                "id": latest?.id.uuidString ?? "",
                "text": latest?.text ?? text,
                "dateCreated": latest.map { ISO8601DateFormatter().string(from: $0.dateCreated) } as Any,
                "authorDisplayName": latest?.authorDisplayName as Any,
                "authorIdentifier": latest?.authorIdentifier as Any,
            ] as [String: Any]
        ])
    }

    /// PUT /api/comments/{id} — edit comment
    private func handleEditComment(commentID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let text = json["text"] as? String, !text.isEmpty else {
            return .badRequest("Missing or empty 'text' field")
        }

        await MainActor.run {
            RustStoreAdapter.shared.editComment(commentID, newText: text)
        }

        return .json(["status": "ok", "updated": true])
    }

    // MARK: - Sync Handlers

    /// POST /api/sync/comments — trigger manual comment sync
    private func handleTriggerCommentSync() async -> HTTPResponse {
        await CommentCloudKitEngine.shared.sync()
        let status = await CommentCloudKitEngine.shared.status()
        return .json([
            "status": "ok",
            "syncStatus": [
                "lastSyncDate": status.lastSyncDate.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "lastError": status.lastError as Any,
                "pendingUploadCount": status.pendingUploadCount,
            ] as [String: Any]
        ])
    }

    /// GET /api/sync/status — sync status
    private func handleSyncStatus() async -> HTTPResponse {
        let commentStatus = await CommentCloudKitEngine.shared.status()
        let settings = CloudKitSyncSettingsStore.shared
        return .json([
            "status": "ok",
            "commentSync": [
                "enabled": settings.commentSyncEnabled,
                "isRunning": commentStatus.isRunning,
                "lastSyncDate": commentStatus.lastSyncDate.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "lastError": commentStatus.lastError as Any,
                "pendingUploadCount": commentStatus.pendingUploadCount,
            ] as [String: Any],
            "generalSync": [
                "enabled": settings.shouldAttemptSync,
                "lastSyncDate": settings.lastSyncDate.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "lastError": settings.lastError as Any,
                "lifecycleState": settings.syncLifecycleState.rawValue,
            ] as [String: Any]
        ])
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
            let participants = try await LibrarySharingService.shared.participants(for: libraryID)
            let dicts: [[String: Any]] = participants.map { p in
                [
                    "id": p.id,
                    "displayName": p.displayName as Any,
                    "emailAddress": p.emailAddress as Any,
                    "permission": p.permission.rawValue,
                    "acceptanceStatus": p.acceptanceStatus.rawValue,
                    "isOwner": p.isOwner,
                    "isCurrentUser": p.isCurrentUser,
                ]
            }
            return .json(["status": "ok", "participants": dicts])
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

    // MARK: - Artifact Handlers

    /// GET /api/artifacts?type=...&query=...&limit=...&offset=...
    @MainActor
    private func handleListArtifacts(_ request: HTTPRequest) async -> HTTPResponse {
        let typeFilter = request.queryParams["type"]
        let query = request.queryParams["query"]
        let limit = request.queryParams["limit"].flatMap { UInt32($0) }
        let offset = request.queryParams["offset"].flatMap { UInt32($0) }

        let artifactType = typeFilter.flatMap { ArtifactType(rawValue: $0) }

        let artifacts: [ResearchArtifact]
        if let query, !query.isEmpty {
            artifacts = RustStoreAdapter.shared.searchArtifacts(query: query, type: artifactType)
        } else {
            artifacts = RustStoreAdapter.shared.listArtifacts(
                type: artifactType,
                limit: limit ?? 50,
                offset: offset
            )
        }

        let artifactDicts = artifacts.map { artifactToDict($0) }

        return .json([
            "status": "ok",
            "count": artifacts.count,
            "artifacts": artifactDicts
        ])
    }

    /// GET /api/artifacts/{id}
    @MainActor
    private func handleGetArtifact(id: UUID) async -> HTTPResponse {
        guard let artifact = RustStoreAdapter.shared.getArtifact(id: id) else {
            return .notFound("Artifact not found: \(id.uuidString)")
        }

        return .json([
            "status": "ok",
            "artifact": artifactToDict(artifact)
        ])
    }

    /// POST /api/artifacts
    ///
    /// Accepts all artifact fields. If `sharedFileName` is provided, the file is
    /// moved from the SharedContainer's shared-artifacts directory into imbib's
    /// artifact storage, and the file hash is computed automatically.
    @MainActor
    private func handleCreateArtifact(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let typeStr = json["type"] as? String else {
            return .badRequest("Missing 'type' field")
        }
        guard let artifactType = ArtifactType(rawValue: typeStr) else {
            return .badRequest("Invalid artifact type: \(typeStr). Valid types: \(ArtifactType.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let title = json["title"] as? String, !title.isEmpty else {
            return .badRequest("Missing 'title' field")
        }

        let sourceURL = json["sourceURL"] as? String
        let notes = json["notes"] as? String
        let tags = json["tags"] as? [String] ?? []
        let originalAuthor = json["originalAuthor"] as? String
        let captureContext = json["captureContext"] as? String
        let eventName = json["eventName"] as? String
        let eventDate = json["eventDate"] as? String

        // File fields — either from direct JSON fields or via SharedContainer import
        var fileName = json["fileName"] as? String
        var fileSize = (json["fileSize"] as? NSNumber)?.int64Value
        let fileMimeType = json["fileMimeType"] as? String
        var fileHash: String? = nil

        // If sharedFileName is provided, import the file from SharedContainer
        if let sharedFileName = json["sharedFileName"] as? String {
            let sharedDir = ImpressKit.SharedContainer.sharedArtifactsDirectory
            let sourceFile = sharedDir.appendingPathComponent(sharedFileName)

            if FileManager.default.fileExists(atPath: sourceFile.path) {
                // Read file data for hash computation
                if let fileData = try? Data(contentsOf: sourceFile) {
                    // Compute SHA-256 hash
                    fileHash = sha256Hex(fileData)
                    fileSize = Int64(fileData.count)

                    // Use the shared filename as the artifact filename if not explicitly set
                    if fileName == nil { fileName = sharedFileName }
                }

                // Clean up the shared file after reading
                try? FileManager.default.removeItem(at: sourceFile)
            }
        }

        let artifact = RustStoreAdapter.shared.createArtifact(
            type: artifactType,
            title: title,
            sourceURL: sourceURL,
            notes: notes,
            fileName: fileName,
            fileHash: fileHash,
            fileSize: fileSize,
            fileMimeType: fileMimeType,
            captureContext: captureContext,
            originalAuthor: originalAuthor,
            eventName: eventName,
            eventDate: eventDate,
            tags: tags
        )

        guard let artifact else {
            return .serverError("Failed to create artifact")
        }

        return .json([
            "status": "ok",
            "artifact": artifactToDict(artifact)
        ], status: 201)
    }

    /// Compute SHA-256 hex digest of data.
    private nonisolated func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// DELETE /api/artifacts/{id}
    @MainActor
    private func handleDeleteArtifact(id: UUID) async -> HTTPResponse {
        guard RustStoreAdapter.shared.getArtifact(id: id) != nil else {
            return .notFound("Artifact not found: \(id.uuidString)")
        }
        RustStoreAdapter.shared.deleteArtifact(id: id)
        return .json(["status": "ok", "deleted": true])
    }

    /// PUT /api/artifacts/{id}/tags
    @MainActor
    private func handleAddArtifactTag(artifactID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let tag = json["tag"] as? String, !tag.isEmpty else {
            return .badRequest("Missing 'tag' field")
        }
        guard RustStoreAdapter.shared.getArtifact(id: artifactID) != nil else {
            return .notFound("Artifact not found: \(artifactID.uuidString)")
        }

        RustStoreAdapter.shared.addArtifactTag(ids: [artifactID], tagPath: tag)
        return .json(["status": "ok", "updated": true])
    }

    /// DELETE /api/artifacts/{id}/tags/{tag}
    @MainActor
    private func handleRemoveArtifactTag(artifactID: UUID, tag: String) async -> HTTPResponse {
        guard RustStoreAdapter.shared.getArtifact(id: artifactID) != nil else {
            return .notFound("Artifact not found: \(artifactID.uuidString)")
        }

        RustStoreAdapter.shared.removeArtifactTag(ids: [artifactID], tagPath: tag)
        return .json(["status": "ok", "updated": true])
    }

    /// POST /api/artifacts/{id}/link
    @MainActor
    private func handleLinkArtifact(artifactID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }
        guard let citeKey = json["citeKey"] as? String, !citeKey.isEmpty else {
            return .badRequest("Missing 'citeKey' field")
        }

        guard RustStoreAdapter.shared.getArtifact(id: artifactID) != nil else {
            return .notFound("Artifact not found: \(artifactID.uuidString)")
        }

        // Look up publication by cite key
        do {
            let identifier = PaperIdentifier.citeKey(citeKey)
            guard let paper = try await automationService.getPaper(identifier: identifier) else {
                return .notFound("Paper not found: \(citeKey)")
            }
            RustStoreAdapter.shared.linkArtifactToPublication(artifactID: artifactID, publicationID: paper.id)
            return .json(["status": "ok", "linked": true])
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    /// Convert a ResearchArtifact to a dictionary for JSON serialization.
    @MainActor
    private func artifactToDict(_ artifact: ResearchArtifact) -> [String: Any] {
        let iso8601 = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": artifact.id.uuidString,
            "type": artifact.schema.rawValue,
            "typeName": artifact.schema.displayName,
            "title": artifact.title,
            "isRead": artifact.isRead,
            "isStarred": artifact.isStarred,
            "created": iso8601.string(from: artifact.created),
            "tags": artifact.tags.map(\.path)
        ]

        if let sourceURL = artifact.sourceURL { dict["sourceURL"] = sourceURL }
        if let notes = artifact.notes { dict["notes"] = notes }
        if let fileName = artifact.fileName { dict["fileName"] = fileName }
        if let fileSize = artifact.fileSize { dict["fileSize"] = fileSize }
        if let fileMimeType = artifact.fileMimeType { dict["fileMimeType"] = fileMimeType }
        if let originalAuthor = artifact.originalAuthor { dict["originalAuthor"] = originalAuthor }
        if let captureContext = artifact.captureContext { dict["captureContext"] = captureContext }
        if let eventName = artifact.eventName { dict["eventName"] = eventName }
        if let flagColor = artifact.flagColor { dict["flagColor"] = flagColor }

        return dict
    }

    // MARK: - Helpers

    /// Parse JSON body from an HTTP request.
    private nonisolated func parseJSONBody(_ request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body, !body.isEmpty else {
            return nil
        }
        guard let data = body.data(using: .utf8) else {
            Logger.sources.warningCapture(
                "parseJSONBody: body not UTF-8 decodable (len=\(body.count))",
                category: "http"
            )
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger.sources.warningCapture(
                "parseJSONBody: failed to parse as top-level object. First 200 chars: \(String(body.prefix(200)))",
                category: "http"
            )
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

    // MARK: - ===== Phase D: helper dict converters =====

    @MainActor
    private func libraryModelToDict(_ lib: LibraryModel) -> [String: Any] {
        return [
            "id": lib.id.uuidString,
            "name": lib.name,
            "is_default": lib.isDefault,
            "is_inbox": lib.isInbox,
            "publication_count": lib.publicationCount,
        ]
    }

    @MainActor
    private func dismissedPaperToDict(_ d: DismissedPaper) -> [String: Any] {
        var dict: [String: Any] = [
            "id": d.id.uuidString,
            "date_dismissed": Int(d.dateDismissed.timeIntervalSince1970 * 1000),
        ]
        if let v = d.doi { dict["doi"] = v }
        if let v = d.arxivID { dict["arxiv_id"] = v }
        if let v = d.bibcode { dict["bibcode"] = v }
        if let v = d.citeKey { dict["cite_key"] = v }
        return dict
    }

    @MainActor
    private func mutedItemToDict(_ m: MutedItem) -> [String: Any] {
        return [
            "id": m.id.uuidString,
            "mute_type": m.muteType,
            "value": m.value,
            "date_added": Int(m.dateAdded.timeIntervalSince1970 * 1000),
        ]
    }

    @MainActor
    private func linkedFileToDict(_ f: LinkedFileModel) -> [String: Any] {
        var dict: [String: Any] = [
            "id": f.id.uuidString,
            "filename": f.filename,
            "file_size": f.fileSize,
            "is_pdf": f.isPDF,
            "is_locally_materialized": f.isLocallyMaterialized,
            "date_added": Int(f.dateAdded.timeIntervalSince1970 * 1000),
        ]
        if let p = f.relativePath { dict["relative_path"] = p }
        return dict
    }

    @MainActor
    private func smartSearchToDict(_ s: SmartSearch) -> [String: Any] {
        var dict: [String: Any] = [
            "id": s.id.uuidString,
            "name": s.name,
            "query": s.query,
            "source_ids": s.sourceIDs,
            "max_results": s.maxResults,
            "feeds_to_inbox": s.feedsToInbox,
            "auto_refresh_enabled": s.autoRefreshEnabled,
            "refresh_interval_seconds": s.refreshIntervalSeconds,
        ]
        if let lid = s.libraryID { dict["library_id"] = lid.uuidString }
        return dict
    }

    @MainActor
    private func scixLibraryToDict(_ s: SciXLibrary) -> [String: Any] {
        var dict: [String: Any] = [
            "id": s.id.uuidString,
            "remote_id": s.remoteID,
            "name": s.name,
            "is_public": s.isPublic,
            "permission_level": s.permissionLevel,
            "document_count": s.documentCount,
            "publication_count": s.publicationCount,
        ]
        if let d = s.description { dict["description"] = d }
        if let e = s.ownerEmail { dict["owner_email"] = e }
        return dict
    }

    /// Resolve a cite-key string to a publication UUID. Returns nil if not
    /// found. Used by handlers whose Swift methods expect UUIDs but whose
    /// HTTP routes expose cite-keys.
    @MainActor
    private func uuidForCiteKey(_ citeKey: String) -> UUID? {
        let decoded = citeKey.removingPercentEncoding ?? citeKey
        do {
            let maybeRow = try RustStoreAdapter.shared.imbibStore.findByCiteKey(
                citeKey: decoded, libraryId: nil
            )
            guard let row = maybeRow else { return nil }
            return UUID(uuidString: row.id)
        } catch {
            return nil
        }
    }

    // MARK: - ===== Phase D: dismissed/muted handlers =====

    /// POST /api/dismissed-papers — body: {doi?, arxiv_id?, bibcode?, cite_key?}
    @MainActor
    private func handleDismissPaper(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        let doi = json["doi"] as? String
        let arxiv = json["arxiv_id"] as? String ?? json["arxivId"] as? String
        let bibcode = json["bibcode"] as? String
        let citeKey = json["cite_key"] as? String ?? json["citeKey"] as? String
        guard let dismissed = RustStoreAdapter.shared.dismissPaper(doi: doi, arxivId: arxiv, bibcode: bibcode, citeKey: citeKey) else {
            return .json(["status": "ok", "dismissed": NSNull()])
        }
        return .json(["status": "ok", "dismissed": dismissedPaperToDict(dismissed)])
    }

    /// GET /api/dismissed-papers/check?doi=...&arxiv_id=...&bibcode=...&cite_key=...
    @MainActor
    private func handleIsPaperDismissed(_ request: HTTPRequest) async -> HTTPResponse {
        let doi = request.queryParams["doi"]
        let arxiv = request.queryParams["arxiv_id"] ?? request.queryParams["arxivId"]
        let bibcode = request.queryParams["bibcode"]
        let citeKey = request.queryParams["cite_key"] ?? request.queryParams["citeKey"]
        let dismissed = RustStoreAdapter.shared.isPaperDismissed(doi: doi, arxivId: arxiv, bibcode: bibcode, citeKey: citeKey)
        return .json(["status": "ok", "dismissed": dismissed])
    }

    /// GET /api/papers/{citeKey}/dismissed
    @MainActor
    private func handleIsPaperDismissedByCiteKey(citeKey: String) async -> HTTPResponse {
        let decoded = citeKey.removingPercentEncoding ?? citeKey
        let dismissed = RustStoreAdapter.shared.isPaperDismissed(citeKey: decoded)
        return .json(["status": "ok", "dismissed": dismissed])
    }

    /// GET /api/dismissed-papers?limit=N&offset=M
    @MainActor
    private func handleListDismissedPapers(_ request: HTTPRequest) async -> HTTPResponse {
        let limit = request.queryParams["limit"].flatMap { UInt32($0) }
        let offset = request.queryParams["offset"].flatMap { UInt32($0) }
        let items = RustStoreAdapter.shared.listDismissedPapers(limit: limit, offset: offset)
        return .json(["status": "ok", "papers": items.map { dismissedPaperToDict($0) }])
    }

    /// POST /api/muted-items — body: {mute_type, value}
    @MainActor
    private func handleCreateMutedItem(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let mt = (json["mute_type"] as? String) ?? (json["muteType"] as? String), !mt.isEmpty else {
            return .badRequest("Missing 'mute_type'")
        }
        guard let value = json["value"] as? String, !value.isEmpty else {
            return .badRequest("Missing 'value'")
        }
        guard let item = RustStoreAdapter.shared.createMutedItem(muteType: mt, value: value) else {
            return .serverError("Failed to create muted item")
        }
        return .json(["status": "ok", "item": mutedItemToDict(item)])
    }

    /// GET /api/muted-items
    @MainActor
    private func handleListMutedItems(_ request: HTTPRequest) async -> HTTPResponse {
        let filter = request.queryParams["mute_type"] ?? request.queryParams["muteType"]
        let items = RustStoreAdapter.shared.listMutedItems(muteType: filter)
        return .json(["status": "ok", "items": items.map { mutedItemToDict($0) }])
    }

    // MARK: - ===== Phase D: library lifecycle helpers =====

    /// GET /api/libraries/default
    @MainActor
    private func handleGetDefaultLibrary() async -> HTTPResponse {
        guard let lib = RustStoreAdapter.shared.getDefaultLibrary() else {
            return .json(["status": "ok", "library": NSNull()])
        }
        return .json(["status": "ok", "library": libraryModelToDict(lib)])
    }

    /// POST /api/libraries/{id}/set-default
    @MainActor
    private func handleSetLibraryDefault(libraryID: UUID) async -> HTTPResponse {
        RustStoreAdapter.shared.setLibraryDefault(id: libraryID)
        return .json(["status": "ok"])
    }

    /// GET /api/libraries/inbox
    @MainActor
    private func handleGetInboxLibrary() async -> HTTPResponse {
        guard let lib = RustStoreAdapter.shared.getInboxLibrary() else {
            return .json(["status": "ok", "library": NSNull()])
        }
        return .json(["status": "ok", "library": libraryModelToDict(lib)])
    }

    // MARK: - ===== Phase D: tag CRUD =====

    /// POST /api/tags — body: {path, color_light?, color_dark?}
    @MainActor
    private func handleCreateTag(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let p = json["path"] as? String, !p.isEmpty else { return .badRequest("Missing 'path'") }
        let cl = json["color_light"] as? String ?? json["colorLight"] as? String
        let cd = json["color_dark"] as? String ?? json["colorDark"] as? String
        RustStoreAdapter.shared.createTag(path: p, colorLight: cl, colorDark: cd)
        return .json(["status": "ok"])
    }

    /// DELETE /api/tags/{path}
    @MainActor
    private func handleDeleteTag(path: String) async -> HTTPResponse {
        RustStoreAdapter.shared.deleteTag(path: path)
        return .json(["status": "ok"])
    }

    /// PUT /api/tags/{path}/rename — body: {new_path}
    @MainActor
    private func handleRenameTag(oldPath: String, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let newPath = (json["new_path"] as? String) ?? (json["newPath"] as? String), !newPath.isEmpty else {
            return .badRequest("Missing 'new_path'")
        }
        RustStoreAdapter.shared.renameTag(oldPath: oldPath, newPath: newPath)
        return .json(["status": "ok"])
    }

    /// PUT /api/tags/{path} — body: {color_light?, color_dark?}
    @MainActor
    private func handleUpdateTag(path: String, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        let cl = json["color_light"] as? String ?? json["colorLight"] as? String
        let cd = json["color_dark"] as? String ?? json["colorDark"] as? String
        RustStoreAdapter.shared.updateTag(path: path, colorLight: cl, colorDark: cd)
        return .json(["status": "ok"])
    }

    // MARK: - ===== Phase D: bulk publication mutations =====

    /// POST /api/papers/move — body: {publication_ids:[uuid], to_library_id:uuid}
    @MainActor
    private func handleMovePublications(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let idsRaw = (json["publication_ids"] as? [String]) ?? (json["ids"] as? [String]) else {
            return .badRequest("Missing 'publication_ids'")
        }
        guard let toRaw = (json["to_library_id"] as? String) ?? (json["toLibraryID"] as? String),
              let toLib = UUID(uuidString: toRaw) else {
            return .badRequest("Missing or invalid 'to_library_id'")
        }
        let ids = idsRaw.compactMap { UUID(uuidString: $0) }
        RustStoreAdapter.shared.movePublications(ids: ids, toLibraryId: toLib)
        return .json(["status": "ok", "moved": ids.count])
    }

    /// POST /api/papers/duplicate — body: {ids:[uuid], to_library_id:uuid}
    @MainActor
    private func handleDuplicatePublications(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let idsRaw = json["ids"] as? [String] else {
            return .badRequest("Missing 'ids'")
        }
        guard let toRaw = (json["to_library_id"] as? String) ?? (json["toLibraryID"] as? String),
              let toLib = UUID(uuidString: toRaw) else {
            return .badRequest("Missing or invalid 'to_library_id'")
        }
        let ids = idsRaw.compactMap { UUID(uuidString: $0) }
        let newIds = RustStoreAdapter.shared.duplicatePublications(ids: ids, toLibraryId: toLib)
        return .json(["status": "ok", "ids": newIds.map { $0.uuidString }])
    }

    /// POST /api/libraries/{id}/deduplicate
    @MainActor
    private func handleDeduplicateLibrary(libraryID: UUID) async -> HTTPResponse {
        let n = RustStoreAdapter.shared.deduplicateLibrary(id: libraryID)
        return .json(["status": "ok", "count": n])
    }

    /// POST /api/collections/{id}/purge-dismissed
    @MainActor
    private func handlePurgeDismissedFromCollection(collectionID: UUID) async -> HTTPResponse {
        // Not yet on the Swift adapter; call via imbibStore which we know exposes it.
        do {
            try RustStoreAdapter.shared.imbibStore.purgeDismissedFromCollection(collectionId: collectionID.uuidString)
            return .json(["status": "ok"])
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    // MARK: - ===== Phase D: identifier batch =====

    /// POST /api/papers/find-by-identifiers — body: {dois:[], arxiv_ids:[], bibcodes:[]}
    @MainActor
    private func handleFindByIdentifiers(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        let dois = (json["dois"] as? [String]) ?? []
        let arxivs = (json["arxiv_ids"] as? [String]) ?? (json["arxivIds"] as? [String]) ?? []
        let bibcodes = (json["bibcodes"] as? [String]) ?? []
        // findByIdentifiers takes single Option each; iterate to gather.
        var seen = Set<UUID>()
        var papers: [PublicationRowData] = []
        for d in dois {
            for p in RustStoreAdapter.shared.findByIdentifiers(doi: d, arxivId: nil, bibcode: nil) {
                if seen.insert(p.id).inserted { papers.append(p) }
            }
        }
        for a in arxivs {
            for p in RustStoreAdapter.shared.findByIdentifiers(doi: nil, arxivId: a, bibcode: nil) {
                if seen.insert(p.id).inserted { papers.append(p) }
            }
        }
        for b in bibcodes {
            for p in RustStoreAdapter.shared.findByIdentifiers(doi: nil, arxivId: nil, bibcode: b) {
                if seen.insert(p.id).inserted { papers.append(p) }
            }
        }
        return .json(["status": "ok", "papers": papers.map { paperToDict($0) }])
    }

    // MARK: - ===== Phase D: undo =====

    /// GET /api/undo/recent?max_entries=N
    @MainActor
    private func handleRecentUndoGroups(_ request: HTTPRequest) async -> HTTPResponse {
        let n = request.queryParams["max_entries"].flatMap { Int($0) } ?? 25
        let groups = RustStoreAdapter.shared.recentUndoGroups(maxEntries: n)
        let groupDicts: [[String: Any]] = groups.map { g in
            var d: [String: Any] = [
                "operation_id": g.operationId,
                "operation_count": g.operationCount,
                "description": g.description,
                "timestamp": g.timestamp,
            ]
            if let b = g.batchId { d["batch_id"] = b }
            return d
        }
        return .json(["status": "ok", "groups": groupDicts])
    }

    /// POST /api/undo/operation/{operation_id}
    @MainActor
    private func handleUndoOperation(operationID: String) async -> HTTPResponse {
        guard let info = RustStoreAdapter.shared.undoOperation(operationId: operationID) else {
            return .notFound("Operation not found: \(operationID)")
        }
        return .json(["status": "ok", "operation_count": info.operationIds.count])
    }

    /// POST /api/undo/batch/{batch_id}
    @MainActor
    private func handleUndoBatch(batchID: String) async -> HTTPResponse {
        guard let info = RustStoreAdapter.shared.undoBatch(batchId: batchID) else {
            return .notFound("Batch not found: \(batchID)")
        }
        return .json(["status": "ok", "operation_count": info.operationIds.count])
    }

    // MARK: - ===== Phase D: BibTeX import =====

    /// POST /api/papers/import-bibtex — body: {bibtex, library_id}
    @MainActor
    private func handleImportBibTeX(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let text = json["bibtex"] as? String, !text.isEmpty else {
            return .badRequest("Missing 'bibtex'")
        }
        guard let libRaw = (json["library_id"] as? String) ?? (json["libraryID"] as? String),
              let libID = UUID(uuidString: libRaw) else {
            return .badRequest("Missing or invalid 'library_id'")
        }
        let ids = RustStoreAdapter.shared.importBibTeX(text, libraryId: libID)
        return .json(["status": "ok", "ids": ids.map { $0.uuidString }])
    }

    /// POST /api/papers/import-batch — body: {papers: [PaperImport], library_id}
    /// PaperImport = { bibtex, doi?, arxiv_id?, bibcode? }
    @MainActor
    private func handleImportPapersBatch(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let papersRaw = json["papers"] as? [[String: Any]] else {
            return .badRequest("Missing 'papers' array")
        }
        guard let libRaw = (json["library_id"] as? String) ?? (json["libraryID"] as? String),
              let libID = UUID(uuidString: libRaw) else {
            return .badRequest("Missing or invalid 'library_id'")
        }
        var importedIds: [String] = []
        var existingIds: [String] = []
        var failedCount = 0
        for p in papersRaw {
            guard let bib = p["bibtex"] as? String, !bib.isEmpty else { failedCount += 1; continue }
            // Dedup by identifier first.
            let doi = p["doi"] as? String
            let arxiv = p["arxiv_id"] as? String ?? p["arxivId"] as? String
            let bibcode = p["bibcode"] as? String
            let existing = RustStoreAdapter.shared.findByIdentifiers(doi: doi, arxivId: arxiv, bibcode: bibcode)
            if let hit = existing.first {
                existingIds.append(hit.id.uuidString)
                continue
            }
            let imported = RustStoreAdapter.shared.importBibTeX(bib, libraryId: libID)
            importedIds.append(contentsOf: imported.map { $0.uuidString })
        }
        return .json([
            "status": "ok",
            "imported_ids": importedIds,
            "existing_ids": existingIds,
            "dismissed_count": 0,
            "failed_count": failedCount,
        ])
    }

    /// GET /api/libraries/{id}/export-bibtex — returns text/plain
    @MainActor
    private func handleExportAllBibTeXForLibrary(libraryID: UUID) async -> HTTPResponse {
        let text = RustStoreAdapter.shared.exportAllBibTeX(libraryId: libraryID)
        return .text(text)
    }

    // MARK: - ===== Phase D: linked files / PDFs =====

    /// GET /api/papers/{citeKey}/files
    @MainActor
    private func handleListLinkedFilesForPaper(citeKey: String) async -> HTTPResponse {
        guard let pubID = uuidForCiteKey(citeKey) else {
            return .notFound("Publication not found for cite key: \(citeKey)")
        }
        let files = RustStoreAdapter.shared.listLinkedFiles(publicationId: pubID)
        return .json(["status": "ok", "files": files.map { linkedFileToDict($0) }])
    }

    /// GET /api/papers/{citeKey}/files/count
    @MainActor
    private func handleCountPdfsForPaper(citeKey: String) async -> HTTPResponse {
        guard let pubID = uuidForCiteKey(citeKey) else {
            return .notFound("Publication not found for cite key: \(citeKey)")
        }
        let n = RustStoreAdapter.shared.countPdfs(publicationId: pubID)
        return .json(["status": "ok", "count": n])
    }

    /// POST /api/papers/{citeKey}/files
    @MainActor
    private func handleAddLinkedFile(citeKey: String, request: HTTPRequest) async -> HTTPResponse {
        guard let pubID = uuidForCiteKey(citeKey) else {
            return .notFound("Publication not found for cite key: \(citeKey)")
        }
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let filename = json["filename"] as? String, !filename.isEmpty else {
            return .badRequest("Missing 'filename'")
        }
        let relativePath = json["relative_path"] as? String ?? json["relativePath"] as? String
        let fileType = json["file_type"] as? String ?? json["fileType"] as? String
        let fileSize = (json["file_size"] as? Int64) ?? Int64((json["file_size"] as? Int) ?? 0)
        let sha256 = json["sha256"] as? String
        let isPdf = (json["is_pdf"] as? Bool) ?? (json["isPdf"] as? Bool) ?? false
        guard let file = RustStoreAdapter.shared.addLinkedFile(
            publicationId: pubID,
            filename: filename,
            relativePath: relativePath,
            fileType: fileType,
            fileSize: fileSize,
            sha256: sha256,
            isPdf: isPdf
        ) else {
            return .serverError("Failed to add linked file")
        }
        return .json(["status": "ok", "file": linkedFileToDict(file)])
    }

    // MARK: - ===== Phase D: annotations (file-scoped) =====

    /// GET /api/files/{linkedFileId}/annotations?page=N
    @MainActor
    private func handleListAnnotationsForFile(linkedFileID: UUID, request: HTTPRequest) async -> HTTPResponse {
        let _ = request.queryParams["page"].flatMap { Int32($0) }
        // RustStoreAdapter doesn't expose list_annotations directly — go through imbibStore.
        do {
            let anns = try RustStoreAdapter.shared.imbibStore.listAnnotations(linkedFileId: linkedFileID.uuidString, pageNumber: nil)
            let dicts: [[String: Any]] = anns.map { a in
                var d: [String: Any] = [
                    "id": a.id,
                    "annotation_type": a.annotationType,
                    "page_number": a.pageNumber,
                    "date_created": a.dateCreated,
                    "date_modified": a.dateModified,
                    "linked_file_id": a.linkedFileId,
                ]
                if let b = a.boundsJson { d["bounds_json"] = b }
                if let c = a.color { d["color"] = c }
                if let c = a.contents { d["contents"] = c }
                if let s = a.selectedText { d["selected_text"] = s }
                if let n = a.authorName { d["author_name"] = n }
                return d
            }
            return .json(["status": "ok", "annotations": dicts])
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    /// GET /api/files/{linkedFileId}/annotations/count
    @MainActor
    private func handleCountAnnotationsForFile(linkedFileID: UUID) async -> HTTPResponse {
        let n = RustStoreAdapter.shared.countAnnotations(linkedFileId: linkedFileID)
        return .json(["status": "ok", "count": n])
    }

    /// POST /api/files/{linkedFileId}/annotations
    @MainActor
    private func handleCreateAnnotationForFile(linkedFileID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let type = json["type"] as? String ?? json["annotation_type"] as? String else {
            return .badRequest("Missing 'type'")
        }
        guard let page = (json["page"] as? Int64) ?? (json["page"] as? Int).map({ Int64($0) }) else {
            return .badRequest("Missing 'page'")
        }
        let bounds = json["bounds"] as? String ?? json["bounds_json"] as? String
        let color = json["color"] as? String
        let contents = json["contents"] as? String
        let selected = json["selected_text"] as? String ?? json["selectedText"] as? String
        do {
            let ann = try RustStoreAdapter.shared.imbibStore.createAnnotation(
                linkedFileId: linkedFileID.uuidString,
                annotationType: type,
                pageNumber: page,
                boundsJson: bounds,
                color: color,
                contents: contents,
                selectedText: selected
            )
            var d: [String: Any] = [
                "id": ann.id,
                "annotation_type": ann.annotationType,
                "page_number": ann.pageNumber,
                "date_created": ann.dateCreated,
                "date_modified": ann.dateModified,
                "linked_file_id": ann.linkedFileId,
            ]
            if let b = ann.boundsJson { d["bounds_json"] = b }
            if let c = ann.color { d["color"] = c }
            if let c = ann.contents { d["contents"] = c }
            if let s = ann.selectedText { d["selected_text"] = s }
            return .json(["status": "ok", "annotation": d])
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    // MARK: - ===== Phase D: smart searches =====

    /// GET /api/smart-searches?library_id=...
    @MainActor
    private func handleListSmartSearches(_ request: HTTPRequest) async -> HTTPResponse {
        let libID = request.queryParams["library_id"].flatMap { UUID(uuidString: $0) }
        let items = RustStoreAdapter.shared.listSmartSearches(libraryId: libID)
        return .json(["status": "ok", "searches": items.map { smartSearchToDict($0) }])
    }

    /// GET /api/smart-searches/{id}
    @MainActor
    private func handleGetSmartSearch(id: UUID) async -> HTTPResponse {
        guard let s = RustStoreAdapter.shared.getSmartSearch(id: id) else {
            return .notFound("Smart search not found: \(id.uuidString)")
        }
        return .json(["status": "ok", "search": smartSearchToDict(s)])
    }

    /// POST /api/smart-searches
    @MainActor
    private func handleCreateSmartSearch(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let name = json["name"] as? String, !name.isEmpty else { return .badRequest("Missing 'name'") }
        guard let query = json["query"] as? String else { return .badRequest("Missing 'query'") }
        guard let libRaw = (json["library_id"] as? String) ?? (json["libraryID"] as? String),
              let libID = UUID(uuidString: libRaw) else { return .badRequest("Missing or invalid 'library_id'") }
        let sourceIds = json["source_ids_json"] as? String
        let maxResults = (json["max_results"] as? Int64) ?? Int64((json["max_results"] as? Int) ?? 100)
        let feeds = (json["feeds_to_inbox"] as? Bool) ?? false
        let autoRefresh = (json["auto_refresh_enabled"] as? Bool) ?? false
        let interval = (json["refresh_interval_seconds"] as? Int64) ?? Int64((json["refresh_interval_seconds"] as? Int) ?? 3600)
        guard let s = RustStoreAdapter.shared.createSmartSearch(
            name: name,
            query: query,
            libraryId: libID,
            sourceIdsJson: sourceIds,
            maxResults: maxResults,
            feedsToInbox: feeds,
            autoRefreshEnabled: autoRefresh,
            refreshIntervalSeconds: interval
        ) else {
            return .serverError("Failed to create smart search")
        }
        return .json(["status": "ok", "search": smartSearchToDict(s)])
    }

    // MARK: - ===== Phase D: SciX libraries =====

    /// GET /api/scix-libraries
    @MainActor
    private func handleListScixLibraries() async -> HTTPResponse {
        let libs = RustStoreAdapter.shared.listScixLibraries()
        return .json(["status": "ok", "libraries": libs.map { scixLibraryToDict($0) }])
    }

    /// GET /api/scix-libraries/{id}
    @MainActor
    private func handleGetScixLibrary(id: UUID) async -> HTTPResponse {
        guard let s = RustStoreAdapter.shared.getScixLibrary(id: id) else {
            return .notFound("SciX library not found: \(id.uuidString)")
        }
        return .json(["status": "ok", "library": scixLibraryToDict(s)])
    }

    /// POST /api/scix-libraries — body matches createScixLibrary args
    @MainActor
    private func handleCreateScixLibrary(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let remoteId = json["remote_id"] as? String else { return .badRequest("Missing 'remote_id'") }
        guard let name = json["name"] as? String else { return .badRequest("Missing 'name'") }
        let desc = json["description"] as? String
        let isPublic = (json["is_public"] as? Bool) ?? false
        let perm = (json["permission_level"] as? String) ?? "read"
        let owner = json["owner_email"] as? String
        guard let lib = RustStoreAdapter.shared.createScixLibrary(
            remoteId: remoteId,
            name: name,
            description: desc,
            isPublic: isPublic,
            permissionLevel: perm,
            ownerEmail: owner
        ) else {
            return .serverError("Failed to create SciX library")
        }
        return .json(["status": "ok", "library": scixLibraryToDict(lib)])
    }

    /// POST /api/scix-libraries/{id}/papers — body: {publication_ids:[uuid]}
    @MainActor
    private func handleAddToScixLibrary(scixLibraryID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let idsRaw = (json["publication_ids"] as? [String]) ?? (json["publicationIds"] as? [String]) else {
            return .badRequest("Missing 'publication_ids'")
        }
        let ids = idsRaw.compactMap { UUID(uuidString: $0) }
        RustStoreAdapter.shared.addToScixLibrary(publicationIds: ids, scixLibraryId: scixLibraryID)
        return .json(["status": "ok", "added": ids.count])
    }

    /// DELETE /api/scix-libraries/{id}/papers — body: {publication_ids:[uuid]}
    @MainActor
    private func handleRemoveFromScixLibrary(scixLibraryID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        guard let idsRaw = (json["publication_ids"] as? [String]) ?? (json["publicationIds"] as? [String]) else {
            return .badRequest("Missing 'publication_ids'")
        }
        let ids = idsRaw.compactMap { UUID(uuidString: $0) }
        RustStoreAdapter.shared.removeFromScixLibrary(publicationIds: ids, scixLibraryId: scixLibraryID)
        return .json(["status": "ok", "removed": ids.count])
    }

    /// GET /api/scix-libraries/{id}/papers?limit=N&offset=M
    @MainActor
    private func handleQueryScixLibraryPapers(scixLibraryID: UUID, request: HTTPRequest) async -> HTTPResponse {
        let limit = request.queryParams["limit"].flatMap { UInt32($0) }
        let offset = request.queryParams["offset"].flatMap { UInt32($0) }
        let papers = RustStoreAdapter.shared.queryScixLibraryPublications(
            scixLibraryId: scixLibraryID,
            sort: "date_added",
            ascending: false,
            limit: limit,
            offset: offset
        )
        return .json(["status": "ok", "papers": papers.map { paperToDict($0) }])
    }

    /// GET /api/scix-libraries/{id}/papers/count
    @MainActor
    private func handleCountScixLibraryPapers(scixLibraryID: UUID) async -> HTTPResponse {
        let n = (try? Int(RustStoreAdapter.shared.imbibStore.countScixLibraryPublications(scixLibraryId: scixLibraryID.uuidString))) ?? 0
        return .json(["status": "ok", "count": n])
    }

    // MARK: - ===== Phase D: count endpoints =====

    /// GET /api/papers/count/unread?parent_id=...
    @MainActor
    private func handleCountUnread(_ request: HTTPRequest) async -> HTTPResponse {
        let parentID = request.queryParams["parent_id"].flatMap { UUID(uuidString: $0) }
        let n = RustStoreAdapter.shared.countUnread(parentId: parentID)
        return .json(["status": "ok", "count": n])
    }

    /// GET /api/papers/count/starred?parent_id=...
    @MainActor
    private func handleCountStarred(_ request: HTTPRequest) async -> HTTPResponse {
        let parentID = request.queryParams["parent_id"].flatMap { UUID(uuidString: $0) }
        let n = RustStoreAdapter.shared.countStarred(parentId: parentID)
        return .json(["status": "ok", "count": n])
    }

    /// GET /api/papers/count/flagged?color=...
    @MainActor
    private func handleCountFlagged(_ request: HTTPRequest) async -> HTTPResponse {
        let color = request.queryParams["color"]
        let n = (try? Int(RustStoreAdapter.shared.imbibStore.countFlagged(color: color))) ?? 0
        return .json(["status": "ok", "count": n])
    }

    /// GET /api/papers/count/by-tag?tag=...&parent_id=...
    @MainActor
    private func handleCountByTag(_ request: HTTPRequest) async -> HTTPResponse {
        guard let tag = request.queryParams["tag"] else { return .badRequest("Missing 'tag'") }
        let parent = request.queryParams["parent_id"]
        let n = (try? Int(RustStoreAdapter.shared.imbibStore.countByTag(tagPath: tag, parentId: parent))) ?? 0
        return .json(["status": "ok", "count": n])
    }

    // MARK: - ===== Phase D: paper queries (recent / starred) =====

    /// GET /api/papers/recent?limit=N&parent_id=...
    @MainActor
    private func handleQueryRecent(_ request: HTTPRequest) async -> HTTPResponse {
        let limit = request.queryParams["limit"].flatMap { UInt32($0) } ?? 50
        let parent = request.queryParams["parent_id"]
        do {
            let papers = try RustStoreAdapter.shared.imbibStore.queryRecent(limit: limit, parentId: parent)
            return .json(["status": "ok", "papers": papers.map { bibToDict($0) }])
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    /// GET /api/papers/starred?limit=N&parent_id=...
    @MainActor
    private func handleQueryStarred(_ request: HTTPRequest) async -> HTTPResponse {
        let limit = request.queryParams["limit"].flatMap { UInt32($0) } ?? 50
        let parent = request.queryParams["parent_id"]
        do {
            let papers = try RustStoreAdapter.shared.imbibStore.queryStarred(
                parentId: parent,
                sortField: "date_added",
                ascending: false,
                limit: limit,
                offset: nil
            )
            return .json(["status": "ok", "papers": papers.map { bibToDict($0) }])
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    // MARK: - ===== Phase D: artifacts (update + relations) =====

    /// PUT /api/artifacts/{id}
    @MainActor
    private func handleUpdateArtifact(artifactID: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else { return .badRequest("Invalid JSON body") }
        let title = json["title"] as? String
        let sourceUrl = json["source_url"] as? String
        let notes = json["notes"] as? String
        let subtype = json["artifact_subtype"] as? String
        let captureContext = json["capture_context"] as? String
        let originalAuthor = json["original_author"] as? String
        let eventName = json["event_name"] as? String
        let eventDate = json["event_date"] as? String
        RustStoreAdapter.shared.updateArtifact(
            id: artifactID,
            title: title,
            sourceURL: sourceUrl,
            notes: notes,
            artifactSubtype: subtype,
            captureContext: captureContext,
            originalAuthor: originalAuthor,
            eventName: eventName,
            eventDate: eventDate
        )
        return .json(["status": "ok"])
    }

    /// GET /api/artifacts/{id}/relations
    @MainActor
    private func handleGetArtifactRelations(id: UUID) async -> HTTPResponse {
        do {
            let rels = try RustStoreAdapter.shared.imbibStore.getArtifactRelations(id: id.uuidString)
            let dicts: [[String: Any]] = rels.map { r in
                var d: [String: Any] = [
                    "target_id": r.targetId,
                    "edge_type": r.edgeType,
                ]
                if let s = r.targetSchema { d["target_schema"] = s }
                if let t = r.targetTitle { d["target_title"] = t }
                return d
            }
            return .json(["status": "ok", "relations": dicts])
        } catch {
            return .serverError(error.localizedDescription)
        }
    }

    // MARK: - ===== Phase D: item-by-UUID =====

    /// GET /api/items/{uuid} — generic item lookup; if publication, return summary.
    @MainActor
    private func handleGetItemByUUID(itemID: UUID) async -> HTTPResponse {
        // Try as publication first. getPublication: throws -> BibliographyRow?
        do {
            if let row = try RustStoreAdapter.shared.imbibStore.getPublication(id: itemID.uuidString) {
                var dict = bibToDict(row)
                dict["cite_key"] = row.citeKey
                dict["citeKey"] = row.citeKey // back-compat
                return .json(["status": "ok"].merging(dict) { _, new in new })
            }
        } catch {
            // fall through to 404
        }
        return .notFound("Item not found: \(itemID.uuidString)")
    }

    // MARK: - ===== Phase D: BibliographyRow → dict helper =====

    @MainActor
    private func bibToDict(_ row: ImbibRustCore.BibliographyRow) -> [String: Any] {
        var dict: [String: Any] = [
            "id": row.id,
            "cite_key": row.citeKey,
            "title": row.title,
            "authors": row.authorString,
            "is_read": row.isRead,
            "is_starred": row.isStarred,
            "has_pdf": row.hasDownloadedPdf,
            "tags": row.tags.map { $0.path },
        ]
        if let y = row.year { dict["year"] = y }
        if let v = row.venue { dict["venue"] = v }
        if let d = row.doi { dict["doi"] = d }
        if let a = row.arxivId { dict["arxiv_id"] = a }
        if let f = row.flagColor { dict["flag_color"] = f }
        return dict
    }

    /// Convert PublicationRowData (used by the adapter) → dict. Mirrors bibToDict
    /// so the wire format is the same regardless of whether the data came from
    /// adapter or imbibStore directly.
    @MainActor
    private func paperToDict(_ p: PublicationRowData) -> [String: Any] {
        var dict: [String: Any] = [
            "id": p.id.uuidString,
            "cite_key": p.citeKey,
            "title": p.title,
            "authors": p.authorString,
            "is_read": p.isRead,
            "is_starred": p.isStarred,
            "has_pdf": p.hasDownloadedPDF,
            "tags": p.tagDisplays.map { $0.path },
        ]
        if let y = p.year { dict["year"] = y }
        if let v = p.venue { dict["venue"] = v }
        if let d = p.doi { dict["doi"] = d }
        if let a = p.arxivID { dict["arxiv_id"] = a }
        if let f = p.flag?.color { dict["flag_color"] = f }
        return dict
    }
}

// MARK: - API Response Types

/// Standard API response wrapper.
nonisolated public struct APIResponse<T: Codable>: Codable, Sendable where T: Sendable {
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
nonisolated public struct StatusResponse: Codable, Sendable {
    public let version: String
    public let libraryCount: Int
    public let collectionCount: Int
    public let serverPort: UInt16
}

/// Search response.
nonisolated public struct SearchResponse: Codable, Sendable {
    public let query: String
    public let count: Int
    public let limit: Int
    public let offset: Int
    public let papers: [PaperResult]
}

/// Export response.
nonisolated public struct ExportResponse: Codable, Sendable {
    public let format: String
    public let paperCount: Int
    public let content: String
}

// MARK: - Manuscript compile (agent verification surface)

extension HTTPAutomationRouter {

    /// Stateless Typst compile of a stored manuscript, with the same
    /// store-backed virtual bibliography the editor's Preview uses:
    /// extract `@citeKey` references (canonical Rust scanner) → export their
    /// BibTeX through the citation seam → inject as bibliography.bib →
    /// auto-append `#bibliography()` when the source lacks one.
    ///
    /// This is the headless twin of ManuscriptCompileController.compileTypst,
    /// exposed so agents can verify citation resolution and rendering without
    /// driving the GUI (see the agent-drivability directive).
    static func compileManuscript(id: UUID, includePDF: Bool) async -> HTTPResponse {
        // Snapshot everything MainActor-bound in one hop.
        struct Snapshot {
            var source: String
            var format: String
            var citedKeys: [String]
            var resolvedKeys: [String]
            var bibSource: String?
        }
        guard var snap = await MainActor.run(body: { () -> Snapshot? in
            guard let detail = RustStoreAdapter.shared.getManuscriptDetail(id: id) else {
                return nil
            }
            let keys = ManuscriptCitationKeys.extract(from: detail.bodyContent)
            let citations = ManuscriptEditorEnvironment.shared.citationSearch
            let resolved = keys.filter { citations?.findByCiteKey($0) != nil }
            let bib = keys.isEmpty ? nil : citations?.bibliography(forKeys: keys)
            return Snapshot(
                source: detail.bodyContent,
                format: detail.format,
                citedKeys: keys,
                resolvedKeys: resolved,
                bibSource: bib
            )
        }) else {
            return .json(["status": "error", "reason": "manuscript not found"], status: 404)
        }

        guard snap.format != "latex" else {
            return .json(
                ["status": "error", "reason": "LaTeX compile is not supported on this endpoint"],
                status: 422)
        }

        if snap.bibSource != nil && !snap.source.contains("#bibliography(") {
            snap.source += "\n#bibliography(\"bibliography.bib\")\n"
        }

        let renderer = TypstRenderer()
        let options = ImprintCore.RenderOptions(
            pageSize: .a4,
            isDraft: false,
            figuresRoot: ManuscriptFiguresDirectory.manuscriptRoot(for: id).path,
            bibSource: snap.bibSource
        )
        do {
            let output = try await renderer.render(snap.source, options: options)
            var payload: [String: Any] = [
                "status": output.isSuccess ? "ok" : "error",
                "pdfBytes": output.pdfData.count,
                "citedKeys": snap.citedKeys,
                "resolvedKeys": snap.resolvedKeys,
                "bibliographyBytes": snap.bibSource?.utf8.count ?? 0,
                "warnings": output.warnings,
            ]
            if !output.isSuccess {
                payload["errors"] = output.errors
            }
            if includePDF && output.isSuccess {
                payload["pdfBase64"] = output.pdfData.base64EncodedString()
            }
            return .json(payload, status: output.isSuccess ? 200 : 422)
        } catch {
            return .json(
                ["status": "error", "reason": error.localizedDescription],
                status: 500)
        }
    }
}
