//
//  CommentService.swift
//  PublicationManagerCore
//
//  Service for managing threaded comments on any item (publications, artifacts, etc.).
//

import Foundation
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
        let authorIdentifier = resolveAuthorIdentifier()

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

    /// Cached CloudKit user identity (fetched once per session).
    private var cachedIdentity: (name: String?, identifier: String)?

    /// Refresh author identity from CloudKit.
    ///
    /// Call this once at app launch or when iCloud account changes.
    /// Falls back to device name when CloudKit is unavailable.
    public func refreshAuthorIdentity() async {
        let identity = await LibrarySharingService.shared.currentUserIdentity()
        cachedIdentity = identity
        Logger.sync.info("Author identity refreshed: \(identity.name ?? "nil"), id: \(identity.identifier)")
    }

    private func resolveAuthorName() -> String? {
        if let cached = cachedIdentity {
            return cached.name
        }
        // Fallback to device name
        #if os(macOS)
        return Host.current().localizedName ?? "Me"
        #else
        return UIDevice.current.name
        #endif
    }

    private func resolveAuthorIdentifier() -> String? {
        if let cached = cachedIdentity {
            return cached.identifier
        }
        // Fallback to device name
        #if os(macOS)
        return Host.current().localizedName
        #else
        return UIDevice.current.name
        #endif
    }

    /// Check if a comment was authored by the current user.
    public func isOwnComment(_ comment: Comment) -> Bool {
        guard let currentID = resolveAuthorIdentifier() else { return false }
        return comment.authorIdentifier == currentID
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
