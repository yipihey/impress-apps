//
//  ProvenanceEvent.swift
//  MessageManagerCore
//
//  Swift types mirroring the Rust provenance event system.
//  These types provide the interface for tracking research conversation provenance.
//

import Foundation

// MARK: - Provenance Event ID

/// Unique identifier for a provenance event.
public struct ProvenanceEventId: Hashable, Codable, Sendable {
    /// The underlying UUID value.
    public let value: UUID

    /// Create a new random event ID.
    public init() {
        self.value = UUID()
    }

    /// Create from a UUID.
    public init(uuid: UUID) {
        self.value = uuid
    }

    /// Parse from a string.
    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.value = uuid
    }
}

extension ProvenanceEventId: CustomStringConvertible {
    public var description: String {
        value.uuidString
    }
}

// MARK: - Provenance Entity Type

/// Type of entity a provenance event affects.
public enum ProvenanceEntityType: String, Codable, Sendable {
    case conversation
    case message
    case artifact
    case insight
    case decision
    case system
}

// MARK: - Provenance Event

/// A provenance event in the impart research conversation system.
public struct ProvenanceEvent: Identifiable, Codable, Sendable {
    /// Unique event ID.
    public let id: ProvenanceEventId

    /// Sequence number for ordering.
    public var sequence: UInt64

    /// Event timestamp.
    public let timestamp: Date

    /// ID of the conversation this event relates to.
    public let conversationId: String

    /// Event payload.
    public let payload: ProvenancePayload

    /// ID of the actor that triggered this event.
    public let actorId: String

    /// Correlation ID for grouping related events.
    public let correlationId: String?

    /// Causation ID (ID of the event that caused this one).
    public let causationId: ProvenanceEventId?

    /// Create a new provenance event.
    public init(
        id: ProvenanceEventId = ProvenanceEventId(),
        sequence: UInt64 = 0,
        timestamp: Date = Date(),
        conversationId: String,
        payload: ProvenancePayload,
        actorId: String,
        correlationId: String? = nil,
        causationId: ProvenanceEventId? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.payload = payload
        self.actorId = actorId
        self.correlationId = correlationId
        self.causationId = causationId
    }

    /// Create with causation chain.
    public func withCausation(_ causationId: ProvenanceEventId) -> ProvenanceEvent {
        ProvenanceEvent(
            id: id,
            sequence: sequence,
            timestamp: timestamp,
            conversationId: conversationId,
            payload: payload,
            actorId: actorId,
            correlationId: correlationId,
            causationId: causationId
        )
    }

    /// Create with correlation.
    public func withCorrelation(_ correlationId: String) -> ProvenanceEvent {
        ProvenanceEvent(
            id: id,
            sequence: sequence,
            timestamp: timestamp,
            conversationId: conversationId,
            payload: payload,
            actorId: actorId,
            correlationId: correlationId,
            causationId: causationId
        )
    }

    /// Get a human-readable description.
    public var eventDescription: String {
        payload.description
    }

    /// Get the entity type affected.
    public var entityType: ProvenanceEntityType {
        payload.entityType
    }
}

// MARK: - Provenance Payload

/// Event payload containing the actual provenance data.
public enum ProvenancePayload: Codable, Sendable {
    // Conversation lifecycle
    case conversationCreated(title: String, participants: [String])
    case conversationBranched(fromMessageId: String, reason: String, branchTitle: String)
    case conversationArchived(reason: String?)
    case conversationUnarchived
    case conversationTitleUpdated(oldTitle: String, newTitle: String)
    case conversationSummarized(summary: String)

    // Messages
    case messageSent(messageId: String, role: String, modelUsed: String?, contentHash: String)
    case messageEdited(messageId: String, oldContentHash: String, newContentHash: String, reason: String?)
    case sideConversationSynthesized(sideConversationId: String, synthesisMessageId: String, summary: String)

    // Artifacts
    case artifactIntroduced(artifactUri: String, artifactType: String, version: String?, displayName: String)
    case artifactReferenced(artifactUri: String, messageId: String, contextSnippet: String)
    case artifactMetadataUpdated(artifactUri: String, field: String, oldValue: String?, newValue: String?)
    case artifactResolved(artifactUri: String, resolutionDetails: String)
    case artifactLinked(sourceUri: String, targetUri: String, relationship: String)

    // Insights and decisions
    case insightRecorded(insightId: String, summary: String, derivedFrom: [String], confidence: Double?)
    case decisionMade(decisionId: String, description: String, rationale: String, alternativesConsidered: [String])
    case decisionRevised(decisionId: String, oldDescription: String, newDescription: String, revisionReason: String)

    // System
    case systemPaused(reason: String?)
    case systemResumed
    case snapshotCreated(snapshotId: String, format: String)
    case conversationExported(exportId: String, format: String, destination: String)
    case conversationImported(importId: String, source: String, originalConversationId: String?)

    /// Human-readable description.
    public var description: String {
        switch self {
        case .conversationCreated(let title, _):
            return "Conversation created: \(title)"
        case .conversationBranched(_, _, let branchTitle):
            return "Branched: \(branchTitle)"
        case .conversationArchived:
            return "Conversation archived"
        case .conversationUnarchived:
            return "Conversation unarchived"
        case .conversationTitleUpdated(_, let newTitle):
            return "Title updated: \(newTitle)"
        case .conversationSummarized:
            return "Summary generated"

        case .messageSent(_, let role, let modelUsed, _):
            if let model = modelUsed {
                return "Message from \(role) (\(model))"
            }
            return "Message from \(role)"
        case .messageEdited(let messageId, _, _, _):
            return "Message \(messageId) edited"
        case .sideConversationSynthesized(_, _, let summary):
            return "Side conversation synthesized: \(summary)"

        case .artifactIntroduced(_, let type, _, let displayName):
            return "\(type) introduced: \(displayName)"
        case .artifactReferenced(let uri, _, _):
            return "Artifact referenced: \(uri)"
        case .artifactMetadataUpdated(let uri, let field, _, _):
            return "Artifact \(uri) updated: \(field)"
        case .artifactResolved(let uri, _):
            return "Artifact resolved: \(uri)"
        case .artifactLinked(let source, let target, let rel):
            return "\(source) \(rel) \(target)"

        case .insightRecorded(_, let summary, _, _):
            return "Insight: \(summary)"
        case .decisionMade(_, let description, _, _):
            return "Decision: \(description)"
        case .decisionRevised(_, _, let newDescription, _):
            return "Decision revised: \(newDescription)"

        case .systemPaused(let reason):
            if let r = reason {
                return "System paused: \(r)"
            }
            return "System paused"
        case .systemResumed:
            return "System resumed"
        case .snapshotCreated(let snapshotId, _):
            return "Snapshot created: \(snapshotId)"
        case .conversationExported(_, let format, _):
            return "Exported as \(format)"
        case .conversationImported(_, let source, _):
            return "Imported from \(source)"
        }
    }

    /// Entity type affected by this payload.
    public var entityType: ProvenanceEntityType {
        switch self {
        case .conversationCreated, .conversationBranched, .conversationArchived,
             .conversationUnarchived, .conversationTitleUpdated, .conversationSummarized,
             .conversationExported, .conversationImported:
            return .conversation

        case .messageSent, .messageEdited, .sideConversationSynthesized:
            return .message

        case .artifactIntroduced, .artifactReferenced, .artifactMetadataUpdated,
             .artifactResolved, .artifactLinked:
            return .artifact

        case .insightRecorded:
            return .insight

        case .decisionMade, .decisionRevised:
            return .decision

        case .systemPaused, .systemResumed, .snapshotCreated:
            return .system
        }
    }
}

// MARK: - Conversation Provenance Stats

/// Statistics about a conversation's provenance.
public struct ConversationProvenanceStats: Codable, Sendable {
    /// Total number of provenance events.
    public let totalEvents: Int

    /// Number of messages sent.
    public let messageCount: Int

    /// Number of unique artifacts referenced.
    public let artifactCount: Int

    /// Number of decisions made.
    public let decisionCount: Int

    /// Number of insights recorded.
    public let insightCount: Int

    /// Number of unique actors.
    public let actorCount: Int

    /// Number of branch conversations.
    public let branchCount: Int

    public init(
        totalEvents: Int,
        messageCount: Int,
        artifactCount: Int,
        decisionCount: Int,
        insightCount: Int,
        actorCount: Int,
        branchCount: Int
    ) {
        self.totalEvents = totalEvents
        self.messageCount = messageCount
        self.artifactCount = artifactCount
        self.decisionCount = decisionCount
        self.insightCount = insightCount
        self.actorCount = actorCount
        self.branchCount = branchCount
    }
}
