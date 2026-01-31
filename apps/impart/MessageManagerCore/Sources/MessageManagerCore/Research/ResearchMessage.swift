//
//  ResearchMessage.swift
//  MessageManagerCore
//
//  Research message DTO for individual messages in research conversations.
//  Supports provenance tracking, AI model attribution, and side conversation synthesis.
//

import Foundation

// MARK: - Research Message

/// A message in a research conversation.
public struct ResearchMessage: Identifiable, Codable, Sendable, Equatable {
    /// Unique identifier
    public let id: UUID

    /// Conversation this message belongs to
    public let conversationId: UUID

    /// Sequence number for ordering within conversation
    public let sequence: Int

    /// Role of the sender
    public let senderRole: ResearchSenderRole

    /// Sender identifier
    public let senderId: String

    /// AI model used (if counsel message)
    public let modelUsed: String?

    /// Message content in Markdown
    public var contentMarkdown: String

    /// When the message was sent
    public let sentAt: Date

    /// Correlation ID for provenance tracking
    public let correlationId: String?

    /// ID of message that caused this response
    public let causationId: UUID?

    /// Whether this is a synthesis of a side conversation
    public let isSideConversationSynthesis: Bool

    /// Side conversation ID if this synthesizes one
    public let sideConversationId: UUID?

    /// Token count (for AI messages)
    public let tokenCount: Int?

    /// Processing duration in ms (for AI messages)
    public let processingDurationMs: Int?

    /// URIs of artifacts mentioned in this message
    public var mentionedArtifactURIs: [String]

    /// Initialize a new research message.
    public init(
        id: UUID = UUID(),
        conversationId: UUID,
        sequence: Int,
        senderRole: ResearchSenderRole,
        senderId: String,
        modelUsed: String? = nil,
        contentMarkdown: String,
        sentAt: Date = Date(),
        correlationId: String? = nil,
        causationId: UUID? = nil,
        isSideConversationSynthesis: Bool = false,
        sideConversationId: UUID? = nil,
        tokenCount: Int? = nil,
        processingDurationMs: Int? = nil,
        mentionedArtifactURIs: [String] = []
    ) {
        self.id = id
        self.conversationId = conversationId
        self.sequence = sequence
        self.senderRole = senderRole
        self.senderId = senderId
        self.modelUsed = modelUsed
        self.contentMarkdown = contentMarkdown
        self.sentAt = sentAt
        self.correlationId = correlationId
        self.causationId = causationId
        self.isSideConversationSynthesis = isSideConversationSynthesis
        self.sideConversationId = sideConversationId
        self.tokenCount = tokenCount
        self.processingDurationMs = processingDurationMs
        self.mentionedArtifactURIs = mentionedArtifactURIs
    }

    /// Whether this message is from a human.
    public var isFromHuman: Bool {
        senderRole == .human
    }

    /// Whether this message is from an AI counsel.
    public var isFromCounsel: Bool {
        senderRole == .counsel
    }

    /// Whether this message is a system message.
    public var isSystemMessage: Bool {
        senderRole == .system
    }

    /// Whether this message has a side conversation that can be expanded.
    public var hasSideConversation: Bool {
        sideConversationId != nil
    }

    /// Get a preview snippet.
    public var snippet: String {
        String(contentMarkdown.prefix(200))
    }

    /// Display name for the sender.
    public var senderDisplayName: String {
        switch senderRole {
        case .human:
            // Extract name from email if present
            if senderId.contains("@") {
                return String(senderId.split(separator: "@")[0])
            }
            return senderId

        case .counsel:
            // Parse agent address
            if senderId.contains("@") {
                let local = String(senderId.split(separator: "@")[0])
                let parts = local.split(separator: "-")
                if parts.count >= 2 {
                    return "\(parts[0].capitalized) (\(parts[1...].joined(separator: " ")))"
                }
                return local.capitalized
            }
            return "Counsel"

        case .system:
            return "System"
        }
    }

    /// Icon name for the sender role.
    public var senderIconName: String {
        switch senderRole {
        case .human: return "person.circle"
        case .counsel: return "brain.head.profile"
        case .system: return "gear"
        }
    }
}

// MARK: - Message Builder

/// Builder for creating research messages with fluent API.
public struct ResearchMessageBuilder {
    private var message: ResearchMessage

    /// Start building a message in a conversation.
    public init(conversationId: UUID, sequence: Int) {
        self.message = ResearchMessage(
            conversationId: conversationId,
            sequence: sequence,
            senderRole: .human,
            senderId: "",
            contentMarkdown: ""
        )
    }

    /// Set as human message.
    public func fromHuman(email: String) -> ResearchMessageBuilder {
        var builder = self
        builder.message = ResearchMessage(
            id: message.id,
            conversationId: message.conversationId,
            sequence: message.sequence,
            senderRole: .human,
            senderId: email,
            contentMarkdown: message.contentMarkdown,
            sentAt: message.sentAt,
            correlationId: message.correlationId,
            causationId: message.causationId
        )
        return builder
    }

    /// Set as counsel message.
    public func fromCounsel(model: String) -> ResearchMessageBuilder {
        var builder = self
        builder.message = ResearchMessage(
            id: message.id,
            conversationId: message.conversationId,
            sequence: message.sequence,
            senderRole: .counsel,
            senderId: "counsel-\(model)@impart.local",
            modelUsed: model,
            contentMarkdown: message.contentMarkdown,
            sentAt: message.sentAt,
            correlationId: message.correlationId,
            causationId: message.causationId
        )
        return builder
    }

    /// Set content.
    public func content(_ markdown: String) -> ResearchMessageBuilder {
        var builder = self
        builder.message = ResearchMessage(
            id: message.id,
            conversationId: message.conversationId,
            sequence: message.sequence,
            senderRole: message.senderRole,
            senderId: message.senderId,
            modelUsed: message.modelUsed,
            contentMarkdown: markdown,
            sentAt: message.sentAt,
            correlationId: message.correlationId,
            causationId: message.causationId
        )
        return builder
    }

    /// Set as response to another message.
    public func inResponseTo(_ messageId: UUID) -> ResearchMessageBuilder {
        var builder = self
        builder.message = ResearchMessage(
            id: message.id,
            conversationId: message.conversationId,
            sequence: message.sequence,
            senderRole: message.senderRole,
            senderId: message.senderId,
            modelUsed: message.modelUsed,
            contentMarkdown: message.contentMarkdown,
            sentAt: message.sentAt,
            correlationId: message.correlationId,
            causationId: messageId
        )
        return builder
    }

    /// Set as side conversation synthesis.
    public func synthesizing(sideConversationId: UUID) -> ResearchMessageBuilder {
        var builder = self
        builder.message = ResearchMessage(
            id: message.id,
            conversationId: message.conversationId,
            sequence: message.sequence,
            senderRole: message.senderRole,
            senderId: message.senderId,
            modelUsed: message.modelUsed,
            contentMarkdown: message.contentMarkdown,
            sentAt: message.sentAt,
            correlationId: message.correlationId,
            causationId: message.causationId,
            isSideConversationSynthesis: true,
            sideConversationId: sideConversationId
        )
        return builder
    }

    /// Set metrics.
    public func withMetrics(tokens: Int, durationMs: Int) -> ResearchMessageBuilder {
        var builder = self
        builder.message = ResearchMessage(
            id: message.id,
            conversationId: message.conversationId,
            sequence: message.sequence,
            senderRole: message.senderRole,
            senderId: message.senderId,
            modelUsed: message.modelUsed,
            contentMarkdown: message.contentMarkdown,
            sentAt: message.sentAt,
            correlationId: message.correlationId,
            causationId: message.causationId,
            isSideConversationSynthesis: message.isSideConversationSynthesis,
            sideConversationId: message.sideConversationId,
            tokenCount: tokens,
            processingDurationMs: durationMs
        )
        return builder
    }

    /// Build the message.
    public func build() -> ResearchMessage {
        message
    }
}

// MARK: - Side Conversation Display

/// Display information for a collapsed side conversation.
public struct SideConversationPreview: Codable, Sendable {
    /// The side conversation ID
    public let sideConversationId: UUID

    /// Title of the side conversation
    public let title: String

    /// Brief summary of what was discussed
    public let summary: String

    /// Participants in the side conversation
    public let participants: [String]

    /// Number of messages in the side conversation
    public let messageCount: Int

    /// Duration of the side conversation
    public let duration: TimeInterval

    public init(
        sideConversationId: UUID,
        title: String,
        summary: String,
        participants: [String],
        messageCount: Int,
        duration: TimeInterval
    ) {
        self.sideConversationId = sideConversationId
        self.title = title
        self.summary = summary
        self.participants = participants
        self.messageCount = messageCount
        self.duration = duration
    }
}

// MARK: - Message Timeline Item

/// An item in the conversation timeline (message or side conversation marker).
public enum TimelineItem: Identifiable, Sendable {
    case message(ResearchMessage)
    case sideConversationMarker(SideConversationPreview)

    public var id: UUID {
        switch self {
        case .message(let msg):
            return msg.id
        case .sideConversationMarker(let preview):
            return preview.sideConversationId
        }
    }

    public var date: Date {
        switch self {
        case .message(let msg):
            return msg.sentAt
        case .sideConversationMarker:
            return Date() // Would be set from actual data
        }
    }
}
