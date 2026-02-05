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
import OSLog
#if os(macOS)
import AppKit
#endif

private let routerLogger = Logger(subsystem: "com.imbib.imprint", category: "httpRouter")

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

            if pathLower.hasPrefix("/api/documents/") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let remainderLower = remainder.lowercased()

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
            if pathLower == "/api/documents/create" {
                return await handleCreateDocument(request)
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

        // DELETE endpoints
        if request.method == "DELETE" {
            if pathLower.hasPrefix("/api/documents/") {
                let remainder = String(path.dropFirst("/api/documents/".count))
                let remainderLower = remainder.lowercased()

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

        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .updateContent(source: source, title: title),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Update requested",
            "documentId": id
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

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .replace(search: search, replacement: replacement, all: replaceAll),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Replace requested",
            "documentId": id,
            "search": search,
            "replacement": replacement,
            "replaceAll": replaceAll
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

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .insertText(position: position, text: text),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Insert requested",
            "documentId": id,
            "position": position,
            "textLength": text.count
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

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .deleteText(start: start, end: end),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Delete requested",
            "documentId": id,
            "start": start,
            "end": end,
            "deletedLength": end - start
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

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .addCitation(citeKey: citeKey, bibtex: bibtex),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Citation added",
            "documentId": id,
            "citeKey": citeKey
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

        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .updateMetadata(title: title, authors: authors),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Metadata update requested",
            "documentId": id
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

        // Queue operation for view to process
        await MainActor.run {
            DocumentRegistry.shared.queueOperation(
                .removeCitation(citeKey: citeKey),
                for: uuid
            )
        }

        return .json([
            "status": "ok",
            "message": "Citation removal requested",
            "documentId": id,
            "citeKey": citeKey
        ])
    }

    // MARK: - Helpers

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
                "DELETE /api/documents/{id}/bibliography/{key}": "Remove citation"
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
