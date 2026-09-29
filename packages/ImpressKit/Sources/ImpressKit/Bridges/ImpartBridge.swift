import Foundation

/// Typed bridge for communicating with impart (messaging) via canonical verbs.
public struct ImpartBridge: Sendable {

    /// List research conversations and preserve the generated page metadata.
    public static func listConversations(limit: Int = 20) async throws -> ConversationListInfo {
        let page: VerbConversationList = try await SiblingBridge.shared.callVerb(
            "impart-service_list-conversations",
            on: .impart,
            arguments: [
                "limit": min(max(limit, 0), Int(UInt32.max)),
                "include_archived": false,
                "offset": 0,
                "query": NSNull(),
            ]
        )
        return ConversationListInfo(page: page)
    }

    /// Get one conversation, including ordered messages and computed statistics.
    public static func getConversation(id: String) async throws -> ConversationDetailInfo? {
        let record: VerbConversationRecord? = try await SiblingBridge.shared.callVerb(
            "impart-service_get-conversation", on: .impart,
            arguments: ["conversation_id": id])
        return record.map(ConversationDetailInfo.init(record:))
    }

    /// List messages in a mailbox.
    public static func listMessages(mailbox: String? = nil, limit: Int = 50) async throws -> [MessageInfo] {
        var query: [String: String] = ["limit": String(limit)]
        if let mailbox { query["mailbox"] = mailbox }
        return try await SiblingBridge.shared.get("/api/messages", from: .impart, query: query)
    }

    /// Check if impart's HTTP API is available.
    public static func isAvailable() async -> Bool {
        await SiblingBridge.shared.isAvailable(.impart)
    }
}

struct VerbConversationList: Decodable, Sendable {
    let conversations: [VerbConversationRecord]
    let count: Int
    let total: Int
    let offset: Int
    let limit: Int
    let includeArchived: Bool
    let query: String?

    enum CodingKeys: String, CodingKey {
        case conversations, count, total, offset, limit, query
        case includeArchived = "include_archived"
    }
}

struct VerbConversationRecord: Decodable, Sendable {
    let id: String
    let title: String
    let summary: String?
    let messageCount: Int?
    let createdAt: String?
    let updatedAt: String?
    let archived: Bool?
    let participants: [String]
    let tags: [String]
    let parentConversationId: String?
    let lastActivityAt: String?
    let summaryText: String
    let messages: [VerbConversationMessage]?
    let statistics: VerbConversationStatistics?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, participants, tags, messages, statistics
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archived
        case parentConversationId = "parent_conversation_id"
        case lastActivityAt = "last_activity_at"
        case summaryText = "summary_text"
    }
}

struct VerbConversationMessage: Decodable, Sendable {
    let id: String
    let sequence: Int
    let senderRole: String
    let senderId: String
    let modelUsed: String?
    let contentMarkdown: String
    let sentAt: String
    let tokenCount: Int?
    let processingDurationMs: Int?
    let mentionedArtifactUris: [String]

    enum CodingKeys: String, CodingKey {
        case id, sequence, contentMarkdown = "content_markdown", sentAt = "sent_at"
        case senderRole = "sender_role"
        case senderId = "sender_id"
        case modelUsed = "model_used"
        case tokenCount = "token_count"
        case processingDurationMs = "processing_duration_ms"
        case mentionedArtifactUris = "mentioned_artifact_uris"
    }
}

struct VerbConversationStatistics: Decodable, Sendable {
    let messageCount: Int
    let humanMessageCount: Int
    let counselMessageCount: Int
    let artifactCount: Int
    let paperCount: Int
    let repositoryCount: Int
    let totalTokens: Int
    let duration: Double
    let branchCount: Int

    enum CodingKeys: String, CodingKey {
        case duration
        case messageCount = "message_count"
        case humanMessageCount = "human_message_count"
        case counselMessageCount = "counsel_message_count"
        case artifactCount = "artifact_count"
        case paperCount = "paper_count"
        case repositoryCount = "repository_count"
        case totalTokens = "total_tokens"
        case branchCount = "branch_count"
    }
}

// MARK: - Result Types

/// Conversation summary in the bridge's stable public shape.
public struct ConversationInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let subject: String?
    public let participants: [String]?
    public let messageCount: Int?
    public let lastActivity: Date?
    public let summary: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let isArchived: Bool?
    public let tags: [String]?
    public let parentConversationId: String?
    public let summaryText: String?

    enum CodingKeys: String, CodingKey {
        case id, participants, messageCount, summary, createdAt, updatedAt, isArchived, tags
        case subject = "title"
        case lastActivity = "lastActivityAt"
        case parentConversationId, summaryText
    }
}

/// Conversation list plus the pagination/filter values needed to interpret it.
public struct ConversationListInfo: Codable, Sendable {
    public let status: String
    public let conversations: [ConversationInfo]
    public let count: Int
    public let total: Int
    public let offset: Int
    public let limit: Int
    public let includeArchived: Bool
    public let query: String?

    init(page: VerbConversationList) {
        self.status = "ok"
        self.conversations = page.conversations.map(ConversationInfo.init(record:))
        self.count = page.count
        self.total = page.total
        self.offset = page.offset
        self.limit = page.limit
        self.includeArchived = page.includeArchived
        self.query = page.query
    }
}

/// Full conversation detail in the current HTTP result envelope's conceptual shape.
public struct ConversationDetailInfo: Codable, Sendable {
    public let status: String
    public let conversation: ConversationInfo
    public let messages: [ConversationMessageInfo]
    public let statistics: ConversationStatisticsInfo?

    init(record: VerbConversationRecord) {
        self.status = "ok"
        self.conversation = ConversationInfo(record: record)
        self.messages = (record.messages ?? []).map(ConversationMessageInfo.init(record:))
        self.statistics = record.statistics.map(ConversationStatisticsInfo.init(record:))
    }
}

public struct ConversationMessageInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let sequence: Int
    public let senderRole: String
    public let senderId: String
    public let modelUsed: String?
    public let contentMarkdown: String
    public let sentAt: Date?
    public let tokenCount: Int?
    public let processingDurationMs: Int?
    public let mentionedArtifactUris: [String]

    enum CodingKeys: String, CodingKey {
        case id, sequence, senderRole, senderId, modelUsed, contentMarkdown, sentAt, tokenCount
        case processingDurationMs
        case mentionedArtifactUris = "mentionedArtifactURIs"
    }
}

public struct ConversationStatisticsInfo: Codable, Sendable {
    public let messageCount: Int
    public let humanMessageCount: Int
    public let counselMessageCount: Int
    public let artifactCount: Int
    public let paperCount: Int
    public let repositoryCount: Int
    public let totalTokens: Int
    public let duration: Double
    public let branchCount: Int
}

extension ConversationInfo {
    init(record: VerbConversationRecord) {
        self.init(
            id: record.id,
            subject: record.title,
            participants: record.participants,
            messageCount: record.messageCount,
            lastActivity: BridgeDate.parse(record.lastActivityAt),
            summary: record.summary,
            createdAt: BridgeDate.parse(record.createdAt),
            updatedAt: BridgeDate.parse(record.updatedAt),
            isArchived: record.archived,
            tags: record.tags,
            parentConversationId: record.parentConversationId,
            summaryText: record.summaryText
        )
    }
}

extension ConversationMessageInfo {
    init(record: VerbConversationMessage) {
        self.init(
            id: record.id,
            sequence: record.sequence,
            senderRole: record.senderRole,
            senderId: record.senderId,
            modelUsed: record.modelUsed,
            contentMarkdown: record.contentMarkdown,
            sentAt: BridgeDate.parse(record.sentAt),
            tokenCount: record.tokenCount,
            processingDurationMs: record.processingDurationMs,
            mentionedArtifactUris: record.mentionedArtifactUris
        )
    }
}

extension ConversationStatisticsInfo {
    init(record: VerbConversationStatistics) {
        self.init(
            messageCount: record.messageCount,
            humanMessageCount: record.humanMessageCount,
            counselMessageCount: record.counselMessageCount,
            artifactCount: record.artifactCount,
            paperCount: record.paperCount,
            repositoryCount: record.repositoryCount,
            totalTokens: record.totalTokens,
            duration: record.duration,
            branchCount: record.branchCount
        )
    }
}

/// Basic message information from impart.
public struct MessageInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let subject: String?
    public let sender: String?
    public let date: Date?
    public let isRead: Bool?
}
