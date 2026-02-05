//
//  CommentService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import Foundation
import CoreData
import OSLog
#if canImport(UIKit)
import UIKit
#endif

#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - Comment Service

/// Service for managing threaded comments on publications in shared libraries.
///
/// Comments are only meaningful in shared library contexts — they enable
/// discussion about papers among collaborators. For private libraries,
/// use the existing notes field on publications instead.
@MainActor
public final class CommentService {

    public static let shared = CommentService()

    private let persistenceController: PersistenceController

    private init() {
        self.persistenceController = .shared
    }

    /// Initialize with custom persistence controller (for testing)
    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    // MARK: - CRUD

    /// Add a comment to a publication.
    ///
    /// - Parameters:
    ///   - text: Comment text (supports markdown)
    ///   - publication: The publication to comment on
    ///   - parentCommentID: Optional parent comment ID for threading
    /// - Returns: The created comment
    @discardableResult
    public func addComment(
        text: String,
        to publication: CDPublication,
        parentCommentID: UUID? = nil
    ) throws -> CDComment {
        let context = persistenceController.viewContext

        let comment = CDComment(context: context)
        comment.id = UUID()
        comment.text = text
        comment.dateCreated = Date()
        comment.dateModified = Date()
        comment.parentCommentID = parentCommentID
        comment.publication = publication

        // Resolve author from CloudKit share participant
        resolveAuthor(for: comment, publication: publication)

        try context.save()

        // Post notification
        NotificationCenter.default.post(name: .commentAdded, object: comment)

        // Record activity if in a shared library
        if let library = publication.libraries?.first(where: { $0.isSharedLibrary }) {
            try? ActivityFeedService.shared.recordActivity(
                type: .commented,
                actorName: comment.authorDisplayName,
                targetTitle: publication.title,
                targetID: publication.id,
                in: library
            )
        }

        Logger.sync.info("Added comment to '\(publication.citeKey)'")

        return comment
    }

    /// Edit an existing comment.
    public func editComment(_ comment: CDComment, newText: String) throws {
        let context = persistenceController.viewContext
        comment.text = newText
        comment.dateModified = Date()
        try context.save()
    }

    /// Delete a comment.
    public func deleteComment(_ comment: CDComment) throws {
        let context = persistenceController.viewContext
        let commentID = comment.id
        context.delete(comment)
        try context.save()

        NotificationCenter.default.post(name: .commentDeleted, object: commentID)
    }

    // MARK: - Queries

    /// Get all comments for a publication, organized for threading.
    ///
    /// Returns top-level comments sorted by date, with replies accessible
    /// via `comment.replies(from:)`.
    public func comments(for publication: CDPublication) -> [CDComment] {
        let allComments = (publication.comments ?? []).sorted { $0.dateCreated < $1.dateCreated }
        return allComments.filter { $0.isTopLevel }
    }

    /// Total comment count for a publication
    public func commentCount(for publication: CDPublication) -> Int {
        publication.comments?.count ?? 0
    }

    // MARK: - Author Resolution

    private func resolveAuthor(for comment: CDComment, publication: CDPublication) {
        #if canImport(CloudKit)
        if let library = publication.libraries?.first(where: { $0.isSharedLibrary }),
           let share = PersistenceController.shared.share(for: library),
           let participant = share.currentUserParticipant {
            if let nameComponents = participant.userIdentity.nameComponents {
                let formatter = PersonNameComponentsFormatter()
                formatter.style = .default
                comment.authorDisplayName = formatter.string(from: nameComponents)
            }
            comment.authorIdentifier = participant.userIdentity.lookupInfo?.emailAddress
                ?? participant.userIdentity.lookupInfo?.phoneNumber
                ?? participant.participantID
        } else {
            setLocalAuthor(for: comment)
        }
        #else
        setLocalAuthor(for: comment)
        #endif
    }

    private func setLocalAuthor(for comment: CDComment) {
        #if os(macOS)
        comment.authorDisplayName = Host.current().localizedName ?? "Me"
        #else
        comment.authorDisplayName = UIDevice.current.name
        #endif
    }
}
