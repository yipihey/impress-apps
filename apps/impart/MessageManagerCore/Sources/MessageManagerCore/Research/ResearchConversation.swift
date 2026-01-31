//
//  ResearchConversation.swift
//  MessageManagerCore
//
//  Research conversation DTO for structured dialogues with AI counsels.
//  Supports full provenance tracking and branching for side conversations.
//

import Foundation

// MARK: - Research Conversation

/// A research conversation with AI counsels.
/// Tracks all messages, artifacts, and provenance for reproducibility.
public struct ResearchConversation: Identifiable, Codable, Sendable, Equatable {
    /// Unique identifier
    public let id: UUID

    /// Title of the conversation
    public var title: String

    /// Participant identifiers (user and agent addresses)
    public var participants: [String]

    /// When the conversation was created
    public let createdAt: Date

    /// Last activity timestamp
    public var lastActivityAt: Date

    /// AI-generated summary
    public var summaryText: String?

    /// Whether the conversation is archived
    public var isArchived: Bool

    /// Tags for organization
    public var tags: [String]

    /// Parent conversation ID if this is a branch
    public var parentConversationId: UUID?

    /// Message count (for display without loading all messages)
    public var messageCount: Int

    /// Latest message snippet for preview
    public var latestSnippet: String?

    /// Initialize a new research conversation.
    public init(
        id: UUID = UUID(),
        title: String,
        participants: [String],
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        summaryText: String? = nil,
        isArchived: Bool = false,
        tags: [String] = [],
        parentConversationId: UUID? = nil,
        messageCount: Int = 0,
        latestSnippet: String? = nil
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.summaryText = summaryText
        self.isArchived = isArchived
        self.tags = tags
        self.parentConversationId = parentConversationId
        self.messageCount = messageCount
        self.latestSnippet = latestSnippet
    }

    /// Whether this is a side/branch conversation.
    public var isSideConversation: Bool {
        parentConversationId != nil
    }

    /// Get participant display names (simplified).
    public var participantDisplayNames: [String] {
        participants.map { participant in
            // Extract display name from agent address or email
            if participant.contains("@impart") {
                // Agent address: counsel-opus4.5@impart.local -> Counsel (Opus 4.5)
                let parts = participant.split(separator: "@")[0].split(separator: "-")
                if parts.count >= 2 {
                    let type = parts[0].capitalized
                    let model = parts[1...].joined(separator: " ").capitalized
                    return "\(type) (\(model))"
                }
                return String(participant.split(separator: "@")[0]).capitalized
            } else {
                // Email address: use local part or full address
                return String(participant.split(separator: "@")[0])
            }
        }
    }
}

// MARK: - Conversation Builder

/// Builder for creating research conversations with fluent API.
public struct ResearchConversationBuilder {
    private var conversation: ResearchConversation

    /// Start building a conversation with a title.
    public init(title: String) {
        self.conversation = ResearchConversation(
            title: title,
            participants: []
        )
    }

    /// Add a participant.
    public func with(participant: String) -> ResearchConversationBuilder {
        var builder = self
        builder.conversation.participants.append(participant)
        return builder
    }

    /// Add multiple participants.
    public func with(participants: [String]) -> ResearchConversationBuilder {
        var builder = self
        builder.conversation.participants.append(contentsOf: participants)
        return builder
    }

    /// Add a human participant.
    public func withHuman(email: String) -> ResearchConversationBuilder {
        with(participant: email)
    }

    /// Add a counsel agent participant.
    public func withCounsel(model: String) -> ResearchConversationBuilder {
        with(participant: "counsel-\(model)@impart.local")
    }

    /// Set tags.
    public func tagged(_ tags: [String]) -> ResearchConversationBuilder {
        var builder = self
        builder.conversation.tags = tags
        return builder
    }

    /// Set as a branch of another conversation.
    public func asBranch(of parentId: UUID) -> ResearchConversationBuilder {
        var builder = self
        builder.conversation.parentConversationId = parentId
        return builder
    }

    /// Build the conversation.
    public func build() -> ResearchConversation {
        conversation
    }
}

// MARK: - Conversation Query

/// Query parameters for fetching research conversations.
public struct ResearchConversationQuery: Sendable {
    /// Filter by participant
    public var participant: String?

    /// Filter by tag
    public var tag: String?

    /// Filter by archived status
    public var includeArchived: Bool

    /// Filter to only root conversations (not branches)
    public var rootOnly: Bool

    /// Search text (matches title and summary)
    public var searchText: String?

    /// Sort order
    public var sortBy: SortField

    /// Sort direction
    public var ascending: Bool

    /// Maximum results
    public var limit: Int?

    /// Offset for pagination
    public var offset: Int?

    public enum SortField: String, Sendable {
        case lastActivityAt
        case createdAt
        case title
        case messageCount
    }

    public init(
        participant: String? = nil,
        tag: String? = nil,
        includeArchived: Bool = false,
        rootOnly: Bool = false,
        searchText: String? = nil,
        sortBy: SortField = .lastActivityAt,
        ascending: Bool = false,
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.participant = participant
        self.tag = tag
        self.includeArchived = includeArchived
        self.rootOnly = rootOnly
        self.searchText = searchText
        self.sortBy = sortBy
        self.ascending = ascending
        self.limit = limit
        self.offset = offset
    }

    /// Default query showing recent active conversations.
    public static var recent: ResearchConversationQuery {
        ResearchConversationQuery(
            includeArchived: false,
            rootOnly: true,
            sortBy: .lastActivityAt,
            ascending: false,
            limit: 50
        )
    }

    /// Query for all conversations with a specific participant.
    public static func withParticipant(_ participant: String) -> ResearchConversationQuery {
        ResearchConversationQuery(
            participant: participant,
            includeArchived: false,
            sortBy: .lastActivityAt,
            ascending: false
        )
    }
}

// MARK: - Conversation Summary

/// Summary statistics for a research conversation.
public struct ResearchConversationSummary: Codable, Sendable {
    /// Total message count
    public let messageCount: Int

    /// Messages from humans
    public let humanMessageCount: Int

    /// Messages from counsels
    public let counselMessageCount: Int

    /// Unique artifacts referenced
    public let artifactCount: Int

    /// Papers referenced
    public let paperCount: Int

    /// Repositories referenced
    public let repositoryCount: Int

    /// Total tokens used by AI
    public let totalTokens: Int

    /// Duration from first to last message
    public let duration: TimeInterval

    /// Branch/side conversation count
    public let branchCount: Int

    public init(
        messageCount: Int,
        humanMessageCount: Int,
        counselMessageCount: Int,
        artifactCount: Int,
        paperCount: Int,
        repositoryCount: Int,
        totalTokens: Int,
        duration: TimeInterval,
        branchCount: Int
    ) {
        self.messageCount = messageCount
        self.humanMessageCount = humanMessageCount
        self.counselMessageCount = counselMessageCount
        self.artifactCount = artifactCount
        self.paperCount = paperCount
        self.repositoryCount = repositoryCount
        self.totalTokens = totalTokens
        self.duration = duration
        self.branchCount = branchCount
    }
}
