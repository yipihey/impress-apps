//
//  ConversationOperation.swift
//  MessageManagerCore
//
//  Operations for research conversation automation that require UI synchronization.
//  Uses the shared ImpressOperationQueue infrastructure.
//

import Foundation
import ImpressOperationQueue

/// Operations that can be queued for research conversation automation via HTTP API.
/// These operations are processed by SwiftUI views to ensure proper UI updates.
public enum ConversationOperation: QueueableOperation {
    /// Create a new research conversation
    case create(title: String, participants: [String])

    /// Add a message to the conversation
    case addMessage(senderRole: String, senderId: String, content: String, causationId: UUID?)

    /// Branch a conversation from a specific message
    case branch(fromMessageId: UUID, title: String)

    /// Update conversation metadata
    case update(title: String?, summary: String?, tags: [String]?)

    /// Archive the conversation
    case archive

    /// Record an artifact reference
    case recordArtifact(uri: String, type: String, displayName: String?)

    /// Record a decision
    case recordDecision(description: String, rationale: String)

    public var id: UUID { UUID() }

    public var operationDescription: String {
        switch self {
        case .create(let title, let participants):
            return "create(title:\(title), participants:\(participants.count))"
        case .addMessage(let role, let senderId, _, let causationId):
            return "addMessage(role:\(role), sender:\(senderId), causation:\(causationId?.uuidString ?? "nil"))"
        case .branch(let messageId, let title):
            return "branch(from:\(messageId.uuidString), title:\(title))"
        case .update(let title, let summary, let tags):
            return "update(title:\(title != nil), summary:\(summary != nil), tags:\(tags?.count ?? 0))"
        case .archive:
            return "archive"
        case .recordArtifact(let uri, let type, _):
            return "recordArtifact(uri:\(uri), type:\(type))"
        case .recordDecision(let description, _):
            return "recordDecision(\(description.prefix(30))...)"
        }
    }
}
