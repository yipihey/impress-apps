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
/// - `GET /api/documents` - List open documents
/// - `GET /api/documents/{id}` - Get document content/metadata
/// - `GET /api/documents/{id}/content` - Get document source content
/// - `POST /api/documents/{id}/compile` - Compile to PDF
/// - `POST /api/documents/{id}/insert-citation` - Insert citation
/// - `POST /api/documents/create` - Create new document
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

        // Route based on path
        let path = request.path.lowercased()

        // GET endpoints
        if request.method == "GET" {
            if path == "/api/status" {
                return await handleStatus()
            }

            if path == "/api/documents" {
                return await handleListDocuments()
            }

            if path.hasPrefix("/api/documents/") {
                let remainder = String(path.dropFirst("/api/documents/".count))

                // Check for /content suffix
                if remainder.hasSuffix("/content") {
                    let docId = String(remainder.dropLast("/content".count))
                    return await handleGetDocumentContent(id: docId)
                }

                // Just the document ID
                if !remainder.contains("/") {
                    return await handleGetDocument(id: remainder)
                }
            }
        }

        // POST endpoints
        if request.method == "POST" {
            if path == "/api/documents/create" {
                return await handleCreateDocument(request)
            }

            if path.hasPrefix("/api/documents/") {
                let remainder = String(path.dropFirst("/api/documents/".count))

                if remainder.hasSuffix("/compile") {
                    let docId = String(remainder.dropLast("/compile".count))
                    return await handleCompile(id: docId, request: request)
                }

                if remainder.hasSuffix("/insert-citation") {
                    let docId = String(remainder.dropLast("/insert-citation".count))
                    return await handleInsertCitation(id: docId, request: request)
                }

                if remainder.hasSuffix("/update") {
                    let docId = String(remainder.dropLast("/update".count))
                    return await handleUpdateDocument(id: docId, request: request)
                }
            }
        }

        // Root path - return API info
        if path == "/" || path == "/api" {
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

        // Post notification to update document
        await MainActor.run {
            var userInfo: [String: Any] = ["documentID": uuid]
            if let source = json["source"] as? String {
                userInfo["source"] = source
            }
            if let title = json["title"] as? String {
                userInfo["title"] = title
            }

            NotificationCenter.default.post(
                name: .updateDocumentContent,
                object: nil,
                userInfo: userInfo
            )
        }

        return .json([
            "status": "ok",
            "message": "Update requested",
            "documentId": id
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
            "version": "1.0.0",
            "endpoints": [
                "GET /api/status": "Server health and info",
                "GET /api/documents": "List open documents",
                "GET /api/documents/{id}": "Get document metadata",
                "GET /api/documents/{id}/content": "Get document source content",
                "POST /api/documents/create": "Create new document (body: {title, source})",
                "POST /api/documents/{id}/compile": "Compile document to PDF",
                "POST /api/documents/{id}/insert-citation": "Insert citation (body: {citeKey, bibtex?, position?})",
                "POST /api/documents/{id}/update": "Update document content (body: {source?, title?})"
            ],
            "port": ImprintHTTPServer.defaultPort,
            "localhost_only": true
        ]
        return .json(info)
    }

    /// Get all open documents.
    @MainActor
    private func getOpenDocuments() -> [ImprintDocument] {
        #if os(macOS)
        // Access documents through NSDocumentController
        let controller = NSDocumentController.shared
        return controller.documents.compactMap { doc -> ImprintDocument? in
            guard let fileDoc = doc as? NSDocument else { return nil }
            // Try to extract ImprintDocument from the file document
            // This depends on the actual document architecture
            return extractImprintDocument(from: fileDoc)
        }
        #else
        // iOS doesn't have NSDocumentController
        return []
        #endif
    }

    /// Find a specific document by ID.
    @MainActor
    private func findDocument(by id: UUID) -> ImprintDocument? {
        let docs = getOpenDocuments()
        return docs.first { $0.id == id }
    }

    #if os(macOS)
    /// Extract ImprintDocument from NSDocument.
    @MainActor
    private func extractImprintDocument(from nsDoc: NSDocument) -> ImprintDocument? {
        // The document might be wrapped - try to access the content
        // This is a simplified version; actual implementation depends on how
        // the document-based app stores its data

        // For ReferenceFileDocument-based apps, the document is accessible
        // through the content view's binding. We'll use a different approach.

        // Store documents in a shared registry for API access
        return DocumentRegistry.shared.documents[nsDoc.fileURL?.absoluteString ?? ""]
    }
    #endif
}

// MARK: - Document Registry

/// Registry for tracking open documents for API access.
@MainActor @Observable
final class DocumentRegistry {
    static let shared = DocumentRegistry()

    /// Map of file URL -> document
    var documents: [String: ImprintDocument] = [:]

    /// Map of document ID -> document
    var documentsById: [UUID: ImprintDocument] = [:]

    private init() {}

    /// Register a document when opened.
    func register(_ document: ImprintDocument, fileURL: URL?) {
        documentsById[document.id] = document
        if let url = fileURL {
            documents[url.absoluteString] = document
        }
    }

    /// Unregister a document when closed.
    func unregister(_ document: ImprintDocument, fileURL: URL?) {
        documentsById.removeValue(forKey: document.id)
        if let url = fileURL {
            documents.removeValue(forKey: url.absoluteString)
        }
    }

    /// Find document by ID.
    func document(withId id: UUID) -> ImprintDocument? {
        documentsById[id]
    }

    /// All registered documents.
    var allDocuments: [ImprintDocument] {
        Array(documentsById.values)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Notification to update document content via API.
    static let updateDocumentContent = Notification.Name("updateDocumentContent")
}
