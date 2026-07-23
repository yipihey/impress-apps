//
//  CommentService.swift
//  PublicationManagerCore
//
//  Service for managing threaded comments on any item (publications, artifacts, etc.).
//

import Foundation
import ImpressKit
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Comment Service

/// Service for managing threaded comments on any item type.
///
/// Comments can be attached to publications, artifacts, or any future item type.
/// They enable discussion among collaborators in shared library contexts.
@MainActor
public final class CommentService {

    public static let shared = CommentService()

    private let store: RustStoreAdapter

    private init() {
        self.store = .shared
    }

    // MARK: - CRUD (Generic)

    /// Add a comment to any item.
    ///
    /// - Parameters:
    ///   - text: Comment text (supports markdown)
    ///   - itemID: The item to comment on (publication, artifact, etc.)
    ///   - parentCommentID: Optional parent comment ID for threading
    /// - Returns: The created comment
    @discardableResult
    public func addComment(
        text: String,
        to itemID: UUID,
        parentCommentID: UUID? = nil
    ) -> Comment? {
        let authorName = resolveAuthorName()
        let authorIdentifier = currentAuthorIdentifier

        let comment = store.createCommentOnItem(
            itemId: itemID,
            text: text,
            authorIdentifier: authorIdentifier,
            authorDisplayName: authorName,
            parentCommentId: parentCommentID
        )

        if let comment {
            // Post notification
            NotificationCenter.default.post(name: .commentAdded, object: comment)

            // Record activity if we can determine context
            recordCommentActivity(comment: comment, authorName: authorName ?? "Unknown")

            Logger.sync.info("Added comment to item \(itemID.uuidString)")
        }

        return comment
    }

    /// Edit an existing comment.
    public func editComment(_ commentID: UUID, newText: String) {
        store.updateComment(id: commentID, text: newText)
    }

    /// Delete a comment.
    public func deleteComment(_ commentID: UUID) {
        store.deleteItem(id: commentID)
        NotificationCenter.default.post(name: .commentDeleted, object: commentID)
    }

    // MARK: - Queries (Generic)

    /// Get top-level comments for any item.
    public func comments(for itemID: UUID) -> [Comment] {
        let allComments = store.commentsForItem(itemID)
        return allComments.filter { $0.parentCommentID == nil }
    }

    /// All comments including replies for any item.
    public func allComments(for itemID: UUID) -> [Comment] {
        store.commentsForItem(itemID)
    }

    /// Total comment count for any item.
    public func commentCount(for itemID: UUID) -> Int {
        store.commentsForItem(itemID).count
    }

    // MARK: - Author Resolution

    private func resolveAuthorName() -> String? {
        // Device display name; CloudKit identity resolution was removed with
        // the CloudKit sharing stack (ADR-023 — imbib migrated off CloudKit).
        CurrentDeviceAuthor.displayName ?? "Me"
    }

    /// The stable identifier stamped onto comments authored on this
    /// installation, and compared in ``isOwnComment(_:)``.
    ///
    /// This is deliberately NOT the CloudKit user record (imbib migrated off
    /// CloudKit, ADR-023) nor the device name (user-editable, `nil` in
    /// sandboxes) — both are unstable across sessions, which is exactly the
    /// bug this fixes. It is a persisted per-installation UUID
    /// (`CurrentDeviceAuthor.stableIdentifier`), identical across every
    /// launch and across imbib/imprint. If genuine cross-device sharing
    /// returns, prefer the CloudKit record name here when it is available.
    public var currentAuthorIdentifier: String {
        CurrentDeviceAuthor.stableIdentifier
    }

    /// Check if a comment was authored by the current user.
    public func isOwnComment(_ comment: Comment) -> Bool {
        comment.authorIdentifier == currentAuthorIdentifier
    }

    // MARK: - Activity Recording

    private func recordCommentActivity(comment: Comment, authorName: String) {
        if comment.isOnPublication {
            let pub = store.getPublication(id: comment.parentItemID)
            if let pub, let libraryName = pub.libraryName {
                let libraries = store.listLibraries()
                if let library = libraries.first(where: { $0.name == libraryName }) {
                    ActivityFeedService.shared.recordActivity(
                        type: .commented,
                        actorName: authorName,
                        targetTitle: pub.title,
                        targetID: comment.parentItemID,
                        in: library.id
                    )
                }
            }
        } else if comment.isOnArtifact {
            let artifact = store.getArtifact(id: comment.parentItemID)
            if let artifact {
                Logger.sync.info("Comment added to artifact '\(artifact.title)'")
            }
        }
    }
}
