//
//  Comment.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDComment.
//

import Foundation
import ImbibRustCore

/// A threaded comment on any item (publication, artifact, etc.).
public struct Comment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let text: String
    public let authorIdentifier: String?
    public let authorDisplayName: String?
    public let dateCreated: Date
    public let dateModified: Date
    public let parentCommentID: UUID?
    public let parentItemID: UUID
    public let parentSchema: String?

    /// Range-anchored comment fields (see `RangeAnchoredComments`). Non-nil
    /// only for comments created via `createAnchoredComment` — e.g. imprint
    /// store-first manuscript comments that pin to a UTF-8 byte range.
    public let anchorStart: Int64?
    public let anchorEnd: Int64?
    public let anchorText: String?
    public let anchoredBodyHash: String?

    /// Backward-compatible alias for code that expects `publicationID`.
    public var publicationID: UUID { parentItemID }

    public var isOnPublication: Bool {
        parentSchema?.hasPrefix("imbib/bibliography") ?? true
    }

    public var isOnArtifact: Bool {
        parentSchema?.hasPrefix("imbib/artifact") ?? false
    }

    public init(from row: CommentRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.text = row.text
        self.authorIdentifier = row.authorIdentifier
        self.authorDisplayName = row.authorDisplayName
        self.dateCreated = Date(timeIntervalSince1970: TimeInterval(row.dateCreated) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.dateModified) / 1000.0)
        self.parentCommentID = row.parentCommentId.flatMap { UUID(uuidString: $0) }
        self.parentItemID = UUID(uuidString: row.parentItemId) ?? UUID()
        self.parentSchema = row.parentSchema
        self.anchorStart = row.anchorStart
        self.anchorEnd = row.anchorEnd
        self.anchorText = row.anchorText
        self.anchoredBodyHash = row.anchoredBodyHash
    }
}
