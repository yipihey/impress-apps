//
//  ImpartHTTPRouter.swift
//  MessageManagerCore
//
//  HTTP API router for AI agent and MCP integration.
//

import Foundation
import ImpressAutomation
import OSLog

private let routerLogger = Logger(subsystem: "com.imbib.impart", category: "httpRouter")

// MARK: - HTTP Automation Router

/// Routes HTTP requests to appropriate handlers.
///
/// API Endpoints:
/// - `GET /api/status` - Server health
/// - `GET /api/accounts` - List accounts
/// - `GET /api/mailboxes` - List mailboxes
/// - `GET /api/messages` - List messages in mailbox
/// - `GET /api/messages/{id}` - Get message detail
/// - `POST /api/messages/send` - Send message (future)
/// - Research Conversation endpoints:
/// - `GET /api/research/conversations` - List research conversations
/// - `GET /api/research/conversations/{id}` - Get conversation with messages
/// - `GET /api/artifacts/{encodedUri}` - Resolve artifact reference
/// - `GET /api/provenance/trace/{messageId}` - Trace provenance chain
/// - `OPTIONS /*` - CORS preflight
public actor ImpartHTTPRouter: HTTPRouter {

    // MARK: - Dependencies

    private var artifactResolver: ArtifactResolver?
    private var provenanceService: ProvenanceService?

    // MARK: - Initialization

    public init() {}

    /// Configure services for research conversation endpoints.
    public func configure(
        artifactResolver: ArtifactResolver,
        provenanceService: ProvenanceService
    ) {
        self.artifactResolver = artifactResolver
        self.provenanceService = provenanceService
    }

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

            if path == "/api/accounts" {
                return await handleListAccounts()
            }

            if path == "/api/mailboxes" {
                return await handleListMailboxes(request)
            }

            if path == "/api/messages" {
                return await handleListMessages(request)
            }

            if path.hasPrefix("/api/messages/") {
                let messageId = String(path.dropFirst("/api/messages/".count))
                return await handleGetMessage(id: messageId)
            }

            // Research conversation endpoints
            if path == "/api/research/conversations" {
                return await handleListResearchConversations(request)
            }

            if path.hasPrefix("/api/research/conversations/") {
                let conversationId = String(path.dropFirst("/api/research/conversations/".count))
                return await handleGetResearchConversation(id: conversationId)
            }

            if path.hasPrefix("/api/artifacts/") {
                let encodedUri = String(path.dropFirst("/api/artifacts/".count))
                return await handleResolveArtifact(encodedUri: encodedUri)
            }

            if path.hasPrefix("/api/provenance/trace/") {
                let messageId = String(path.dropFirst("/api/provenance/trace/".count))
                return await handleProvenanceTrace(messageId: messageId)
            }
        }

        // POST endpoints
        if request.method == "POST" {
            if path == "/api/messages/send" {
                return await handleSendMessage(request)
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
        let response: [String: Any] = [
            "status": "ok",
            "app": "impart",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "port": ImpartHTTPServer.defaultPort,
            "accounts": 0  // TODO: Get actual count
        ]

        return .json(response)
    }

    /// GET /api/accounts
    /// List all configured accounts.
    private func handleListAccounts() async -> HTTPResponse {
        // TODO: Implement account listing
        return .json([
            "status": "ok",
            "count": 0,
            "accounts": [] as [Any]
        ])
    }

    /// GET /api/mailboxes?account={id}
    /// List mailboxes for an account.
    private func handleListMailboxes(_ request: HTTPRequest) async -> HTTPResponse {
        // TODO: Parse account from query and return mailboxes
        return .json([
            "status": "ok",
            "count": 0,
            "mailboxes": [] as [Any]
        ])
    }

    /// GET /api/messages?mailbox={id}&limit={n}&offset={n}
    /// List messages in a mailbox.
    private func handleListMessages(_ request: HTTPRequest) async -> HTTPResponse {
        // TODO: Parse mailbox/limit/offset from query and return messages
        return .json([
            "status": "ok",
            "count": 0,
            "messages": [] as [Any]
        ])
    }

    /// GET /api/messages/{id}
    /// Get message detail.
    private func handleGetMessage(id: String) async -> HTTPResponse {
        guard let _ = UUID(uuidString: id) else {
            return .badRequest("Invalid message ID format")
        }

        // TODO: Fetch message by ID
        return .notFound("Message not found: \(id)")
    }

    // MARK: - POST Handlers

    /// POST /api/messages/send
    /// Send a message.
    private func handleSendMessage(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let accountId = json["accountId"] as? String,
              let _ = UUID(uuidString: accountId) else {
            return .badRequest("Missing or invalid 'accountId' parameter")
        }

        guard let to = json["to"] as? [String], !to.isEmpty else {
            return .badRequest("Missing 'to' recipients")
        }

        // TODO: Create draft and send via SMTP
        return .json([
            "status": "ok",
            "message": "Send not yet implemented"
        ])
    }

    // MARK: - Research Conversation Handlers

    /// GET /api/research/conversations
    /// List all research conversations.
    private func handleListResearchConversations(_ request: HTTPRequest) async -> HTTPResponse {
        // TODO: Implement with ResearchConversationQuery
        let limit = request.queryParameters["limit"].flatMap { Int($0) } ?? 50
        let offset = request.queryParameters["offset"].flatMap { Int($0) } ?? 0
        let includeArchived = request.queryParameters["includeArchived"] == "true"

        // Placeholder response
        return .json([
            "status": "ok",
            "count": 0,
            "conversations": [] as [Any],
            "query": [
                "limit": limit,
                "offset": offset,
                "includeArchived": includeArchived
            ] as [String: Any]
        ])
    }

    /// GET /api/research/conversations/{id}
    /// Get a research conversation with messages.
    private func handleGetResearchConversation(id: String) async -> HTTPResponse {
        guard let _ = UUID(uuidString: id) else {
            return .badRequest("Invalid conversation ID format")
        }

        // TODO: Fetch conversation from persistence
        return .notFound("Research conversation not found: \(id)")
    }

    /// GET /api/artifacts/{encodedUri}
    /// Resolve an artifact URI.
    private func handleResolveArtifact(encodedUri: String) async -> HTTPResponse {
        guard let uri = encodedUri.removingPercentEncoding else {
            return .badRequest("Invalid URI encoding")
        }

        guard let resolver = artifactResolver else {
            return .json([
                "status": "error",
                "error": "Artifact resolver not configured"
            ])
        }

        do {
            let resolved = try await resolver.resolve(uri)

            var response: [String: Any] = [
                "status": "ok",
                "uri": uri,
                "isResolved": resolved.isResolved,
                "displayName": resolved.reference.displayName,
                "type": resolved.reference.type.rawValue
            ]

            if let error = resolved.error {
                response["error"] = error
            }

            return .json(response)
        } catch {
            return .json([
                "status": "error",
                "uri": uri,
                "error": error.localizedDescription
            ])
        }
    }

    /// GET /api/provenance/trace/{messageId}
    /// Trace provenance chain for a message.
    private func handleProvenanceTrace(messageId: String) async -> HTTPResponse {
        guard let service = provenanceService else {
            return .json([
                "status": "error",
                "error": "Provenance service not configured"
            ])
        }

        guard let eventId = ProvenanceEventId(string: messageId) else {
            return .badRequest("Invalid event ID format")
        }

        let lineage = await service.traceLineage(from: eventId)

        let events = lineage.map { event -> [String: Any] in
            [
                "id": event.id.description,
                "sequence": event.sequence,
                "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
                "conversationId": event.conversationId,
                "actorId": event.actorId,
                "description": event.eventDescription
            ]
        }

        return .json([
            "status": "ok",
            "messageId": messageId,
            "lineageCount": lineage.count,
            "events": events
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
            "name": "impart HTTP API",
            "version": "1.0.0",
            "endpoints": [
                "GET /api/status": "Server health and info",
                "GET /api/accounts": "List configured accounts",
                "GET /api/mailboxes?account={id}": "List mailboxes for account",
                "GET /api/messages?mailbox={id}&limit={n}&offset={n}": "List messages in mailbox",
                "GET /api/messages/{id}": "Get message detail",
                "POST /api/messages/send": "Send message (body: {accountId, to, cc?, bcc?, subject, body})",
                "GET /api/research/conversations": "List research conversations",
                "GET /api/research/conversations/{id}": "Get conversation with messages",
                "GET /api/artifacts/{encodedUri}": "Resolve artifact reference",
                "GET /api/provenance/trace/{eventId}": "Trace provenance chain"
            ],
            "port": ImpartHTTPServer.defaultPort,
            "localhost_only": true
        ]
        return .json(info)
    }
}

// MARK: - HTTP Server

/// Local HTTP server for AI agent and MCP integration.
///
/// Runs on `127.0.0.1:23122` (localhost only for security).
public actor ImpartHTTPServer {

    // MARK: - Singleton

    public static let shared = ImpartHTTPServer()

    // MARK: - Configuration

    /// Default port (after imbib's 23120, imprint's 23121)
    public static let defaultPort: UInt16 = 23122

    // MARK: - Settings

    /// Whether the HTTP server is enabled
    @MainActor
    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "httpAutomationEnabled")
    }

    /// The configured port
    @MainActor
    private static var configuredPort: UInt16 {
        let port = UserDefaults.standard.integer(forKey: "httpAutomationPort")
        return port > 0 ? UInt16(port) : defaultPort
    }

    // MARK: - State

    private let server: HTTPServer<ImpartHTTPRouter>
    private let router: ImpartHTTPRouter

    // MARK: - Initialization

    private init() {
        self.router = ImpartHTTPRouter()
        self.server = HTTPServer(router: router)
    }

    // MARK: - Lifecycle

    /// Start the HTTP server on the configured port.
    @MainActor
    public func start() async {
        let alreadyRunning = await server.running
        guard !alreadyRunning else {
            routerLogger.info("HTTP server already running")
            return
        }

        guard Self.isEnabled else {
            routerLogger.info("HTTP server is disabled in settings")
            return
        }

        let configuration = HTTPServerConfiguration(
            port: Self.configuredPort,
            loggerSubsystem: "com.imbib.impart",
            loggerCategory: "httpServer",
            logRequests: true
        )

        await server.start(configuration: configuration)
    }

    /// Stop the HTTP server.
    public func stop() async {
        await server.stop()
    }

    /// Restart the server (e.g., after port change).
    @MainActor
    public func restart() async {
        let configuration = HTTPServerConfiguration(
            port: Self.configuredPort,
            loggerSubsystem: "com.imbib.impart",
            loggerCategory: "httpServer",
            logRequests: true
        )

        await server.restart(configuration: configuration)
    }

    /// Check if the server is currently running.
    public var running: Bool {
        get async {
            await server.running
        }
    }
}
