//
//  CommentService.swift
//  PublicationManagerCore
//
//  Service for managing threaded comments on publications.
//

import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Comment Service

/// Service for managing threaded comments on publications in shared libraries.
///
/// Comments are only meaningful in shared library contexts -- they enable
/// discussion about papers among collaborators. For private libraries,
/// use the existing notes field on publications instead.
@MainActor
public final class CommentService {

    public static let shared = CommentService()

    private let store: RustStoreAdapter

    private init() {
        self.store = .shared
    }

    // MARK: - CRUD

    /// Add a comment to a publication.
    ///
    /// - Parameters:
    ///   - text: Comment text (supports markdown)
    ///   - publicationID: The publication to comment on
    ///   - parentCommentID: Optional parent comment ID for threading
    /// - Returns: The created comment
    @discardableResult
    public func addComment(
        text: String,
        to publicationID: UUID,
        parentCommentID: UUID? = nil
    ) -> Comment? {
        let authorName = resolveAuthorName()
        let authorIdentifier = resolveAuthorIdentifier()

        let comment = store.createComment(
            publicationId: publicationID,
            text: text,
            authorIdentifier: authorIdentifier,
            authorDisplayName: authorName,
            parentCommentId: parentCommentID
        )

        if let comment {
            // Post notification
            NotificationCenter.default.post(name: .commentAdded, object: comment)

            // Record activity
            let pub = store.getPublication(id: publicationID)
            if let pub {
                // Try to find a library for this publication to record activity
                // The publication's library is encoded in its row data
                if let libraryName = pub.libraryName {
                    let libraries = store.listLibraries()
                    if let library = libraries.first(where: { $0.name == libraryName }) {
                        ActivityFeedService.shared.recordActivity(
                            type: .commented,
                            actorName: authorName,
                            targetTitle: pub.title,
                            targetID: publicationID,
                            in: library.id
                        )
                    }
                }
            }

            Logger.sync.info("Added comment to publication \(publicationID.uuidString)")
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

    // MARK: - Queries

    /// Get all comments for a publication, organized for threading.
    ///
    /// Returns top-level comments sorted by date, with replies accessible
    /// via parentCommentID filtering.
    public func comments(for publicationID: UUID) -> [Comment] {
        let allComments = store.listComments(publicationId: publicationID)
        return allComments.filter { $0.parentCommentID == nil }
    }

    /// All comments including replies for a publication.
    public func allComments(for publicationID: UUID) -> [Comment] {
        store.listComments(publicationId: publicationID)
    }

    /// Total comment count for a publication.
    public func commentCount(for publicationID: UUID) -> Int {
        store.listComments(publicationId: publicationID).count
    }

    // MARK: - Author Resolution

    private func resolveAuthorName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Me"
        #else
        return UIDevice.current.name
        #endif
    }

    private func resolveAuthorIdentifier() -> String? {
        #if os(macOS)
        return Host.current().localizedName
        #else
        return UIDevice.current.name
        #endif
    }
}
