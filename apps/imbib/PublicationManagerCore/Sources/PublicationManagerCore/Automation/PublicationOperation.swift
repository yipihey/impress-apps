//
//  PublicationOperation.swift
//  PublicationManagerCore
//
//  Operations for publication automation that require UI synchronization.
//  Uses the shared ImpressOperationQueue infrastructure.
//

import Foundation
import ImpressOperationQueue

/// Operations that can be queued for publication automation via HTTP API.
/// These operations are processed by SwiftUI views to ensure proper UI updates.
public enum PublicationOperation: QueueableOperation {
    case addTag(tagPath: String)
    case removeTag(tagPath: String)
    case setFlag(flagStyle: String, color: String?, length: Int?)
    case clearFlag
    case markRead
    case markUnread
    case toggleStar
    case updateMetadata(title: String?, authors: [String]?)
    case setCollection(collectionID: UUID?)
    case updateBibTeX(rawBibTeX: String)
    case setPDFPath(path: String?)

    public var id: UUID { UUID() }

    public var operationDescription: String {
        switch self {
        case .addTag(let path):
            return "addTag(\(path))"
        case .removeTag(let path):
            return "removeTag(\(path))"
        case .setFlag(let style, let color, let length):
            return "setFlag(\(style), color:\(color ?? "nil"), length:\(length ?? 0))"
        case .clearFlag:
            return "clearFlag"
        case .markRead:
            return "markRead"
        case .markUnread:
            return "markUnread"
        case .toggleStar:
            return "toggleStar"
        case .updateMetadata(let title, let authors):
            return "updateMetadata(title:\(title != nil), authors:\(authors?.count ?? 0))"
        case .setCollection(let id):
            return "setCollection(\(id?.uuidString ?? "nil"))"
        case .updateBibTeX:
            return "updateBibTeX"
        case .setPDFPath(let path):
            return "setPDFPath(\(path ?? "nil"))"
        }
    }
}
