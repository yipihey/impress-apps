//
//  ImpartHTTPRouter.swift
//  MessageManagerCore
//
//  HTTP API router for AI agent and MCP integration.
//

import CoreData
import Foundation
import ImpressAutomation
import OSLog

private let routerLogger = Logger(subsystem: "com.imbib.impart", category: "httpRouter")

// MARK: - HTTP Automation Router

/// Routes HTTP requests to appropriate handlers.
///
/// API Endpoints (GET):
/// - `GET /api/status` - Server health
/// - `GET /api/accounts` - List accounts
/// - `GET /api/mailboxes` - List mailboxes
/// - `GET /api/messages` - List messages in mailbox
/// - `GET /api/messages/{id}` - Get message detail
/// - `GET /api/research/conversations` - List research conversations
/// - `GET /api/research/conversations/{id}` - Get conversation with messages
/// - `GET /api/artifacts/{encodedUri}` - Resolve artifact reference
/// - `GET /api/provenance/trace/{messageId}` - Trace provenance chain
/// - `GET /api/logs` - Query in-app log entries
///
/// API Endpoints (POST):
/// - `POST /api/messages/send` - Send message
/// - `POST /api/research/conversations` - Create research conversation
/// - `POST /api/research/conversations/{id}/messages` - Add message to conversation
/// - `POST /api/research/conversations/{id}/branch` - Branch conversation from message
/// - `POST /api/research/conversations/{id}/artifacts` - Record artifact reference
/// - `POST /api/research/conversations/{id}/decisions` - Record decision
///
/// API Endpoints (PATCH):
/// - `PATCH /api/research/conversations/{id}` - Update conversation metadata
/// - `PATCH /api/research/conversations/{id}/archive` - Archive conversation
///
/// - `OPTIONS /*` - CORS preflight
public actor ImpartHTTPRouter: HTTPRouter {

    // MARK: - Dependencies

    private var artifactResolver: ArtifactResolver?
    private var provenanceService: ProvenanceService?
    private var researchRepository: ResearchConversationRepository?
    private var persistenceController: PersistenceController?
    private var syncService: SyncService?

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

    /// Configure all services for full API functionality.
    public func configureAll(
        persistenceController: PersistenceController,
        syncService: SyncService,
        researchRepository: ResearchConversationRepository,
        artifactResolver: ArtifactResolver,
        provenanceService: ProvenanceService
    ) {
        self.persistenceController = persistenceController
        self.syncService = syncService
        self.researchRepository = researchRepository
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

            if path == "/api/logs" {
                return await LogEndpointHandler.handle(request)
            }
        }

        // POST endpoints
        if request.method == "POST" {
            if path == "/api/messages/send" {
                return await handleSendMessage(request)
            }

            // Research conversation POST endpoints
            if path == "/api/research/conversations" {
                return await handleCreateResearchConversation(request)
            }

            // POST /api/research/conversations/{id}/messages
            if path.hasPrefix("/api/research/conversations/") && path.hasSuffix("/messages") {
                let segment = String(request.path.dropFirst("/api/research/conversations/".count).dropLast("/messages".count))
                guard let conversationId = UUID(uuidString: segment) else {
                    return .badRequest("Invalid conversation ID")
                }
                return await handleAddResearchMessage(conversationId: conversationId, request: request)
            }

            // POST /api/research/conversations/{id}/branch
            if path.hasPrefix("/api/research/conversations/") && path.hasSuffix("/branch") {
                let segment = String(request.path.dropFirst("/api/research/conversations/".count).dropLast("/branch".count))
                guard let conversationId = UUID(uuidString: segment) else {
                    return .badRequest("Invalid conversation ID")
                }
                return await handleBranchConversation(conversationId: conversationId, request: request)
            }

            // POST /api/research/conversations/{id}/artifacts
            if path.hasPrefix("/api/research/conversations/") && path.hasSuffix("/artifacts") {
                let segment = String(request.path.dropFirst("/api/research/conversations/".count).dropLast("/artifacts".count))
                guard let conversationId = UUID(uuidString: segment) else {
                    return .badRequest("Invalid conversation ID")
                }
                return await handleRecordArtifact(conversationId: conversationId, request: request)
            }

            // POST /api/research/conversations/{id}/decisions
            if path.hasPrefix("/api/research/conversations/") && path.hasSuffix("/decisions") {
                let segment = String(request.path.dropFirst("/api/research/conversations/".count).dropLast("/decisions".count))
                guard let conversationId = UUID(uuidString: segment) else {
                    return .badRequest("Invalid conversation ID")
                }
                return await handleRecordDecision(conversationId: conversationId, request: request)
            }
        }

        // PATCH endpoints
        if request.method == "PATCH" {
            // PATCH /api/research/conversations/{id}/archive
            if path.hasPrefix("/api/research/conversations/") && path.hasSuffix("/archive") {
                let segment = String(request.path.dropFirst("/api/research/conversations/".count).dropLast("/archive".count))
                guard let conversationId = UUID(uuidString: segment) else {
                    return .badRequest("Invalid conversation ID")
                }
                return await handleArchiveConversation(conversationId: conversationId)
            }

            // PATCH /api/research/conversations/{id}
            if path.hasPrefix("/api/research/conversations/") {
                let segment = String(request.path.dropFirst("/api/research/conversations/".count))
                guard let conversationId = UUID(uuidString: segment) else {
                    return .badRequest("Invalid conversation ID")
                }
                return await handleUpdateResearchConversation(conversationId: conversationId, request: request)
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
        var accountCount = 0

        if let persistence = persistenceController {
            do {
                accountCount = try await persistence.performBackgroundTask { context in
                    let request = CDAccount.fetchRequest()
                    return try context.count(for: request)
                }
            } catch {
                routerLogger.error("Failed to get account count: \(error.localizedDescription)")
            }
        }

        let response: [String: Any] = [
            "status": "ok",
            "app": "impart",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "port": ImpartHTTPServer.defaultPort,
            "accounts": accountCount
        ]

        return .json(response)
    }

    /// GET /api/accounts
    /// List all configured accounts.
    private func handleListAccounts() async -> HTTPResponse {
        guard let persistence = persistenceController else {
            return .json([
                "status": "error",
                "error": "Persistence not configured"
            ])
        }

        do {
            let accounts = try await persistence.performBackgroundTask { context -> [[String: Any]] in
                let request = CDAccount.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "email", ascending: true)]
                let results = try context.fetch(request)

                return results.map { account -> [String: Any] in
                    [
                        "id": account.id.uuidString,
                        "email": account.email,
                        "displayName": account.displayName,
                        "isEnabled": account.isEnabled,
                        "lastSyncDate": account.lastSyncDate.map { ISO8601DateFormatter().string(from: $0) } as Any
                    ]
                }
            }

            return .json([
                "status": "ok",
                "count": accounts.count,
                "accounts": accounts
            ])
        } catch {
            routerLogger.error("Failed to list accounts: \(error.localizedDescription)")
            return .json([
                "status": "error",
                "error": error.localizedDescription
            ])
        }
    }

    /// GET /api/mailboxes?account={id}
    /// List mailboxes for an account.
    private func handleListMailboxes(_ request: HTTPRequest) async -> HTTPResponse {
        guard let persistence = persistenceController else {
            return .json([
                "status": "error",
                "error": "Persistence not configured"
            ])
        }

        let accountIdString = request.queryParams["account"]

        do {
            let mailboxes = try await persistence.performBackgroundTask { context -> [[String: Any]] in
                let request = CDFolder.fetchRequest()

                if let accountIdStr = accountIdString,
                   let accountId = UUID(uuidString: accountIdStr) {
                    request.predicate = NSPredicate(format: "account.id == %@", accountId as CVarArg)
                }

                request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
                let results = try context.fetch(request)

                return results.map { folder -> [String: Any] in
                    [
                        "id": folder.id.uuidString,
                        "name": folder.name,
                        "fullPath": folder.fullPath,
                        "role": folder.roleRaw,
                        "messageCount": folder.messageCount,
                        "unreadCount": folder.unreadCount,
                        "accountId": folder.account?.id.uuidString ?? ""
                    ]
                }
            }

            return .json([
                "status": "ok",
                "count": mailboxes.count,
                "mailboxes": mailboxes
            ])
        } catch {
            routerLogger.error("Failed to list mailboxes: \(error.localizedDescription)")
            return .json([
                "status": "error",
                "error": error.localizedDescription
            ])
        }
    }

    /// GET /api/messages?mailbox={id}&limit={n}&offset={n}
    /// List messages in a mailbox.
    private func handleListMessages(_ request: HTTPRequest) async -> HTTPResponse {
        guard let persistence = persistenceController else {
            return .json([
                "status": "error",
                "error": "Persistence not configured"
            ])
        }

        let mailboxIdString = request.queryParams["mailbox"]
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 50
        let offset = request.queryParams["offset"].flatMap { Int($0) } ?? 0

        do {
            let messages = try await persistence.performBackgroundTask { context -> [[String: Any]] in
                let request = CDMessage.fetchRequest()

                if let mailboxIdStr = mailboxIdString,
                   let mailboxId = UUID(uuidString: mailboxIdStr) {
                    request.predicate = NSPredicate(format: "folder.id == %@", mailboxId as CVarArg)
                }

                request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                request.fetchLimit = limit
                request.fetchOffset = offset
                let results = try context.fetch(request)

                let formatter = ISO8601DateFormatter()
                return results.map { msg -> [String: Any] in
                    [
                        "id": msg.id.uuidString,
                        "uid": msg.uid,
                        "messageId": msg.messageId ?? "",
                        "subject": msg.subject,
                        "snippet": msg.snippet,
                        "from": msg.fromJSON,
                        "to": msg.toJSON,
                        "date": formatter.string(from: msg.date),
                        "isRead": msg.isRead,
                        "isStarred": msg.isStarred,
                        "hasAttachments": msg.hasAttachments,
                        "mailboxId": msg.folder?.id.uuidString ?? ""
                    ]
                }
            }

            return .json([
                "status": "ok",
                "count": messages.count,
                "messages": messages,
                "query": [
                    "mailbox": mailboxIdString as Any,
                    "limit": limit,
                    "offset": offset
                ] as [String: Any]
            ])
        } catch {
            routerLogger.error("Failed to list messages: \(error.localizedDescription)")
            return .json([
                "status": "error",
                "error": error.localizedDescription
            ])
        }
    }

    /// GET /api/messages/{id}
    /// Get message detail.
    private func handleGetMessage(id: String) async -> HTTPResponse {
        guard let messageId = UUID(uuidString: id) else {
            return .badRequest("Invalid message ID format")
        }

        guard let persistence = persistenceController else {
            return .json([
                "status": "error",
                "error": "Persistence not configured"
            ])
        }

        do {
            let messageData = try await persistence.performBackgroundTask { context -> [String: Any]? in
                let request = CDMessage.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
                request.fetchLimit = 1

                guard let msg = try context.fetch(request).first else {
                    return nil
                }

                let formatter = ISO8601DateFormatter()

                var result: [String: Any] = [
                    "id": msg.id.uuidString,
                    "uid": msg.uid,
                    "messageId": msg.messageId ?? "",
                    "inReplyTo": msg.inReplyTo ?? "",
                    "references": msg.referencesJSON ?? "[]",
                    "subject": msg.subject,
                    "snippet": msg.snippet,
                    "from": msg.fromJSON,
                    "to": msg.toJSON,
                    "cc": msg.ccJSON ?? "[]",
                    "bcc": msg.bccJSON ?? "[]",
                    "date": formatter.string(from: msg.date),
                    "receivedDate": formatter.string(from: msg.receivedDate),
                    "isRead": msg.isRead,
                    "isStarred": msg.isStarred,
                    "hasAttachments": msg.hasAttachments,
                    "mailboxId": msg.folder?.id.uuidString ?? "",
                    "mailboxName": msg.folder?.name ?? ""
                ]

                // Include body content if available
                if let content = msg.content {
                    result["textBody"] = content.textBody ?? ""
                    result["htmlBody"] = content.htmlBody ?? ""

                    // Include attachment info
                    if let attachments = content.attachments {
                        result["attachments"] = attachments.map { att -> [String: Any] in
                            [
                                "id": att.id.uuidString,
                                "filename": att.filename,
                                "mimeType": att.mimeType,
                                "size": att.size,
                                "isInline": att.isInline
                            ]
                        }
                    }
                }

                return result
            }

            guard let message = messageData else {
                return .notFound("Message not found: \(id)")
            }

            return .json([
                "status": "ok",
                "message": message
            ])
        } catch {
            routerLogger.error("Failed to get message: \(error.localizedDescription)")
            return .json([
                "status": "error",
                "error": error.localizedDescription
            ])
        }
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

        guard let accountIdStr = json["accountId"] as? String,
              let accountId = UUID(uuidString: accountIdStr) else {
            return .badRequest("Missing or invalid 'accountId' parameter")
        }

        guard let toStrings = json["to"] as? [String], !toStrings.isEmpty else {
            return .badRequest("Missing 'to' recipients")
        }

        guard let persistence = persistenceController, let sync = syncService else {
            return .json([
                "status": "error",
                "error": "Services not configured"
            ])
        }

        do {
            // Fetch account from Core Data
            let account = try await persistence.performBackgroundTask { context -> Account? in
                let request = CDAccount.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", accountId as CVarArg)
                request.fetchLimit = 1

                guard let cdAccount = try context.fetch(request).first else {
                    return nil
                }

                return Account(
                    id: cdAccount.id,
                    email: cdAccount.email,
                    displayName: cdAccount.displayName,
                    imapSettings: IMAPSettings(
                        host: cdAccount.imapHost,
                        port: UInt16(cdAccount.imapPort),
                        security: .tls,
                        username: cdAccount.email
                    ),
                    smtpSettings: SMTPSettings(
                        host: cdAccount.smtpHost,
                        port: UInt16(cdAccount.smtpPort),
                        security: .starttls,
                        username: cdAccount.email
                    )
                )
            }

            guard let account = account else {
                return .notFound("Account not found: \(accountIdStr)")
            }

            // Build the draft
            let to = toStrings.map { EmailAddress(email: $0) }
            let cc = (json["cc"] as? [String])?.map { EmailAddress(email: $0) } ?? []
            let bcc = (json["bcc"] as? [String])?.map { EmailAddress(email: $0) } ?? []
            let subject = json["subject"] as? String ?? ""
            let bodyText = json["body"] as? String ?? ""

            let draft = DraftMessage(
                accountId: account.id,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: bodyText,
                isHTML: false
            )

            // Send via sync service
            try await sync.send(draft, from: account)

            return .json([
                "status": "ok",
                "message": "Message sent successfully",
                "subject": subject,
                "to": toStrings
            ])
        } catch {
            routerLogger.error("Failed to send message: \(error.localizedDescription)")
            return .json([
                "status": "error",
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: - Research Conversation Handlers

    /// GET /api/research/conversations
    /// List all research conversations.
    private func handleListResearchConversations(_ request: HTTPRequest) async -> HTTPResponse {
        guard let repository = researchRepository else {
            return .json([
                "status": "error",
                "error": "Research repository not configured"
            ])
        }

        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 50
        let offset = request.queryParams["offset"].flatMap { Int($0) } ?? 0
        let includeArchived = request.queryParams["includeArchived"] == "true"

        do {
            let allConversations = try await repository.fetchConversations(includeArchived: includeArchived)

            // Apply pagination
            let paginatedConversations = Array(allConversations.dropFirst(offset).prefix(limit))
            let formatter = ISO8601DateFormatter()

            let conversationsData = paginatedConversations.map { conv -> [String: Any] in
                [
                    "id": conv.id.uuidString,
                    "title": conv.title,
                    "participants": conv.participants,
                    "createdAt": formatter.string(from: conv.createdAt),
                    "lastActivityAt": formatter.string(from: conv.lastActivityAt),
                    "summaryText": conv.summaryText ?? "",
                    "isArchived": conv.isArchived,
                    "tags": conv.tags,
                    "parentConversationId": conv.parentConversationId?.uuidString as Any
                ]
            }

            return .json([
                "status": "ok",
                "count": conversationsData.count,
                "total": allConversations.count,
                "conversations": conversationsData,
                "query": [
                    "limit": limit,
                    "offset": offset,
                    "includeArchived": includeArchived
                ] as [String: Any]
            ])
        } catch {
            routerLogger.error("Failed to list research conversations: \(error.localizedDescription)")
            return .json([
                "status": "error",
                "error": error.localizedDescription
            ])
        }
    }

    /// GET /api/research/conversations/{id}
    /// Get a research conversation with messages.
    private func handleGetResearchConversation(id: String) async -> HTTPResponse {
        guard let conversationId = UUID(uuidString: id) else {
            return .badRequest("Invalid conversation ID format")
        }

        guard let repository = researchRepository else {
            return .json([
                "status": "error",
                "error": "Research repository not configured"
            ])
        }

        do {
            guard let conversation = try await repository.fetchConversation(id: conversationId) else {
                return .notFound("Research conversation not found: \(id)")
            }

            let messages = try await repository.fetchMessages(for: conversationId)
            let stats = try await repository.getStatistics(for: conversationId)

            let formatter = ISO8601DateFormatter()

            let conversationData: [String: Any] = [
                "id": conversation.id.uuidString,
                "title": conversation.title,
                "participants": conversation.participants,
                "createdAt": formatter.string(from: conversation.createdAt),
                "lastActivityAt": formatter.string(from: conversation.lastActivityAt),
                "summaryText": conversation.summaryText ?? "",
                "isArchived": conversation.isArchived,
                "tags": conversation.tags,
                "parentConversationId": conversation.parentConversationId?.uuidString as Any
            ]

            let messagesData = messages.map { msg -> [String: Any] in
                [
                    "id": msg.id.uuidString,
                    "sequence": msg.sequence,
                    "senderRole": msg.senderRole.rawValue,
                    "senderId": msg.senderId,
                    "modelUsed": msg.modelUsed as Any,
                    "contentMarkdown": msg.contentMarkdown,
                    "sentAt": formatter.string(from: msg.sentAt),
                    "tokenCount": msg.tokenCount as Any,
                    "processingDurationMs": msg.processingDurationMs as Any,
                    "mentionedArtifactURIs": msg.mentionedArtifactURIs
                ]
            }

            var statsData: [String: Any] = [:]
            if let s = stats {
                statsData = [
                    "messageCount": s.messageCount,
                    "humanMessageCount": s.humanMessageCount,
                    "counselMessageCount": s.counselMessageCount,
                    "artifactCount": s.artifactCount,
                    "paperCount": s.paperCount,
                    "repositoryCount": s.repositoryCount,
                    "totalTokens": s.totalTokens,
                    "duration": s.duration,
                    "branchCount": s.branchCount
                ]
            }

            return .json([
                "status": "ok",
                "conversation": conversationData,
                "messages": messagesData,
                "statistics": statsData
            ])
        } catch {
            routerLogger.error("Failed to get research conversation: \(error.localizedDescription)")
            return .json([
                "status": "error",
                "error": error.localizedDescription
            ])
        }
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

    // MARK: - Research Conversation Write Handlers

    /// POST /api/research/conversations
    /// Create a new research conversation.
    private func handleCreateResearchConversation(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let title = json["title"] as? String, !title.isEmpty else {
            return .badRequest("Missing 'title' field")
        }

        let participants = json["participants"] as? [String] ?? []
        let conversationId = UUID()

        // Queue the operation for UI synchronization
        await MainActor.run {
            ConversationRegistry.shared.queueOperation(
                .create(title: title, participants: participants),
                for: conversationId
            )
        }

        routerLogger.info("Queued create conversation: \(conversationId)")

        return .json([
            "status": "ok",
            "conversationId": conversationId.uuidString,
            "title": title,
            "participants": participants,
            "message": "Conversation creation queued"
        ], status: 201)
    }

    /// POST /api/research/conversations/{id}/messages
    /// Add a message to a research conversation.
    private func handleAddResearchMessage(conversationId: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let senderRole = json["senderRole"] as? String,
              ["human", "counsel", "system"].contains(senderRole) else {
            return .badRequest("Missing or invalid 'senderRole' field (human, counsel, system)")
        }

        guard let senderId = json["senderId"] as? String, !senderId.isEmpty else {
            return .badRequest("Missing 'senderId' field")
        }

        guard let content = json["content"] as? String, !content.isEmpty else {
            return .badRequest("Missing 'content' field")
        }

        let causationId = (json["causationId"] as? String).flatMap { UUID(uuidString: $0) }

        // Queue the operation for UI synchronization
        await MainActor.run {
            ConversationRegistry.shared.queueOperation(
                .addMessage(senderRole: senderRole, senderId: senderId, content: content, causationId: causationId),
                for: conversationId
            )
        }

        routerLogger.info("Queued add message to conversation: \(conversationId)")

        return .json([
            "status": "ok",
            "conversationId": conversationId.uuidString,
            "senderRole": senderRole,
            "senderId": senderId,
            "message": "Message addition queued"
        ], status: 201)
    }

    /// POST /api/research/conversations/{id}/branch
    /// Branch a conversation from a specific message.
    private func handleBranchConversation(conversationId: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let messageIdStr = json["fromMessageId"] as? String,
              let fromMessageId = UUID(uuidString: messageIdStr) else {
            return .badRequest("Missing or invalid 'fromMessageId' field")
        }

        guard let title = json["title"] as? String, !title.isEmpty else {
            return .badRequest("Missing 'title' field")
        }

        // Queue the operation for UI synchronization
        await MainActor.run {
            ConversationRegistry.shared.queueOperation(
                .branch(fromMessageId: fromMessageId, title: title),
                for: conversationId
            )
        }

        routerLogger.info("Queued branch conversation: \(conversationId) from message: \(fromMessageId)")

        return .json([
            "status": "ok",
            "conversationId": conversationId.uuidString,
            "fromMessageId": fromMessageId.uuidString,
            "title": title,
            "message": "Branch operation queued"
        ], status: 201)
    }

    /// PATCH /api/research/conversations/{id}
    /// Update conversation metadata.
    private func handleUpdateResearchConversation(conversationId: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        let title = json["title"] as? String
        let summary = json["summary"] as? String
        let tags = json["tags"] as? [String]

        if title == nil && summary == nil && tags == nil {
            return .badRequest("At least one of 'title', 'summary', or 'tags' must be provided")
        }

        // Queue the operation for UI synchronization
        await MainActor.run {
            ConversationRegistry.shared.queueOperation(
                .update(title: title, summary: summary, tags: tags),
                for: conversationId
            )
        }

        routerLogger.info("Queued update conversation: \(conversationId)")

        return .json([
            "status": "ok",
            "conversationId": conversationId.uuidString,
            "message": "Update operation queued"
        ])
    }

    /// PATCH /api/research/conversations/{id}/archive
    /// Archive a conversation.
    private func handleArchiveConversation(conversationId: UUID) async -> HTTPResponse {
        // Queue the operation for UI synchronization
        await MainActor.run {
            ConversationRegistry.shared.queueOperation(
                .archive,
                for: conversationId
            )
        }

        routerLogger.info("Queued archive conversation: \(conversationId)")

        return .json([
            "status": "ok",
            "conversationId": conversationId.uuidString,
            "message": "Archive operation queued"
        ])
    }

    /// POST /api/research/conversations/{id}/artifacts
    /// Record an artifact reference.
    private func handleRecordArtifact(conversationId: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let uri = json["uri"] as? String, !uri.isEmpty else {
            return .badRequest("Missing 'uri' field")
        }

        guard let type = json["type"] as? String, !type.isEmpty else {
            return .badRequest("Missing 'type' field")
        }

        let displayName = json["displayName"] as? String

        // Queue the operation for UI synchronization
        await MainActor.run {
            ConversationRegistry.shared.queueOperation(
                .recordArtifact(uri: uri, type: type, displayName: displayName),
                for: conversationId
            )
        }

        routerLogger.info("Queued record artifact for conversation: \(conversationId), uri: \(uri)")

        return .json([
            "status": "ok",
            "conversationId": conversationId.uuidString,
            "uri": uri,
            "type": type,
            "message": "Artifact recording queued"
        ], status: 201)
    }

    /// POST /api/research/conversations/{id}/decisions
    /// Record a decision.
    private func handleRecordDecision(conversationId: UUID, request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .badRequest("Invalid JSON body")
        }

        guard let description = json["description"] as? String, !description.isEmpty else {
            return .badRequest("Missing 'description' field")
        }

        guard let rationale = json["rationale"] as? String, !rationale.isEmpty else {
            return .badRequest("Missing 'rationale' field")
        }

        // Queue the operation for UI synchronization
        await MainActor.run {
            ConversationRegistry.shared.queueOperation(
                .recordDecision(description: description, rationale: rationale),
                for: conversationId
            )
        }

        routerLogger.info("Queued record decision for conversation: \(conversationId)")

        return .json([
            "status": "ok",
            "conversationId": conversationId.uuidString,
            "description": description,
            "message": "Decision recording queued"
        ], status: 201)
    }

    // MARK: - Helpers

    /// CORS preflight response.
    private func handleCORSPreflight() -> HTTPResponse {
        HTTPResponse(
            status: 204,
            statusText: "No Content",
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, PATCH, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400"
            ]
        )
    }

    /// Root API info response.
    private func handleAPIInfo() -> HTTPResponse {
        let info: [String: Any] = [
            "name": "impart HTTP API",
            "version": "2.0.0",
            "endpoints": [
                // GET endpoints
                "GET /api/status": "Server health and info",
                "GET /api/accounts": "List configured accounts",
                "GET /api/mailboxes?account={id}": "List mailboxes for account",
                "GET /api/messages?mailbox={id}&limit={n}&offset={n}": "List messages in mailbox",
                "GET /api/messages/{id}": "Get message detail",
                "GET /api/research/conversations": "List research conversations (params: limit, offset, includeArchived)",
                "GET /api/research/conversations/{id}": "Get conversation with messages and statistics",
                "GET /api/artifacts/{encodedUri}": "Resolve artifact reference",
                "GET /api/provenance/trace/{eventId}": "Trace provenance chain",
                "GET /api/logs?limit=&level=&category=&search=&after=": "Query in-app log entries",
                // POST endpoints
                "POST /api/messages/send": "Send message (body: {accountId, to, cc?, bcc?, subject, body})",
                "POST /api/research/conversations": "Create conversation (body: {title, participants?})",
                "POST /api/research/conversations/{id}/messages": "Add message (body: {senderRole, senderId, content, causationId?})",
                "POST /api/research/conversations/{id}/branch": "Branch conversation (body: {fromMessageId, title})",
                "POST /api/research/conversations/{id}/artifacts": "Record artifact (body: {uri, type, displayName?})",
                "POST /api/research/conversations/{id}/decisions": "Record decision (body: {description, rationale})",
                // PATCH endpoints
                "PATCH /api/research/conversations/{id}": "Update conversation (body: {title?, summary?, tags?})",
                "PATCH /api/research/conversations/{id}/archive": "Archive conversation"
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
