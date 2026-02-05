//
//  MessageOperation.swift
//  MessageManagerCore
//
//  Operations for message automation that require UI synchronization.
//  Uses the shared ImpressOperationQueue infrastructure.
//

import Foundation
import ImpressOperationQueue

/// Operations that can be queued for message automation via HTTP API.
/// These operations are processed by SwiftUI views to ensure proper UI updates.
public enum MessageOperation: QueueableOperation {
    case moveToMailbox(mailboxID: UUID)
    case markAsRead
    case markAsUnread
    case setFlag(flag: String)
    case clearFlag(flag: String)
    case archive
    case trash
    case draftReply(content: String, inReplyTo: UUID?)
    case sendDraft
    case star
    case unstar
    case setLabels(labels: [String])
    case addLabel(label: String)
    case removeLabel(label: String)

    public var id: UUID { UUID() }

    public var operationDescription: String {
        switch self {
        case .moveToMailbox(let id):
            return "moveToMailbox(\(id.uuidString))"
        case .markAsRead:
            return "markAsRead"
        case .markAsUnread:
            return "markAsUnread"
        case .setFlag(let flag):
            return "setFlag(\(flag))"
        case .clearFlag(let flag):
            return "clearFlag(\(flag))"
        case .archive:
            return "archive"
        case .trash:
            return "trash"
        case .draftReply(_, let inReplyTo):
            return "draftReply(inReplyTo:\(inReplyTo?.uuidString ?? "nil"))"
        case .sendDraft:
            return "sendDraft"
        case .star:
            return "star"
        case .unstar:
            return "unstar"
        case .setLabels(let labels):
            return "setLabels(\(labels.count) labels)"
        case .addLabel(let label):
            return "addLabel(\(label))"
        case .removeLabel(let label):
            return "removeLabel(\(label))"
        }
    }
}
