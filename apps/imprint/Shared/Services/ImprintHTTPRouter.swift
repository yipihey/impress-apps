//
//  ImprintHTTPRouter.swift
//  imprint
//
//  Created by Claude on 2026-01-28.
//
//  Route parsing and response handling for HTTP automation API.
//  Implements JSON REST endpoints for AI agent and MCP integration.
//

import Foundation
import ImpressAutomation
import ImpressLogging
import ImpressOperationQueue
import ImprintCore
import ImprintRustCore
import OSLog
#if os(macOS)
import AppKit
#endif


// MARK: - HTTP Automation Router

/// Routes HTTP requests to appropriate handlers.
///
/// API Endpoints:
/// - `GET /api/status` - Server health
/// - `GET /api/logs` - Query log entries
/// - `GET /api/documents` - List open documents
/// - `GET /api/documents/{id}` - Get document content/metadata
/// - `GET /api/documents/{id}/content` - Get document source content
/// - `GET /api/documents/{id}/outline` - Get document structure (headings)
/// - `GET /api/documents/{id}/pdf` - Download compiled PDF
/// - `GET /api/documents/{id}/bibliography` - List all citations
/// - `GET /api/documents/{id}/citations` - Find citation usages in source
/// - `GET /api/documents/{id}/export/latex` - Export as LaTeX
/// - `GET /api/documents/{id}/export/text` - Export as plain text
/// - `GET /api/documents/{id}/export/typst` - Export Typst source + bib
/// - `POST /api/documents/{id}/compile` - Compile to PDF
/// - `POST /api/documents/{id}/insert-citation` - Insert citation
/// - `POST /api/documents/{id}/search` - Search for text
/// - `POST /api/documents/{id}/replace` - Search and replace
/// - `POST /api/documents/{id}/insert` - Insert text at position
/// - `POST /api/documents/{id}/delete` - Delete text range
/// - `POST /api/documents/{id}/bibliography` - Add citation to bibliography
/// - `POST /api/documents/create` - Create new document
/// - `PUT /api/documents/{id}/metadata` - Update document metadata
/// - `DELETE /api/documents/{id}/bibliography/{key}` - Remove citation
/// - `GET /api/latex/status` - TeX distribution info and available engines
/// - `GET /api/store-timings` - StoreTimings snapshot (per-caller stats)
/// - `POST /api/store-timings/reset` - Reset StoreTimings counters
/// - `GET /api/manuscripts` - List every manuscript known to the store
/// - `GET /api/manuscripts/{id}/sections` - List sections for a manuscript
/// - `GET /api/sections/{id}` - Fetch a single section (id, body, metadata)
/// - `GET /api/search?q=...` - Cross-document manuscript search
/// - `GET /api/citation-usages` - List citation-usage records
/// - `GET /api/documents/{id}/diagnostics` - Structured compilation diagnostics
/// - `GET /api/documents/{id}/synctex` - SyncTeX bidirectional lookup
/// - `POST /api/compile/typst` - Stateless: compile source bytes → PDF (journal pipeline)
/// - `POST /api/compile/bundle` - Compile a manuscript bundle (typst or LaTeX) → PDF
/// - `OPTIONS /*` - CORS preflight
public actor ImprintHTTPRouter: HTTPRouter {

    // MARK: - Initialization

    public init() {}

    // MARK: - Routing

    /// Route a request to the appropriate handler.
    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        // Handle CORS preflight
        if request.method == "OPTIONS" {
            return handleCORSPreflight()
        }

        // Route based on path - preserve case for document IDs
        let path = request.path
        let pathLower = path.lowercased()

        // GET endpoints
        if request.method == "GET" {
            if pathLower == "/api/status" {
                return await handleStatus()
            }

            if pathLower == "/api/logs" {
                return await handleGetLogs(request)
            }

            if pathLower == "/api/documents" {
                return await handleListDocuments()
            }

            if pathLower == "/api/latex/status" {
                return await handleLaTeXStatus()
            }

            if pathLower == "/api/store-timings" {
                return handleStoreTimings(request)
            }

            if pathLower == "/api/manuscripts" {
                return await handleListManuscripts()
            }

            if pathLower == "/api/citation-usages" {
                return handleListCitationUsages()
            }

            if pathLower == "/api/search" {
                return await handleCrossDocumentSearch(request)
            }

            if pathLower.hasPrefix("/api/manuscripts/") {
                let remainder = String(path.dropFirst("/api/manuscripts/".count))
                if remainder.hasSuffix("/sections") {
                    let docId = String(remainder.dropLast("/sections".count))
                    return handleManuscriptSections(id: docId)
                }
            }

            if pathLower.hasPrefix("/api/sections/") {
                let sectionID = String(path.dropFirst("/api/sections/".count))
                return handleGetSection(id: sectionID)
            }

            if pathLower.hasPrefix("/api/operations/") {
                let opID = String(path.dropFirst("/api/operations/".count))
                return handleGetOperation(id: opID)
            }

            // GET /api/documents/{id}/comments — list comments for a document
            if pathLower.hasPrefix("/api/documents/") && pathLower.hasSuffix("/comments") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let docId = String(remainder.dropLast("/comments".count))
                return await handleListComments(
                    docId: docId,
                    filter: request.queryParams["filter"],
                    authorAgentId: request.queryParams["authorAgentId"]
                )
            }

            if pathLower.hasPrefix("/api/documents/") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let remainderLower = remainder.lowercased()

                // GET /api/documents/{id}/outline/v2 — richer outline with section UUIDs
                if remainderLower.hasSuffix("/outline/v2") {
                    let docId = String(remainder.dropLast("/outline/v2".count))
                    return await handleGetOutlineV2(id: docId)
                }

                // GET /api/documents/{docId}/sections — list derived sections
                if remainderLower.hasSuffix("/sections") {
                    let docId = String(remainder.dropLast("/sections".count))
                    return await handleListSectionsForDocument(id: docId)
                }

                // GET /api/documents/{docId}/sections/{sectionKey}
                if remainderLower.contains("/sections/") {
                    let parts = remainder.components(separatedBy: "/sections/")
                    if parts.count == 2 {
                        let docId = parts[0]
                        let key = parts[1]
                        return await handleGetSectionInDocument(docId: docId, sectionKey: key)
                    }
                }

                // Export endpoints
                if remainderLower.hasSuffix("/export/latex") {
                    let docId = String(remainder.dropLast("/export/latex".count))
                    return await handleExportLatex(id: docId, request: request)
                }
                if remainderLower.hasSuffix("/export/text") {
                    let docId = String(remainder.dropLast("/export/text".count))
                    return await handleExportText(id: docId)
                }
                if remainderLower.hasSuffix("/export/typst") {
                    let docId = String(remainder.dropLast("/export/typst".count))
                    return await handleExportTypst(id: docId)
                }

                // Check for /diagnostics suffix
                if remainderLower.hasSuffix("/diagnostics") {
                    let docId = String(remainder.dropLast("/diagnostics".count))
                    return await handleGetDiagnostics(id: docId)
                }

                // Check for /synctex suffix
                if remainderLower.hasSuffix("/synctex") {
                    let docId = String(remainder.dropLast("/synctex".count))
                    return await handleSyncTeX(id: docId, request: request)
                }

                // Check for /content suffix
                if remainderLower.hasSuffix("/content") {
                    let docId = String(remainder.dropLast("/content".count))
                    return await handleGetDocumentContent(id: docId)
                }

                // Check for /outline suffix
                if remainderLower.hasSuffix("/outline") {
                    let docId = String(remainder.dropLast("/outline".count))
                    return await handleGetOutline(id: docId)
                }

                // Check for /pdf suffix
                if remainderLower.hasSuffix("/pdf") {
                    let docId = String(remainder.dropLast("/pdf".count))
                    return await handleGetPDF(id: docId)
                }

                // Check for /bibliography suffix
                if remainderLower.hasSuffix("/bibliography") {
                    let docId = String(remainder.dropLast("/bibliography".count))
                    return await handleGetBibliography(id: docId)
                }

                // Check for /citations suffix
                if remainderLower.hasSuffix("/citations") {
                    let docId = String(remainder.dropLast("/citations".count))
                    return await handleGetCitationUsages(id: docId)
                }

                // Just the document ID
                if !remainder.contains("/") {
                    return await handleGetDocument(id: remainder)
                }
            }
        }

        // POST endpoints
        if request.method == "POST" {
            // Stateless compile route — accepts source bytes, returns PDF.
            // No document lifecycle side effects. Used by the journal pipeline
            // (Archivist) to compile manuscript-revision source content into
            // PDF artifacts without polluting the editor's document registry.
            // Per docs/plan-imprint-compile.md.
            if pathLower == "/api/compile/typst" {
                return await handleStatelessCompile(request)
            }

            // Bundle compile route (Phase 8.9 / docs/plan-journal-pipeline.md).
            // Accepts a content-addressed bundle SHA + manifest hint, dispatches
            // to imprint-core (typst) or LaTeXCompilationService (LaTeX engines).
            if pathLower == "/api/compile/bundle" {
                return await handleBundleCompile(request)
            }

            if pathLower == "/api/documents/create" {
                return await handleCreateDocument(request)
            }

            if pathLower == "/api/store-timings/reset" {
                return handleResetStoreTimings()
            }

            // POST /api/documents/{docId}/sections — append a new section
            if pathLower.hasPrefix("/api/documents/") && pathLower.hasSuffix("/sections") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let docId = String(remainder.dropLast("/sections".count))
                return await handleCreateSection(docId: docId, request: request)
            }

            // POST /api/documents/{docId}/comments — create a comment
            if pathLower.hasPrefix("/api/documents/") && pathLower.hasSuffix("/comments") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let docId = String(remainder.dropLast("/comments".count))
                return await handleCreateComment(docId: docId, request: request)
            }

            // POST /api/comments/{id}/accept — apply suggestion + resolve
            if pathLower.hasPrefix("/api/comments/") && pathLower.hasSuffix("/accept") {
                let remainder = String(path.dropFirst("/api/comments/".count))
                let id = String(remainder.dropLast("/accept".count))
                return await handleAcceptComment(id: id)
            }

            // POST /api/comments/{id}/reject — resolve without applying
            if pathLower.hasPrefix("/api/comments/") && pathLower.hasSuffix("/reject") {
                let remainder = String(path.dropFirst("/api/comments/".count))
                let id = String(remainder.dropLast("/reject".count))
                return await handleRejectComment(id: id)
            }

            // POST /api/documents/{docId}/sections/{sectionKey}/citations — insert @citeKey inside a section
            if pathLower.hasPrefix("/api/documents/") && pathLower.hasSuffix("/citations") && pathLower.contains("/sections/") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let withoutCitations = String(remainder.dropLast("/citations".count))
                let parts = withoutCitations.components(separatedBy: "/sections/")
                if parts.count == 2 {
                    let docId = parts[0]
                    let key = parts[1]
                    return await handleInsertCitationInSection(docId: docId, sectionKey: key, request: request)
                }
            }

            if pathLower.hasPrefix("/api/documents/") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let remainderLower = remainder.lowercased()

                if remainderLower.hasSuffix("/compile") {
                    let docId = String(remainder.dropLast("/compile".count))
                    return await handleCompile(id: docId, request: request)
                }

                if remainderLower.hasSuffix("/insert-citation") {
                    let docId = String(remainder.dropLast("/insert-citation".count))
                    return await handleInsertCitation(id: docId, request: request)
                }

                if remainderLower.hasSuffix("/update") {
                    let docId = String(remainder.dropLast("/update".count))
                    return await handleUpdateDocument(id: docId, request: request)
                }

                if remainderLower.hasSuffix("/search") {
                    let docId = String(remainder.dropLast("/search".count))
                    return await handleSearch(id: docId, request: request)
                }

                if remainderLower.hasSuffix("/replace") {
                    let docId = String(remainder.dropLast("/replace".count))
                    return await handleReplace(id: docId, request: request)
                }

                if remainderLower.hasSuffix("/insert") {
                    let docId = String(remainder.dropLast("/insert".count))
                    return await handleInsertText(id: docId, request: request)
                }

                if remainderLower.hasSuffix("/delete") {
                    let docId = String(remainder.dropLast("/delete".count))
                    return await handleDeleteText(id: docId, request: request)
                }

                if remainderLower.hasSuffix("/bibliography") {
                    let docId = String(remainder.dropLast("/bibliography".count))
                    return await handleAddCitation(id: docId, request: request)
                }
            }
        }

        // PUT endpoints
        if request.method == "PUT" {
            if pathLower.hasPrefix("/api/documents/") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let remainderLower = remainder.lowercased()

                if remainderLower.hasSuffix("/metadata") {
                    let docId = String(remainder.dropLast("/metadata".count))
                    return await handleUpdateMetadata(id: docId, request: request)
                }
            }
        }

        // PATCH endpoints
        if request.method == "PATCH" {
            // PATCH /api/comments/{id} — edit content / resolve / unresolve
            if pathLower.hasPrefix("/api/comments/") {
                let id = String(path.dropFirst("/api/comments/".count))
                return await handlePatchComment(id: id, request: request)
            }

            // PATCH /api/documents/{docId}/sections/{sectionKey} — replace section body or metadata
            if pathLower.hasPrefix("/api/documents/") && pathLower.contains("/sections/") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let parts = remainder.components(separatedBy: "/sections/")
                if parts.count == 2 {
                    let docId = parts[0]
                    let key = parts[1]
                    return await handlePatchSection(docId: docId, sectionKey: key, request: request)
                }
            }
        }

        // DELETE endpoints
        if request.method == "DELETE" {
            // DELETE /api/comments/{id}
            if pathLower.hasPrefix("/api/comments/") {
                let id = String(path.dropFirst("/api/comments/".count))
                return await handleDeleteComment(id: id)
            }

            if pathLower.hasPrefix("/api/documents/") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let remainderLower = remainder.lowercased()

                // DELETE /api/documents/{docId}/sections/{sectionKey}
                if remainderLower.contains("/sections/") {
                    let parts = remainder.components(separatedBy: "/sections/")
                    if parts.count == 2 {
                        let docId = parts[0]
                        let key = parts[1]
                        return await handleDeleteSection(docId: docId, sectionKey: key)
                    }
                }

                // DELETE /api/documents/{id}/bibliography/{key}
                if remainderLower.contains("/bibliography/") {
                    let parts = remainder.components(separatedBy: "/bibliography/")
                    if parts.count == 2 {
                        let docId = parts[0]
                        let citeKey = parts[1]
                        return await handleRemoveCitation(id: docId, citeKey: citeKey)
                    }
                }
            }
        }

        // Root path - return API info
        if pathLower == "/" || pathLower == "/api" {
            return handleAPIInfo()
        }

        return .notFound("Unknown endpoint: \(request.path)")
    }

    // MARK: - GET Handlers

    /// GET /api/status
    /// Returns server health and basic info.
    private func handleStatus() async -> HTTPResponse {
        let openDocs = await getOpenDocuments()

        let response: [String: Any] = [
            "status": "ok",
            "app": "imprint",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "port": ImprintHTTPServer.defaultPort,
            "openDocuments": openDocs.count
        ]

        return .json(response)
    }

    /// GET /api/documents
    /// List all open documents.
    private func handleListDocuments() async -> HTTPResponse {
        let documents = await getOpenDocuments()

        let docDicts: [[String: Any]] = documents.map { doc in
            [
                "id": doc.id.uuidString,
                "title": doc.title,
                "authors": doc.authors,
                "modifiedAt": ISO8601DateFormatter().string(from: doc.modifiedAt),
                "createdAt": ISO8601DateFormatter().string(from: doc.createdAt),
                "citationCount": doc.bibliography.count
            ]
        }

        return .json([
            "status": "ok",
            "count": documents.count,
            "documents": docDicts
        ])
    }

    /// GET /api/documents/{id}
    /// Get document metadata.
    private func handleGetDocument(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        let response: [String: Any] = [
            "status": "ok",
            "document": [
                "id": doc.id.uuidString,
                "title": doc.title,
                "authors": doc.authors,
                "modifiedAt": ISO8601DateFormatter().string(from: doc.modifiedAt),
                "createdAt": ISO8601DateFormatter().string(from: doc.createdAt),
                "bibliography": Array(doc.bibliography.keys),
                "linkedImbibManuscriptID": doc.linkedImbibManuscriptID?.uuidString as Any
            ]
        ]

        return .json(response)
    }

    /// GET /api/documents/{id}/content
    /// Get document source content.
    private func handleGetDocumentContent(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        let response: [String: Any] = [
            "status": "ok",
            "id": doc.id.uuidString,
            "source": doc.source,
            "bibliography": doc.bibliography
        ]

        return .json(response)
    }

    /// GET /api/documents/{id}/outline
    /// Get document structure (headings).
    private func handleGetOutline(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        let outline = extractOutline(doc.source)

        let response: [String: Any] = [
            "status": "ok",
            "id": doc.id.uuidString,
            "outline": outline
        ]

        return .json(response)
    }

    /// GET /api/documents/{id}/pdf
    /// Download compiled PDF.
    private func handleGetPDF(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        // Get cached PDF from DocumentRegistry
        guard let pdfData = await MainActor.run(body: { DocumentRegistry.shared.cachedPDF[uuid] }) else {
            // Trigger compilation and wait briefly, or return error
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .compileDocument,
                    object: nil,
                    userInfo: ["documentID": uuid]
                )
            }
            // Wait a moment for compilation
            try? await Task.sleep(for: .milliseconds(500))

            // Check again
            if let pdfData = await MainActor.run(body: { DocumentRegistry.shared.cachedPDF[uuid] }) {
                return HTTPResponse(
                    status: 200,
                    statusText: "OK",
                    headers: [
                        "Content-Type": "application/pdf",
                        "Content-Disposition": "attachment; filename=\"\(doc.title).pdf\""
                    ],
                    body: pdfData
                )
            }

            return .notFound("PDF not available. Compile the document first using POST /api/documents/{id}/compile")
        }

        return HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: [
                "Content-Type": "application/pdf",
                "Content-Disposition": "attachment; filename=\"\(doc.title).pdf\""
            ],
            body: pdfData
        )
    }

    /// GET /api/documents/{id}/bibliography
    /// List all citations in the document.
    private func handleGetBibliography(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        let citations: [[String: String]] = doc.bibliography.map { key, bibtex in
            ["citeKey": key, "bibtex": bibtex]
        }

        let response: [String: Any] = [
            "status": "ok",
            "id": doc.id.uuidString,
            "count": doc.bibliography.count,
            "citations": citations
        ]

        return .json(response)
    }

    /// GET /api/documents/{id}/citations
    /// Find citation usages in source.
    private func handleGetCitationUsages(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        // Find all @citeKey occurrences in the source
        let usages = findCitationUsages(in: doc.source)

        let response: [String: Any] = [
            "status": "ok",
            "id": doc.id.uuidString,
            "usages": usages
        ]

        return .json(response)
    }

    /// GET /api/logs
    /// Query log entries.
    private func handleGetLogs(_ request: HTTPRequest) async -> HTTPResponse {
        await MainActor.run {
            LogEndpointHandler.handle(request)
        }
    }

    // MARK: - Export Handlers

    /// GET /api/documents/{id}/export/latex
    /// Export document as LaTeX.
    private func handleExportLatex(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        // Get optional template parameter
        let template = request.queryParams["template"] ?? "generic"

        // Convert Typst to LaTeX (simplified conversion)
        let latex = convertToLatex(doc.source, template: template)

        return HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: [
                "Content-Type": "text/x-latex; charset=utf-8",
                "Content-Disposition": "attachment; filename=\"\(doc.title).tex\""
            ],
            body: latex.data(using: .utf8) ?? Data()
        )
    }

    /// GET /api/documents/{id}/export/text
    /// Export document as plain text.
    private func handleExportText(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        // Strip Typst formatting for plain text
        let plainText = stripTypstFormatting(doc.source)

        return HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Disposition": "attachment; filename=\"\(doc.title).txt\""
            ],
            body: plainText.data(using: .utf8) ?? Data()
        )
    }

    /// GET /api/documents/{id}/export/typst
    /// Export Typst source with bibliography.
    private func handleExportTypst(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        // Combine source with bibliography
        var export = doc.source
        if !doc.bibliography.isEmpty {
            export += "\n\n// Bibliography\n"
            export += "// BibTeX entries are stored separately in bibliography.bib\n"
        }

        let response: [String: Any] = [
            "status": "ok",
            "id": doc.id.uuidString,
            "source": doc.source,
            "bibliography": doc.bibliography
        ]

        return .json(response)
    }

    // MARK: - POST Handlers

    /// POST /api/documents/create
    /// Create a new document.
    private func handleCreateDocument(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        let title = json["title"] as? String ?? "Untitled"
        let content = json["source"] as? String

        #if os(macOS)
        // Create new document on main thread
        let docId = await MainActor.run {
            let doc = ImprintDocument()
            // Note: We can't easily create documents programmatically in a document-based app
            // Return the ID of what would be created
            return doc.id
        }

        return .json([
            "status": "ok",
            "message": "Document creation requested",
            "id": docId.uuidString,
            "title": title
        ])
        #else
        return .badRequest("Document creation not supported on this platform")
        #endif
    }

    /// POST /api/documents/{id}/compile
    /// Compile document to PDF.
    private func handleCompile(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        // Post notification to trigger compilation
        await MainActor.run {
            NotificationCenter.default.post(
                name: .compileDocument,
                object: nil,
                userInfo: ["documentID": uuid]
            )
        }

        return .json([
            "status": "ok",
            "message": "Compilation triggered",
            "documentId": id
        ])
    }

    /// POST /api/compile/typst
    /// Stateless compile route — input is source bytes, output is PDF bytes.
    /// Per docs/plan-imprint-compile.md: this is the canonical cross-app
    /// compile authority. The journal pipeline's Archivist routes through
    /// this endpoint to produce real PDF artifacts. No document lifecycle
    /// side effects (unlike POST /api/documents/{id}/compile).
    ///
    /// Request body (JSON):
    ///   { "source": "= Hello\n\nBody.",
    ///     "page_size": "a4" | "letter" | "a5",          (optional, default a4)
    ///     "font_size": 11.0,                            (optional, default 11)
    ///     "margins": { "top": 72, "right": 72,
    ///                  "bottom": 72, "left": 72 } }     (optional, default 72pt all)
    ///
    /// Success: 200 OK, Content-Type: application/pdf, body = raw PDF bytes.
    /// Custom headers: X-Imprint-Compile-Status, X-Imprint-Page-Count,
    /// X-Imprint-Compile-Ms, X-Imprint-Warnings.
    ///
    /// Failure: 422 (compile error in source) or 500 (compiler crash) with
    /// JSON body { status, error, warnings, compile_ms }.
    private func handleStatelessCompile(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .badRequest("Body must be JSON: { source: \"...\", ... }")
        }

        guard let source = json["source"] as? String, !source.isEmpty else {
            return .badRequest("Missing or empty 'source' field")
        }

        // Map optional knobs to ImprintRustCore.CompileOptions. Defaults
        // mirror the editor preview defaults (A4, 11pt, 72pt margins).
        let pageSize: ImprintRustCore.FfiPageSize = {
            switch (json["page_size"] as? String)?.lowercased() {
            case "letter": return .letter
            case "a5":     return .a5
            default:       return .a4
            }
        }()
        let fontSize: Double = (json["font_size"] as? Double)
            ?? (json["font_size"] as? Int).map(Double.init)
            ?? 11.0

        let margins = (json["margins"] as? [String: Any]) ?? [:]
        func marginValue(_ key: String) -> Double {
            (margins[key] as? Double)
                ?? (margins[key] as? Int).map(Double.init)
                ?? 72.0
        }
        let options = ImprintRustCore.CompileOptions(
            pageSize: pageSize,
            fontSize: fontSize,
            marginTop: marginValue("top"),
            marginRight: marginValue("right"),
            marginBottom: marginValue("bottom"),
            marginLeft: marginValue("left")
        )

        // Run the synchronous Rust compile call on a background thread so it
        // doesn't block the HTTP server's actor.
        let start = Date()
        let result: ImprintRustCore.CompileResult = await Task.detached(priority: .userInitiated) {
            ImprintRustCore.compileTypstToPdf(source: source, options: options)
        }.value
        let compileMs = Int(Date().timeIntervalSince(start) * 1000)

        // Compiler error in source → 422.
        if let err = result.error {
            let payload: [String: Any] = [
                "status":     "error",
                "error":      err,
                "warnings":   result.warnings,
                "compile_ms": compileMs,
            ]
            return .json(payload, status: 422)
        }

        // Empty PDF → treat as 500 (compile said success but gave nothing).
        guard let pdfData = result.pdfData, !pdfData.isEmpty else {
            return .json([
                "status":     "error",
                "error":      "Compile succeeded but returned empty PDF",
                "warnings":   result.warnings,
                "compile_ms": compileMs,
            ] as [String: Any], status: 500)
        }

        var headers: [String: String] = [
            "Content-Type":             "application/pdf",
            "Content-Disposition":      "inline",
            "X-Imprint-Compile-Status": "ok",
            "X-Imprint-Page-Count":     "\(result.pageCount)",
            "X-Imprint-Compile-Ms":     "\(compileMs)",
        ]
        if !result.warnings.isEmpty {
            headers["X-Imprint-Warnings"] = result.warnings.joined(separator: "; ")
        }
        return HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: headers,
            body: Data(pdfData)
        )
    }

    /// POST /api/compile/bundle
    /// Compile a manuscript bundle (`.tar.zst` directory tree) to PDF. The
    /// archive is identified by its SHA-256 in the local content-addressed
    /// blob root (`~/.local/share/impress/content/{prefix}/{prefix}/{sha}.tar.zst`)
    /// — imprint and impel share the filesystem, so the journal pipeline
    /// passes a SHA reference rather than re-uploading binary bytes.
    ///
    /// Per `docs/plan-journal-pipeline.md` §Phase 8: imprint owns ALL
    /// compilation. Typst projects route through imprint-core's
    /// `compileTypstProjectToPdf`; LaTeX projects route through imprint's
    /// existing `LaTeXCompilationService` (pdflatex/xelatex/lualatex/latexmk).
    /// There is no parallel compile path in any other process.
    ///
    /// Request body (JSON):
    ///   { "bundle_sha256": "abc123…",
    ///     "main": "paper.typ",
    ///     "engine": "typst" | "pdflatex" | "xelatex" | "lualatex" | "latexmk" }
    ///
    /// Success: 200 OK, Content-Type: application/pdf, body = raw PDF bytes.
    /// Custom headers: X-Imprint-Compile-Status, X-Imprint-Page-Count,
    /// X-Imprint-Compile-Ms, X-Imprint-Warnings.
    ///
    /// Failure: 422 (compile error in source) or 500 (internal error) with
    /// JSON body { status, error, warnings, compile_ms }.
    private func handleBundleCompile(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .badRequest(
                "Body must be JSON: { bundle_sha256: \"...\", main: \"...\", engine: \"...\" }"
            )
        }

        guard let sha = json["bundle_sha256"] as? String, sha.count == 64,
              sha.allSatisfy(\.isHexDigit)
        else {
            return .badRequest("Missing or malformed 'bundle_sha256' field (expected 64 hex chars)")
        }
        guard let main = json["main"] as? String, !main.isEmpty else {
            return .badRequest("Missing or empty 'main' field (relative path of the entry source)")
        }
        guard let engineStr = json["engine"] as? String else {
            return .badRequest("Missing 'engine' field")
        }

        let blobURL = bundleArchiveURL(sha256: sha)
        guard FileManager.default.fileExists(atPath: blobURL.path) else {
            return .json([
                "status": "error",
                "error": "bundle archive not found in blob store: \(sha.prefix(12))…",
            ] as [String: Any], status: 404)
        }

        // Extract to a per-request temp dir.
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "imprint-bundle-compile-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: extractDir) }
        do {
            try FileManager.default.createDirectory(
                at: extractDir, withIntermediateDirectories: true
            )
        } catch {
            return .json([
                "status": "error",
                "error": "failed to create temp dir: \(error.localizedDescription)",
            ] as [String: Any], status: 500)
        }
        let extractStatus = await runTarExtract(archiveURL: blobURL, intoDir: extractDir)
        if let stderr = extractStatus {
            return .json([
                "status": "error",
                "error": "tar extraction failed: \(stderr)",
            ] as [String: Any], status: 500)
        }

        // Resolve main file inside the extracted dir.
        let mainURL = extractDir.appendingPathComponent(main)
        guard FileManager.default.fileExists(atPath: mainURL.path) else {
            return .json([
                "status": "error",
                "error": "main file \(main) not present in bundle",
            ] as [String: Any], status: 422)
        }

        let start = Date()
        switch engineStr.lowercased() {
        case "typst":
            return await dispatchBundleTypst(
                projectDir: extractDir,
                mainFile: main,
                start: start
            )
        case "pdflatex", "xelatex", "lualatex", "latexmk":
            #if os(macOS)
            return await dispatchBundleLaTeX(
                mainURL: mainURL,
                engine: engineStr.lowercased(),
                start: start
            )
            #else
            return .json([
                "status": "error",
                "error": "LaTeX compilation requires macOS (LaTeXCompilationService is macOS-only)",
            ] as [String: Any], status: 500)
            #endif
        case "none":
            return .json([
                "status": "error",
                "error": "engine=none means store-only; nothing to compile",
            ] as [String: Any], status: 422)
        default:
            return .badRequest(
                "Unknown engine \"\(engineStr)\"; expected typst|pdflatex|xelatex|lualatex|latexmk"
            )
        }
    }

    /// Dispatch a Typst bundle compile to imprint-core.
    private func dispatchBundleTypst(
        projectDir: URL,
        mainFile: String,
        start: Date
    ) async -> HTTPResponse {
        let projectPath = projectDir.path
        let result: ImprintRustCore.ProjectCompileResult = await Task.detached(priority: .userInitiated) {
            ImprintRustCore.compileTypstProjectToPdf(
                projectDir: projectPath,
                mainFile: mainFile
            )
        }.value
        let compileMs = Int(Date().timeIntervalSince(start) * 1000)

        if let err = result.error {
            return .json([
                "status": "error",
                "error": err,
                "warnings": result.warnings,
                "compile_ms": compileMs,
            ] as [String: Any], status: 422)
        }
        guard let pdfData = result.pdfData, !pdfData.isEmpty else {
            return .json([
                "status": "error",
                "error": "Compile succeeded but returned empty PDF",
                "warnings": result.warnings,
                "compile_ms": compileMs,
            ] as [String: Any], status: 500)
        }
        var headers: [String: String] = [
            "Content-Type": "application/pdf",
            "Content-Disposition": "inline",
            "X-Imprint-Compile-Status": "ok",
            "X-Imprint-Page-Count": "\(result.pageCount)",
            "X-Imprint-Compile-Ms": "\(compileMs)",
        ]
        if !result.warnings.isEmpty {
            headers["X-Imprint-Warnings"] = result.warnings.joined(separator: "; ")
        }
        return HTTPResponse(
            status: 200, statusText: "OK", headers: headers, body: Data(pdfData)
        )
    }

    #if os(macOS)
    /// Dispatch a LaTeX bundle compile to imprint's LaTeXCompilationService.
    private func dispatchBundleLaTeX(
        mainURL: URL,
        engine engineStr: String,
        start: Date
    ) async -> HTTPResponse {
        let engine: LaTeXEngine = {
            switch engineStr {
            case "xelatex": return .xelatex
            case "lualatex": return .lualatex
            case "latexmk": return .latexmk
            default: return .pdflatex
            }
        }()
        let options = LaTeXCompileOptions(engine: engine)
        do {
            let result = try await LaTeXCompilationService.shared.compile(
                sourceURL: mainURL,
                engine: engine,
                options: options
            )
            let compileMs = result.compilationTimeMs
            if !result.isSuccess {
                let firstError = result.errors.first?.message ?? "LaTeX compile failed (exit \(result.exitCode))"
                return .json([
                    "status": "error",
                    "error": firstError,
                    "warnings": result.warnings.map(\.message),
                    "compile_ms": compileMs,
                    "exit_code": result.exitCode,
                ] as [String: Any], status: 422)
            }
            guard let pdfData = result.pdfData, !pdfData.isEmpty else {
                return .json([
                    "status": "error",
                    "error": "LaTeX compile succeeded but returned empty PDF",
                    "warnings": result.warnings.map(\.message),
                    "compile_ms": compileMs,
                ] as [String: Any], status: 500)
            }
            var headers: [String: String] = [
                "Content-Type": "application/pdf",
                "Content-Disposition": "inline",
                "X-Imprint-Compile-Status": "ok",
                // Page count is not surfaced by LaTeXCompilationService; emit 0.
                "X-Imprint-Page-Count": "0",
                "X-Imprint-Compile-Ms": "\(compileMs)",
            ]
            if !result.warnings.isEmpty {
                headers["X-Imprint-Warnings"] = result.warnings.map(\.message).joined(separator: "; ")
            }
            return HTTPResponse(
                status: 200, statusText: "OK", headers: headers, body: pdfData
            )
        } catch {
            // LaTeXCompilationError.engineNotFound → engine-unavailable.
            let isEngineNotFound = String(describing: error).contains("engineNotFound")
            return .json([
                "status": "error",
                "error": isEngineNotFound
                    ? "LaTeX engine \(engineStr) not installed (no TeX distribution detected)"
                    : "LaTeX compile failed: \(error.localizedDescription)",
                "warnings": [String](),
                "compile_ms": Int(Date().timeIntervalSince(start) * 1000),
            ] as [String: Any], status: isEngineNotFound ? 503 : 500)
        }
    }
    #endif

    /// Resolve the on-disk URL of a bundle archive by SHA-256, matching
    /// imbib's BlobStore convention.
    private func bundleArchiveURL(sha256 sha: String) -> URL {
        let prefix1 = String(sha.prefix(2))
        let prefix2 = String(sha.dropFirst(2).prefix(2))
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("impress", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
            .appendingPathComponent("\(sha).tar.zst")
    }

    /// Shell to `/usr/bin/tar --zstd -xf` to extract a bundle archive.
    /// Returns nil on success; stderr text on failure.
    private func runTarExtract(archiveURL: URL, intoDir: URL) async -> String? {
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = [
                "--zstd",
                "-x",
                "-f", archiveURL.path,
                "-C", intoDir.path,
            ]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
            } catch {
                return "tar launch failed: \(error)"
            }
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return nil
            }
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "(unreadable)"
            return "tar exit \(process.terminationStatus): \(stderr)"
        }.value
    }

    /// POST /api/documents/{id}/insert-citation
    /// Insert a citation into the document.
    private func handleInsertCitation(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let citeKey = json["citeKey"] as? String else {
            return .badRequest("Missing 'citeKey' parameter")
        }

        let bibtex = json["bibtex"] as? String
        let position = json["position"] as? Int

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        // Post notification to insert citation
        await MainActor.run {
            NotificationCenter.default.post(
                name: .insertCitation,
                object: nil,
                userInfo: [
                    "documentID": uuid,
                    "citeKey": citeKey,
                    "bibtex": bibtex as Any,
                    "position": position as Any
                ]
            )
        }

        return .json([
            "status": "ok",
            "message": "Citation insert requested",
            "documentId": id,
            "citeKey": citeKey
        ])
    }

    /// POST /api/documents/{id}/update
    /// Update document content.
    private func handleUpdateDocument(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        // Queue operation for view to process
        let source = json["source"] as? String
        let title = json["title"] as? String
        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: uuid, kind: "updateContent")

        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .updateContent(operationID: opID, source: source, title: title),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Update requested",
            "documentId": id,
            "operationId": opID.uuidString
        ])
    }

    /// POST /api/documents/{id}/search
    /// Search for text in document.
    private func handleSearch(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let query = json["query"] as? String else {
            return .badRequest("Missing 'query' parameter")
        }

        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }

        let isRegex = json["regex"] as? Bool ?? false
        let caseSensitive = json["caseSensitive"] as? Bool ?? false

        let matches = searchText(
            in: doc.source,
            query: query,
            isRegex: isRegex,
            caseSensitive: caseSensitive
        )

        let response: [String: Any] = [
            "status": "ok",
            "id": doc.id.uuidString,
            "query": query,
            "matchCount": matches.count,
            "matches": matches
        ]

        return .json(response)
    }

    /// POST /api/documents/{id}/replace
    /// Search and replace in document.
    private func handleReplace(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let search = json["search"] as? String else {
            return .badRequest("Missing 'search' parameter")
        }

        guard let replacement = json["replacement"] as? String else {
            return .badRequest("Missing 'replacement' parameter")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        let replaceAll = json["all"] as? Bool ?? false
        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: uuid, kind: "replace")

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .replace(operationID: opID, search: search, replacement: replacement, all: replaceAll),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Replace requested",
            "documentId": id,
            "search": search,
            "replacement": replacement,
            "replaceAll": replaceAll,
            "operationId": opID.uuidString
        ])
    }

    /// POST /api/documents/{id}/insert
    /// Insert text at position.
    private func handleInsertText(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let position = json["position"] as? Int else {
            return .badRequest("Missing 'position' parameter")
        }

        guard let text = json["text"] as? String else {
            return .badRequest("Missing 'text' parameter")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: uuid, kind: "insertText")

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .insertText(operationID: opID, position: position, text: text),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Insert requested",
            "documentId": id,
            "position": position,
            "textLength": text.count,
            "operationId": opID.uuidString
        ])
    }

    /// POST /api/documents/{id}/delete
    /// Delete text range.
    private func handleDeleteText(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let start = json["start"] as? Int else {
            return .badRequest("Missing 'start' parameter")
        }

        guard let end = json["end"] as? Int else {
            return .badRequest("Missing 'end' parameter")
        }

        guard start < end else {
            return .badRequest("'start' must be less than 'end'")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: uuid, kind: "deleteText")

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .deleteText(operationID: opID, start: start, end: end),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Delete requested",
            "documentId": id,
            "start": start,
            "end": end,
            "deletedLength": end - start,
            "operationId": opID.uuidString
        ])
    }

    /// POST /api/documents/{id}/bibliography
    /// Add citation to bibliography.
    private func handleAddCitation(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let citeKey = json["citeKey"] as? String else {
            return .badRequest("Missing 'citeKey' parameter")
        }

        guard let bibtex = json["bibtex"] as? String else {
            return .badRequest("Missing 'bibtex' parameter")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: uuid, kind: "addCitation")

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .addCitation(operationID: opID, citeKey: citeKey, bibtex: bibtex),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Citation added",
            "documentId": id,
            "citeKey": citeKey,
            "operationId": opID.uuidString
        ])
    }

    // MARK: - PUT Handlers

    /// PUT /api/documents/{id}/metadata
    /// Update document metadata.
    private func handleUpdateMetadata(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        // Queue operation for view to process
        let title = json["title"] as? String
        let authors = json["authors"] as? [String]
        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: uuid, kind: "updateMetadata")

        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .updateMetadata(operationID: opID, title: title, authors: authors),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Metadata update requested",
            "documentId": id,
            "operationId": opID.uuidString
        ])
    }

    // MARK: - DELETE Handlers

    /// DELETE /api/documents/{id}/bibliography/{key}
    /// Remove citation from bibliography.
    private func handleRemoveCitation(id: String, citeKey: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: uuid, kind: "removeCitation")

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .removeCitation(operationID: opID, citeKey: citeKey),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Citation removal requested",
            "documentId": id,
            "citeKey": citeKey,
            "operationId": opID.uuidString
        ])
    }

    // MARK: - LaTeX Handlers

    /// GET /api/latex/status
    /// Returns TeX distribution info and available engines.
    private func handleLaTeXStatus() async -> HTTPResponse {
        #if os(macOS)
        let (distPath, isAvailable, engines) = await MainActor.run {
            (
                TeXDistributionManager.shared.distributionPath?.path,
                TeXDistributionManager.shared.isAvailable,
                TeXDistributionManager.shared.installedEngines.map(\.rawValue)
            )
        }

        let response: [String: Any] = [
            "status": "ok",
            "latex": [
                "available": isAvailable,
                "distributionPath": distPath as Any,
                "installedEngines": engines,
            ]
        ]
        return .json(response)
        #else
        return .json(["status": "ok", "latex": ["available": false, "reason": "LaTeX compilation requires macOS"]])
        #endif
    }

    /// GET /api/documents/{id}/diagnostics
    /// Returns structured compilation diagnostics (errors + warnings).
    private func handleGetDiagnostics(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        #if os(macOS)
        let diagnostics = await MainActor.run { DocumentRegistry.shared.cachedDiagnostics[uuid] ?? [] }

        let items: [[String: Any]] = diagnostics.map { diag in
            var item: [String: Any] = [
                "file": diag.file,
                "line": diag.line,
                "message": diag.message,
                "severity": diag.severity == .error ? "error" : (diag.severity == .warning ? "warning" : "info")
            ]
            if let col = diag.column { item["column"] = col }
            if let ctx = diag.context { item["context"] = ctx }
            return item
        }

        return .json([
            "status": "ok",
            "id": id,
            "diagnostics": items,
            "errorCount": diagnostics.filter { $0.severity == .error }.count,
            "warningCount": diagnostics.filter { $0.severity == .warning }.count
        ])
        #else
        return .json(["status": "ok", "id": id, "diagnostics": [], "errorCount": 0, "warningCount": 0])
        #endif
    }

    /// GET /api/documents/{id}/synctex?direction=forward&line=42&file=main.tex
    /// or GET /api/documents/{id}/synctex?direction=inverse&page=1&x=100&y=200
    /// SyncTeX bidirectional lookup.
    private func handleSyncTeX(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }

        guard await findDocument(by: uuid) != nil else {
            return .notFound("Document not found: \(id)")
        }

        let direction = request.queryParams["direction"] ?? "forward"

        #if os(macOS)
        if direction == "forward" {
            guard let lineStr = request.queryParams["line"],
                  let line = Int(lineStr) else {
                return .badRequest("Missing or invalid 'line' parameter")
            }
            let file = request.queryParams["file"] ?? "main.tex"
            let column = Int(request.queryParams["column"] ?? "0") ?? 0

            let positions = await SyncTeXService.shared.forwardSync(file: file, line: line, column: column)
            let items: [[String: Any]] = positions.map { pos in
                ["page": pos.page, "x": pos.x, "y": pos.y, "width": pos.width, "height": pos.height]
            }
            return .json(["status": "ok", "direction": "forward", "positions": items])

        } else if direction == "inverse" {
            guard let pageStr = request.queryParams["page"],
                  let page = Int(pageStr),
                  let xStr = request.queryParams["x"],
                  let x = Double(xStr),
                  let yStr = request.queryParams["y"],
                  let y = Double(yStr) else {
                return .badRequest("Missing or invalid 'page', 'x', or 'y' parameters")
            }

            if let loc = await SyncTeXService.shared.inverseSync(page: page, x: x, y: y) {
                return .json([
                    "status": "ok",
                    "direction": "inverse",
                    "source": ["file": loc.file, "line": loc.line, "column": loc.column]
                ])
            }
            return .json(["status": "ok", "direction": "inverse", "source": NSNull()])
        }

        return .badRequest("direction must be 'forward' or 'inverse'")
        #else
        return .badRequest("SyncTeX is only available on macOS")
        #endif
    }

    // MARK: - Store-backed Manuscript Handlers

    /// GET /api/manuscripts — list every manuscript document known to
    /// the shared store, sorted by most-recently-modified first. Same
    /// data the `RecentDocumentsSnapshot` drives the sidebar with.
    private func handleListManuscripts() async -> HTTPResponse {
        let entries = await MainActor.run { RecentDocumentsSnapshot.shared.documents }
        let iso = ISO8601DateFormatter()
        let payload: [[String: Any]] = entries.map { entry in
            [
                "id": entry.id.uuidString,
                "title": entry.title,
                "sectionCount": entry.sectionCount,
                "lastModified": iso.string(from: entry.lastModified),
                "firstSectionTitle": entry.firstSectionTitle,
                "totalWordCount": entry.totalWordCount
            ]
        }
        return .json([
            "status": "ok",
            "count": entries.count,
            "manuscripts": payload
        ])
    }

    /// GET /api/manuscripts/{id}/sections — list every stored section
    /// for a document, sorted by `order_index`. Body is inline; large
    /// content-addressed bodies are not rehydrated here — call
    /// `/api/sections/{id}` for those.
    private func handleManuscriptSections(id: String) -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid manuscript id: \(id)")
        }
        #if canImport(ImpressRustCore)
        let sections = ImprintImpressStore.shared.listSectionsForDocument(documentID: uuid)
        let payload: [[String: Any]] = sections.map { Self.sectionToJSON($0) }
        return .json([
            "status": "ok",
            "manuscriptID": id,
            "count": sections.count,
            "sections": payload
        ])
        #else
        return .json(["status": "ok", "manuscriptID": id, "count": 0, "sections": []])
        #endif
    }

    /// GET /api/sections/{id} — fetch a single section with its body
    /// rehydrated from content-addressed storage when needed.
    private func handleGetSection(id: String) -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid section id: \(id)")
        }
        #if canImport(ImpressRustCore)
        guard let section = ImprintImpressStore.shared.loadSection(id: uuid) else {
            return .notFound("Section not found: \(id)")
        }
        return .json(Self.sectionToJSON(section))
        #else
        return .notFound("Rust store not available")
        #endif
    }

    /// GET /api/search?q=...&limit=... — cross-document manuscript search.
    private func handleCrossDocumentSearch(_ request: HTTPRequest) async -> HTTPResponse {
        guard let query = request.queryParams["q"], !query.isEmpty else {
            return .badRequest("Missing query parameter 'q'")
        }
        let limit = Int(request.queryParams["limit"] ?? "50") ?? 50
        let hits = await ManuscriptSearchService.shared.search(query, limit: limit)
        let payload: [[String: Any]] = hits.map { hit in
            [
                "sectionID": hit.sectionID.uuidString,
                "documentID": hit.documentID?.uuidString ?? "",
                "title": hit.title,
                "sectionType": hit.sectionType ?? "",
                "excerpt": hit.excerpt,
                "score": hit.score,
                "matchedTerms": hit.matchedTerms
            ]
        }
        return .json([
            "status": "ok",
            "query": query,
            "count": hits.count,
            "results": payload
        ])
    }

    /// GET /api/citation-usages — list every citation-usage record.
    private func handleListCitationUsages() -> HTTPResponse {
        #if canImport(ImpressRustCore)
        let records = ImprintImpressStore.shared.listCitationUsages()
        let iso = ISO8601DateFormatter()
        let payload: [[String: Any]] = records.map { r in
            [
                "id": r.id.uuidString,
                "citeKey": r.citeKey,
                "sectionID": r.sectionID.uuidString,
                "documentID": r.documentID?.uuidString ?? "",
                "paperID": r.paperID?.uuidString ?? "",
                "firstCited": r.firstCited.map { iso.string(from: $0) } ?? "",
                "lastSeen": r.lastSeen.map { iso.string(from: $0) } ?? ""
            ]
        }
        return .json([
            "status": "ok",
            "count": records.count,
            "citationUsages": payload
        ])
        #else
        return .json(["status": "ok", "count": 0, "citationUsages": []])
        #endif
    }

    #if canImport(ImpressRustCore)
    private static func sectionToJSON(_ section: ManuscriptSection) -> [String: Any] {
        [
            "id": section.id.uuidString,
            "documentID": section.documentID?.uuidString ?? "",
            "title": section.title,
            "body": section.body ?? "",
            "sectionType": section.sectionType ?? "",
            "orderIndex": section.orderIndex,
            "wordCount": section.wordCount,
            "contentHash": section.contentHash ?? "",
            "createdAt": ISO8601DateFormatter().string(from: section.createdAt)
        ]
    }
    #endif

    // MARK: - Operation Tracking

    /// GET /api/operations/{id}
    /// Status of a queued automation operation: pending / completed / failed.
    private func handleGetOperation(id: String) -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid operation ID format")
        }
        guard let op = OperationTracker.shared.get(id: uuid) else {
            return .notFound("Unknown operation ID — it may have been purged or was never queued")
        }
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "status": "ok",
            "operationId": op.id.uuidString,
            "documentId": op.documentID.uuidString,
            "kind": op.kind,
            "state": op.status.rawValue,
            "queuedAt": iso.string(from: op.queuedAt)
        ]
        if let completed = op.completedAt {
            payload["completedAt"] = iso.string(from: completed)
        }
        if let err = op.errorMessage {
            payload["error"] = err
        }
        return .json(payload)
    }

    // MARK: - Section Handlers (document-scoped)

    /// GET /api/documents/{id}/outline/v2
    /// Richer outline that agents can drive directly: each entry has a stable
    /// section UUID, byte range, order index, section type, and word count.
    private func handleGetOutlineV2(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id) else {
            return .badRequest("Invalid document ID format")
        }
        guard let doc = await findDocument(by: uuid) else {
            return .notFound("Document not found: \(id)")
        }
        let sections = SectionExtractor.extract(from: doc.source, documentID: uuid)
        let payload: [[String: Any]] = sections.map { s in
            [
                "id": s.id.uuidString,
                "title": s.title,
                "level": s.level,
                "sectionType": s.sectionType ?? "",
                "orderIndex": s.orderIndex,
                "start": s.start,
                "end": s.end,
                "bodyStart": s.bodyStart,
                "wordCount": s.wordCount
            ]
        }
        return .json([
            "status": "ok",
            "documentId": id,
            "count": sections.count,
            "sections": payload
        ])
    }

    /// GET /api/documents/{docId}/sections — same as outline/v2 for convenience.
    private func handleListSectionsForDocument(id: String) async -> HTTPResponse {
        await handleGetOutlineV2(id: id)
    }

    /// GET /api/documents/{docId}/sections/{sectionKey}
    /// `sectionKey` is either a UUID (derived from the source) or a zero-based
    /// integer index into the document's outline. Returns the section's body
    /// content plus its range so agents can round-trip.
    private func handleGetSectionInDocument(docId: String, sectionKey: String) async -> HTTPResponse {
        guard let docUUID = UUID(uuidString: docId) else {
            return .badRequest("Invalid document ID format")
        }
        guard let doc = await findDocument(by: docUUID) else {
            return .notFound("Document not found: \(docId)")
        }
        let sections = SectionExtractor.extract(from: doc.source, documentID: docUUID)
        guard let section = resolveSection(sectionKey, in: sections) else {
            return .notFound("Section not found: \(sectionKey)")
        }
        let body = Self.substring(doc.source, start: section.bodyStart, end: section.end)
        return .json([
            "status": "ok",
            "documentId": docId,
            "id": section.id.uuidString,
            "title": section.title,
            "level": section.level,
            "sectionType": section.sectionType ?? "",
            "orderIndex": section.orderIndex,
            "start": section.start,
            "end": section.end,
            "bodyStart": section.bodyStart,
            "wordCount": section.wordCount,
            "body": body
        ])
    }

    /// PATCH /api/documents/{docId}/sections/{sectionKey}
    /// Body: `{"body": "…"}` — replace section body only (heading preserved).
    ///       `{"title": "…"}` — rename the heading; preserves level.
    ///       Both can be passed at once.
    private func handlePatchSection(docId: String, sectionKey: String, request: HTTPRequest) async -> HTTPResponse {
        guard let docUUID = UUID(uuidString: docId) else {
            return .badRequest("Invalid document ID format")
        }
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }
        let newBody = json["body"] as? String
        let newTitle = json["title"] as? String
        guard newBody != nil || newTitle != nil else {
            return .badRequest("Provide at least one of 'body' or 'title'")
        }
        guard let doc = await findDocument(by: docUUID) else {
            return .notFound("Document not found: \(docId)")
        }
        let sections = SectionExtractor.extract(from: doc.source, documentID: docUUID)
        guard let section = resolveSection(sectionKey, in: sections) else {
            return .notFound("Section not found: \(sectionKey)")
        }

        // Compose the new section text: heading line + body.
        let currentBody = Self.substring(doc.source, start: section.bodyStart, end: section.end)
        let bodyToWrite = newBody ?? currentBody
        let titleToWrite = newTitle ?? section.title
        let headingLine = Self.composeHeading(
            title: titleToWrite,
            level: section.level,
            format: SectionFormat.autoDetect(doc.source)
        )
        var newSectionText = headingLine + "\n" + bodyToWrite
        // Preserve the trailing newline between this section and the next, if any.
        if section.end < doc.source.count, !newSectionText.hasSuffix("\n") {
            newSectionText += "\n"
        }

        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: docUUID, kind: "patchSection")
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .replaceRange(
                    operationID: opID,
                    start: section.start,
                    end: section.end,
                    text: newSectionText
                ),
                for: docUUID
            )
        }

        return .json([
            "status": "ok",
            "message": "Section patch requested",
            "documentId": docId,
            "sectionId": section.id.uuidString,
            "operationId": opID.uuidString,
            "replacedRange": ["start": section.start, "end": section.end],
            "newLength": newSectionText.count
        ])
    }

    /// DELETE /api/documents/{docId}/sections/{sectionKey}
    /// Removes the section (heading + body) from the source.
    private func handleDeleteSection(docId: String, sectionKey: String) async -> HTTPResponse {
        guard let docUUID = UUID(uuidString: docId) else {
            return .badRequest("Invalid document ID format")
        }
        guard let doc = await findDocument(by: docUUID) else {
            return .notFound("Document not found: \(docId)")
        }
        let sections = SectionExtractor.extract(from: doc.source, documentID: docUUID)
        guard let section = resolveSection(sectionKey, in: sections) else {
            return .notFound("Section not found: \(sectionKey)")
        }
        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: docUUID, kind: "deleteSection")
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .deleteText(operationID: opID, start: section.start, end: section.end),
                for: docUUID
            )
        }
        return .json([
            "status": "ok",
            "message": "Section deletion requested",
            "documentId": docId,
            "sectionId": section.id.uuidString,
            "operationId": opID.uuidString,
            "removedRange": ["start": section.start, "end": section.end]
        ])
    }

    /// POST /api/documents/{docId}/sections
    /// Body: `{"title": "…", "body": "…"?, "level": 1, "position": "end"|"before:{key}"|"after:{key}"}`
    /// Default position is "end" (append to document).
    private func handleCreateSection(docId: String, request: HTTPRequest) async -> HTTPResponse {
        guard let docUUID = UUID(uuidString: docId) else {
            return .badRequest("Invalid document ID format")
        }
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }
        guard let title = json["title"] as? String, !title.isEmpty else {
            return .badRequest("Missing 'title' parameter")
        }
        let newBody = json["body"] as? String ?? ""
        let level = (json["level"] as? Int).map { max(1, min($0, 6)) } ?? 1
        let position = (json["position"] as? String) ?? "end"

        guard let doc = await findDocument(by: docUUID) else {
            return .notFound("Document not found: \(docId)")
        }
        let format = SectionFormat.autoDetect(doc.source)
        let sections = SectionExtractor.extract(from: doc.source, documentID: docUUID, format: format)
        let heading = Self.composeHeading(title: title, level: level, format: format)

        // Compute insert position based on the `position` parameter.
        let insertOffset: Int
        if position == "end" {
            insertOffset = doc.source.count
        } else if position.hasPrefix("before:") {
            let key = String(position.dropFirst("before:".count))
            guard let target = resolveSection(key, in: sections) else {
                return .badRequest("Unknown target section: \(key)")
            }
            insertOffset = target.start
        } else if position.hasPrefix("after:") {
            let key = String(position.dropFirst("after:".count))
            guard let target = resolveSection(key, in: sections) else {
                return .badRequest("Unknown target section: \(key)")
            }
            insertOffset = target.end
        } else {
            return .badRequest("Invalid 'position' — use 'end', 'before:{key}', or 'after:{key}'")
        }

        // Build the inserted text with appropriate padding.
        var text = ""
        if insertOffset > 0 && insertOffset == doc.source.count {
            // Appending at the very end: ensure blank line before.
            let chars = Array(doc.source)
            let trailing = chars.suffix(2)
            if trailing.count < 2 || trailing.last != "\n" { text += "\n" }
            if !(trailing.count == 2 && trailing[trailing.startIndex] == "\n" && trailing[chars.index(before: chars.endIndex)] == "\n") {
                text += "\n"
            }
        }
        text += heading + "\n" + newBody
        if !text.hasSuffix("\n") { text += "\n" }

        // Pre-compute the id the new section will have once the source re-parses
        // — the agent can round-trip by index anyway, but returning a stable
        // UUID here avoids a second outline fetch for the common case.
        let newOrderIndex = newOrderIndexFor(position: position, in: sections)
        let newID = SectionExtractor.sectionID(documentID: docUUID, title: title, orderIndex: newOrderIndex)

        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: docUUID, kind: "createSection")
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .insertText(operationID: opID, position: insertOffset, text: text),
                for: docUUID
            )
        }

        return .json([
            "status": "ok",
            "message": "Section create requested",
            "documentId": docId,
            "operationId": opID.uuidString,
            "predictedSectionId": newID.uuidString,
            "predictedOrderIndex": newOrderIndex,
            "insertedAt": insertOffset,
            "insertedLength": text.count
        ])
    }

    /// POST /api/documents/{docId}/sections/{sectionKey}/citations
    /// Atomic: given a cite key + BibTeX (typically from `/api/papers/resolve`
    /// on imbib), (a) add the entry to the document bibliography, and (b)
    /// insert `@citeKey` at the end of the section (or at `position` chars
    /// within the section body).
    ///
    /// Body: `{"citeKey":"...", "bibtex"?: "...", "position"?: int}`.
    /// `position` is a character offset *relative to the section body*
    /// (bodyStart = 0). When omitted, the citation is appended to the body.
    private func handleInsertCitationInSection(docId: String, sectionKey: String, request: HTTPRequest) async -> HTTPResponse {
        guard let docUUID = UUID(uuidString: docId) else {
            return .badRequest("Invalid document ID format")
        }
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }
        guard let citeKey = json["citeKey"] as? String, !citeKey.isEmpty else {
            return .badRequest("Missing 'citeKey' parameter")
        }
        let bibtex = json["bibtex"] as? String
        let relPosition = json["position"] as? Int

        guard let doc = await findDocument(by: docUUID) else {
            return .notFound("Document not found: \(docId)")
        }
        let format = SectionFormat.autoDetect(doc.source)
        let sections = SectionExtractor.extract(from: doc.source, documentID: docUUID, format: format)
        guard let section = resolveSection(sectionKey, in: sections) else {
            return .notFound("Section not found: \(sectionKey)")
        }

        // Compute the absolute insert position within the source.
        let absPosition: Int
        if let rel = relPosition {
            let bodyLen = section.end - section.bodyStart
            absPosition = section.bodyStart + max(0, min(rel, bodyLen))
        } else {
            // Append: trim trailing whitespace/newlines of the section body,
            // then insert a space + citation just before that trimmed boundary.
            let bodyEnd = section.end
            var insertAt = bodyEnd
            let chars = Array(doc.source)
            while insertAt > section.bodyStart {
                let prior = chars[insertAt - 1]
                if prior == "\n" || prior == " " || prior == "\t" {
                    insertAt -= 1
                } else {
                    break
                }
            }
            absPosition = insertAt
        }

        let citationText = Self.composeCitation(citeKey: citeKey, format: format, appendSpace: relPosition == nil)

        // Add to bibliography first (so the .bib projector sees it) — fire
        // this as its own operation, then queue the insertion.
        if let bibtex, !bibtex.isEmpty {
            let addOp = UUID()
            OperationTracker.shared.registerPending(id: addOp, documentID: docUUID, kind: "addCitation")
            await MainActor.run {
                DocumentRegistry.shared.queueOperation(
                    .addCitation(operationID: addOp, citeKey: citeKey, bibtex: bibtex),
                    for: docUUID
                )
            }
        }

        let insertOp = UUID()
        OperationTracker.shared.registerPending(id: insertOp, documentID: docUUID, kind: "insertCitation")
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .insertText(operationID: insertOp, position: absPosition, text: citationText),
                for: docUUID
            )
        }

        return .json([
            "status": "ok",
            "message": "Section citation insert requested",
            "documentId": docId,
            "sectionId": section.id.uuidString,
            "citeKey": citeKey,
            "position": absPosition,
            "insertedLength": citationText.count,
            "operationId": insertOp.uuidString
        ])
    }

    // MARK: - Comment Handlers

    /// GET /api/documents/{docId}/comments?filter=unresolved|resolved|all|mine&authorAgentId=...
    private func handleListComments(
        docId: String,
        filter: String?,
        authorAgentId: String?
    ) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: docId) else {
            return .badRequest("Invalid document ID format")
        }
        guard let service = await MainActor.run(body: { CommentRegistry.shared.service(for: uuid) }) else {
            return .notFound("No comment service registered for document \(docId) — is it open?")
        }
        let all = await MainActor.run { service.comments }
        var filtered = all
        switch (filter ?? "all").lowercased() {
        case "unresolved": filtered = filtered.filter { !$0.isResolved }
        case "resolved": filtered = filtered.filter { $0.isResolved }
        case "suggestions": filtered = filtered.filter { $0.proposedText != nil && !$0.isResolved }
        case "all": break
        default: break
        }
        if let agentID = authorAgentId {
            filtered = filtered.filter { $0.authorAgentId == agentID }
        }
        let payload: [[String: Any]] = filtered.map { Self.commentToDict($0) }
        return .json([
            "status": "ok",
            "documentId": docId,
            "count": payload.count,
            "comments": payload
        ])
    }

    /// POST /api/documents/{docId}/comments
    /// Body: `{"content": "...", "start": int, "end": int, "parentId"?: "uuid",
    ///         "proposedText"?: "...", "authorAgentId"?: "...", "authorName"?: "..."}`
    private func handleCreateComment(docId: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: docId) else {
            return .badRequest("Invalid document ID format")
        }
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }
        guard let content = json["content"] as? String, !content.isEmpty else {
            return .badRequest("Missing 'content'")
        }
        let start = (json["start"] as? Int) ?? 0
        let end = (json["end"] as? Int) ?? start
        let parentID = (json["parentId"] as? String).flatMap { UUID(uuidString: $0) }
        let proposedText = json["proposedText"] as? String
        let authorAgentId = json["authorAgentId"] as? String
        let authorName = json["authorName"] as? String

        guard let service = await MainActor.run(body: { CommentRegistry.shared.service(for: uuid) }) else {
            return .notFound("No comment service registered for document \(docId) — is it open?")
        }

        let comment = await MainActor.run {
            service.addComment(
                content: content,
                at: TextRange(start: start, end: end),
                parentId: parentID,
                proposedText: proposedText,
                authorAgentId: authorAgentId,
                authorName: authorName
            )
        }

        return .json([
            "status": "ok",
            "documentId": docId,
            "comment": Self.commentToDict(comment)
        ], status: 201)
    }

    /// PATCH /api/comments/{id}
    /// Body: any of `{"content": "...", "isResolved": bool, "proposedText": "..."}`.
    private func handlePatchComment(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let commentUUID = UUID(uuidString: id) else {
            return .badRequest("Invalid comment ID format")
        }
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }
        let (docID, service) = await MainActor.run { () -> (UUID?, CommentService?) in
            guard let docID = CommentRegistry.shared.documentID(forComment: commentUUID) else {
                return (nil, nil)
            }
            return (docID, CommentRegistry.shared.service(for: docID))
        }
        guard let docID, let service else {
            return .notFound("Comment not found: \(id)")
        }

        await MainActor.run {
            if let content = json["content"] as? String {
                service.updateComment(commentUUID, content: content)
            }
            if let proposedText = json["proposedText"] as? String {
                service.updateProposedText(commentUUID, proposedText: proposedText)
            }
            if let resolved = json["isResolved"] as? Bool {
                if resolved {
                    service.resolve(commentUUID, includeReplies: false)
                } else {
                    service.unresolve(commentUUID)
                }
            }
        }

        let snapshot = await MainActor.run { service.comments.first(where: { $0.id == commentUUID }) }
        guard let comment = snapshot else {
            return .notFound("Comment not found: \(id)")
        }
        return .json([
            "status": "ok",
            "documentId": docID.uuidString,
            "comment": Self.commentToDict(comment)
        ])
    }

    /// DELETE /api/comments/{id}
    private func handleDeleteComment(id: String) async -> HTTPResponse {
        guard let commentUUID = UUID(uuidString: id) else {
            return .badRequest("Invalid comment ID format")
        }
        let deleted = await MainActor.run { () -> Bool in
            guard let docID = CommentRegistry.shared.documentID(forComment: commentUUID),
                  let service = CommentRegistry.shared.service(for: docID) else {
                return false
            }
            service.deleteComment(commentUUID)
            return true
        }
        if !deleted {
            return .notFound("Comment not found: \(id)")
        }
        return .json(["status": "ok", "commentId": id, "deleted": true])
    }

    /// POST /api/comments/{id}/accept — apply the suggestion's `proposedText`,
    /// then resolve the comment. No-op if the comment isn't a suggestion.
    private func handleAcceptComment(id: String) async -> HTTPResponse {
        guard let commentUUID = UUID(uuidString: id) else {
            return .badRequest("Invalid comment ID format")
        }
        let (docID, comment) = await MainActor.run { () -> (UUID?, Comment?) in
            guard let docID = CommentRegistry.shared.documentID(forComment: commentUUID),
                  let service = CommentRegistry.shared.service(for: docID),
                  let c = service.comments.first(where: { $0.id == commentUUID }) else {
                return (nil, nil)
            }
            return (docID, c)
        }
        guard let docID, let comment else {
            return .notFound("Comment not found: \(id)")
        }
        guard let proposed = comment.proposedText else {
            return .badRequest("Comment is not a suggestion (no 'proposedText')")
        }
        let opID = UUID()
        OperationTracker.shared.registerPending(id: opID, documentID: docID, kind: "acceptSuggestion")
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .replaceRange(
                    operationID: opID,
                    start: comment.textRange.start,
                    end: comment.textRange.end,
                    text: proposed
                ),
                for: docID
            )
            CommentRegistry.shared.service(for: docID)?.resolve(commentUUID, includeReplies: false)
        }
        return .json([
            "status": "ok",
            "commentId": id,
            "documentId": docID.uuidString,
            "accepted": true,
            "operationId": opID.uuidString
        ])
    }

    /// POST /api/comments/{id}/reject — resolve without applying the suggestion.
    private func handleRejectComment(id: String) async -> HTTPResponse {
        guard let commentUUID = UUID(uuidString: id) else {
            return .badRequest("Invalid comment ID format")
        }
        let resolved = await MainActor.run { () -> Bool in
            guard let docID = CommentRegistry.shared.documentID(forComment: commentUUID),
                  let service = CommentRegistry.shared.service(for: docID) else {
                return false
            }
            service.resolve(commentUUID, includeReplies: false)
            return true
        }
        if !resolved {
            return .notFound("Comment not found: \(id)")
        }
        return .json(["status": "ok", "commentId": id, "rejected": true])
    }

    /// Convert a Comment to a JSON-serializable dictionary.
    private static func commentToDict(_ c: Comment) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": c.id.uuidString,
            "author": c.author,
            "authorId": c.authorId,
            "content": c.content,
            "range": ["start": c.textRange.start, "end": c.textRange.end],
            "createdAt": iso.string(from: c.createdAt),
            "modifiedAt": iso.string(from: c.modifiedAt),
            "isResolved": c.isResolved,
            "isSuggestion": c.isSuggestion
        ]
        if let parentID = c.parentId { dict["parentId"] = parentID.uuidString }
        if let proposed = c.proposedText { dict["proposedText"] = proposed }
        if let agent = c.authorAgentId { dict["authorAgentId"] = agent }
        return dict
    }

    /// Compose the citation token for the given format.
    private static func composeCitation(citeKey: String, format: SectionFormat, appendSpace: Bool) -> String {
        let token: String
        switch format {
        case .typst: token = "@\(citeKey)"
        case .latex: token = "\\cite{\(citeKey)}"
        }
        return appendSpace ? " " + token : token
    }

    // MARK: - Section helpers

    /// Resolve a section key (UUID string or integer order index) to a section.
    private func resolveSection(_ key: String, in sections: [ExtractedSection]) -> ExtractedSection? {
        if let uuid = UUID(uuidString: key) {
            return sections.first { $0.id == uuid }
        }
        if let idx = Int(key), idx >= 0, idx < sections.count {
            return sections[idx]
        }
        return nil
    }

    /// Substring by character offsets — tolerant of out-of-range values.
    private static func substring(_ source: String, start: Int, end: Int) -> String {
        let chars = Array(source)
        let lo = max(0, min(start, chars.count))
        let hi = max(lo, min(end, chars.count))
        return String(chars[lo..<hi])
    }

    /// Build a heading line at the given level for the given format.
    private static func composeHeading(title: String, level: Int, format: SectionFormat) -> String {
        switch format {
        case .typst:
            let prefix = String(repeating: "=", count: max(1, min(level, 6)))
            return "\(prefix) \(title)"
        case .latex:
            switch level {
            case 1: return "\\section{\(title)}"
            case 2: return "\\subsection{\(title)}"
            case 3: return "\\subsubsection{\(title)}"
            case 4: return "\\paragraph{\(title)}"
            default: return "\\subparagraph{\(title)}"
            }
        }
    }

    /// Predict the order index a newly-created section will occupy.
    private func newOrderIndexFor(position: String, in existing: [ExtractedSection]) -> Int {
        if position == "end" { return existing.count }
        if position.hasPrefix("before:") {
            let key = String(position.dropFirst("before:".count))
            if let target = resolveSection(key, in: existing) {
                return target.orderIndex
            }
        }
        if position.hasPrefix("after:") {
            let key = String(position.dropFirst("after:".count))
            if let target = resolveSection(key, in: existing) {
                return target.orderIndex + 1
            }
        }
        return existing.count
    }

    // MARK: - Store Timings Handlers

    /// GET /api/store-timings?top=20
    /// Returns a JSON snapshot of `StoreTimings.shared` — per-caller counts,
    /// mean/max latencies, and how much time was spent on the main thread.
    /// Mirrors imbib's endpoint so `impress-toolbox` can query either app.
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

    /// POST /api/store-timings/reset
    private func handleResetStoreTimings() -> HTTPResponse {
        StoreTimings.shared.reset()
        return .json(["status": "ok", "reset": true])
    }

    // MARK: - Helpers

    /// CORS preflight response.
    private func handleCORSPreflight() -> HTTPResponse {
        HTTPResponse(
            status: 204,
            statusText: "No Content",
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400"
            ]
        )
    }

    /// Root API info response.
    private func handleAPIInfo() -> HTTPResponse {
        let info: [String: Any] = [
            "name": "imprint HTTP API",
            "version": "2.0.0",
            "endpoints": [
                "GET /api/status": "Server health and info",
                "GET /api/logs": "Query log entries (params: limit, offset, level, category, search, after)",
                "GET /api/documents": "List open documents",
                "GET /api/documents/{id}": "Get document metadata",
                "GET /api/documents/{id}/content": "Get document source content",
                "GET /api/documents/{id}/outline": "Get document structure (headings)",
                "GET /api/documents/{id}/pdf": "Download compiled PDF",
                "GET /api/documents/{id}/bibliography": "List all citations",
                "GET /api/documents/{id}/citations": "Find citation usages in source",
                "GET /api/documents/{id}/export/latex": "Export as LaTeX (param: template)",
                "GET /api/documents/{id}/export/text": "Export as plain text",
                "GET /api/documents/{id}/export/typst": "Export Typst source + bibliography",
                "POST /api/documents/create": "Create new document (body: {title, source})",
                "POST /api/documents/{id}/compile": "Compile document to PDF",
                "POST /api/documents/{id}/insert-citation": "Insert citation (body: {citeKey, bibtex?, position?})",
                "POST /api/documents/{id}/update": "Update document content (body: {source?, title?})",
                "POST /api/documents/{id}/search": "Search for text (body: {query, regex?, caseSensitive?})",
                "POST /api/documents/{id}/replace": "Search and replace (body: {search, replacement, all?})",
                "POST /api/documents/{id}/insert": "Insert text (body: {position, text})",
                "POST /api/documents/{id}/delete": "Delete text range (body: {start, end})",
                "POST /api/documents/{id}/bibliography": "Add citation (body: {citeKey, bibtex})",
                "PUT /api/documents/{id}/metadata": "Update metadata (body: {title?, authors?})",
                "DELETE /api/documents/{id}/bibliography/{key}": "Remove citation",
                "GET /api/latex/status": "TeX distribution info and available engines",
                "GET /api/documents/{id}/diagnostics": "Structured compilation diagnostics",
                "GET /api/documents/{id}/synctex": "SyncTeX lookup (params: direction, line/file or page/x/y)"
            ],
            "port": ImprintHTTPServer.defaultPort,
            "localhost_only": true
        ]
        return .json(info)
    }

    // MARK: - Text Processing Helpers

    /// Extract document outline from Typst source.
    private func extractOutline(_ source: String) -> [[String: Any]] {
        var outline: [[String: Any]] = []
        let lines = source.components(separatedBy: .newlines)
        var lineOffset = 0

        for (lineNumber, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Typst headings start with = (level 1), == (level 2), etc.
            if trimmed.hasPrefix("=") {
                var level = 0
                for char in trimmed {
                    if char == "=" {
                        level += 1
                    } else {
                        break
                    }
                }

                let title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    outline.append([
                        "level": level,
                        "title": title,
                        "line": lineNumber + 1,
                        "position": lineOffset
                    ])
                }
            }

            lineOffset += line.count + 1 // +1 for newline
        }

        return outline
    }

    /// Find citation usages in source text.
    private func findCitationUsages(in source: String) -> [[String: Any]] {
        var usages: [[String: Any]] = []

        // Match @citeKey patterns
        let pattern = #"@([a-zA-Z][a-zA-Z0-9_:-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return usages
        }

        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        for match in matches {
            if let keyRange = Range(match.range(at: 1), in: source) {
                let citeKey = String(source[keyRange])
                let position = match.range.location

                usages.append([
                    "citeKey": citeKey,
                    "position": position,
                    "length": match.range.length
                ])
            }
        }

        return usages
    }

    /// Search for text in source.
    private func searchText(
        in source: String,
        query: String,
        isRegex: Bool,
        caseSensitive: Bool
    ) -> [[String: Any]] {
        var matches: [[String: Any]] = []

        if isRegex {
            var options: NSRegularExpression.Options = []
            if !caseSensitive {
                options.insert(.caseInsensitive)
            }

            guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                return matches
            }

            let nsSource = source as NSString
            let regexMatches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

            for match in regexMatches {
                if let range = Range(match.range, in: source) {
                    let matchedText = String(source[range])
                    matches.append([
                        "position": match.range.location,
                        "length": match.range.length,
                        "text": matchedText
                    ])
                }
            }
        } else {
            var searchOptions: String.CompareOptions = []
            if !caseSensitive {
                searchOptions.insert(.caseInsensitive)
            }

            var searchRange = source.startIndex..<source.endIndex
            while let range = source.range(of: query, options: searchOptions, range: searchRange) {
                let position = source.distance(from: source.startIndex, to: range.lowerBound)
                let length = source.distance(from: range.lowerBound, to: range.upperBound)
                let matchedText = String(source[range])

                matches.append([
                    "position": position,
                    "length": length,
                    "text": matchedText
                ])

                searchRange = range.upperBound..<source.endIndex
            }
        }

        return matches
    }

    /// Convert Typst source to LaTeX (simplified conversion).
    private func convertToLatex(_ source: String, template: String) -> String {
        var latex = source

        // Document class based on template
        let documentClass: String
        switch template.lowercased() {
        case "mnras":
            documentClass = "\\documentclass{mnras}"
        case "aastex", "apj":
            documentClass = "\\documentclass{aastex631}"
        case "article":
            documentClass = "\\documentclass{article}"
        default:
            documentClass = "\\documentclass{article}"
        }

        // Convert Typst headings to LaTeX
        // = Title -> \section{Title}
        // == Subtitle -> \subsection{Subtitle}
        latex = latex.replacingOccurrences(
            of: #"^===\s*(.+)$"#,
            with: "\\subsubsection{$1}",
            options: .regularExpression
        )
        latex = latex.replacingOccurrences(
            of: #"^==\s*(.+)$"#,
            with: "\\subsection{$1}",
            options: .regularExpression
        )
        latex = latex.replacingOccurrences(
            of: #"^=\s*(.+)$"#,
            with: "\\section{$1}",
            options: .regularExpression
        )

        // Convert emphasis
        latex = latex.replacingOccurrences(
            of: #"_([^_]+)_"#,
            with: "\\emph{$1}",
            options: .regularExpression
        )
        latex = latex.replacingOccurrences(
            of: #"\*([^*]+)\*"#,
            with: "\\textbf{$1}",
            options: .regularExpression
        )

        // Convert citations @key -> \cite{key}
        latex = latex.replacingOccurrences(
            of: #"@([a-zA-Z][a-zA-Z0-9_:-]*)"#,
            with: "\\cite{$1}",
            options: .regularExpression
        )

        // Wrap in document structure
        return """
        \(documentClass)

        \\begin{document}

        \(latex)

        \\end{document}
        """
    }

    /// Strip Typst formatting for plain text export.
    private func stripTypstFormatting(_ source: String) -> String {
        var text = source

        // Remove Typst comments
        text = text.replacingOccurrences(
            of: #"//.*$"#,
            with: "",
            options: .regularExpression
        )

        // Convert headings to plain text with underlines
        text = text.replacingOccurrences(
            of: #"^=+\s*(.+)$"#,
            with: "$1",
            options: .regularExpression
        )

        // Remove emphasis markers
        text = text.replacingOccurrences(
            of: #"_([^_]+)_"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\*([^*]+)\*"#,
            with: "$1",
            options: .regularExpression
        )

        // Convert citations to readable form
        text = text.replacingOccurrences(
            of: #"@([a-zA-Z][a-zA-Z0-9_:-]*)"#,
            with: "[$1]",
            options: .regularExpression
        )

        // Remove multiple blank lines
        text = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get all open documents from the registry.
    @MainActor
    private func getOpenDocuments() -> [ImprintDocument] {
        // Use the DocumentRegistry which is populated by ContentView.onAppear
        return DocumentRegistry.shared.allDocuments
    }

    /// Find a specific document by ID.
    @MainActor
    private func findDocument(by id: UUID) -> ImprintDocument? {
        return DocumentRegistry.shared.document(withId: id)
    }
}


// MARK: - Notification Names

extension Notification.Name {
    /// Notification to update document content via API.
    static let updateDocumentContent = Notification.Name("updateDocumentContent")

    /// Notification to perform search and replace in document.
    static let replaceInDocument = Notification.Name("replaceInDocument")

    /// Notification to insert text at position.
    static let insertTextInDocument = Notification.Name("insertTextInDocument")

    /// Notification to delete text range.
    static let deleteTextInDocument = Notification.Name("deleteTextInDocument")

    /// Notification to add citation to bibliography.
    static let addCitationToDocument = Notification.Name("addCitationToDocument")

    /// Notification to remove citation from bibliography.
    static let removeCitationFromDocument = Notification.Name("removeCitationFromDocument")

    /// Notification to update document metadata.
    static let updateDocumentMetadata = Notification.Name("updateDocumentMetadata")
}
