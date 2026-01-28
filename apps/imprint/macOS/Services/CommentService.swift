//
//  CommentService.swift
//  imprint
//
//  Service for managing document comments.
//  Handles CRUD operations, filtering, and sync.
//

import Foundation
import SwiftUI
import Combine
import OSLog

private let logger = Logger(subsystem: "com.imprint.app", category: "comments")

// MARK: - Comment Service

/// Service for managing comments attached to a document.
///
/// Features:
/// - CRUD operations for comments
/// - Threaded comment organization
/// - Filter by resolved/unresolved/author
/// - Range adjustment when document is edited
/// - Persistence with document
@MainActor
public final class CommentService: ObservableObject {

    // MARK: - Published State

    /// All comments in the document
    @Published public private(set) var comments: [Comment] = []

    /// Current filter for display
    @Published public var filter: CommentFilter = .all

    /// Current sort order
    @Published public var sortOrder: CommentSort = .position

    /// Currently selected comment (for navigation)
    @Published public var selectedCommentId: UUID?

    // MARK: - Private State

    /// Current user's author ID
    private let localAuthorId: String

    /// Current user's display name
    @AppStorage("collaboration.displayName") private var localDisplayName: String = NSFullUserName()

    // MARK: - Computed Properties

    /// Comments organized into threads
    public var threads: [CommentThread] {
        let rootComments = comments.filter { $0.parentId == nil }
        return rootComments.map { root in
            let replies = comments.filter { $0.parentId == root.id }
                .sorted { $0.createdAt < $1.createdAt }
            return CommentThread(rootComment: root, replies: replies)
        }
    }

    /// Filtered and sorted threads
    public var filteredThreads: [CommentThread] {
        var result = threads

        // Apply filter
        switch filter {
        case .all:
            break
        case .unresolved:
            result = result.filter { !$0.rootComment.isResolved }
        case .resolved:
            result = result.filter { $0.rootComment.isResolved }
        case .mine:
            result = result.filter { $0.rootComment.authorId == localAuthorId }
        }

        // Apply sort
        switch sortOrder {
        case .position:
            result.sort { $0.textRange.start < $1.textRange.start }
        case .newest:
            result.sort { $0.lastActivity > $1.lastActivity }
        case .oldest:
            result.sort { $0.lastActivity < $1.lastActivity }
        }

        return result
    }

    /// Count of unresolved comments
    public var unresolvedCount: Int {
        comments.filter { !$0.isResolved && $0.parentId == nil }.count
    }

    /// Count of resolved comments
    public var resolvedCount: Int {
        comments.filter { $0.isResolved && $0.parentId == nil }.count
    }

    // MARK: - Initialization

    public init(authorId: String? = nil) {
        self.localAuthorId = authorId ?? UUID().uuidString
    }

    // MARK: - CRUD Operations

    /// Add a new comment at the given text range.
    @discardableResult
    public func addComment(
        content: String,
        at range: TextRange,
        parentId: UUID? = nil
    ) -> Comment {
        let comment = Comment(
            author: localDisplayName,
            authorId: localAuthorId,
            content: content,
            textRange: range,
            parentId: parentId
        )

        comments.append(comment)
        logger.info("Added comment \(comment.id) at \(range.start)-\(range.end)")

        return comment
    }

    /// Update an existing comment's content.
    public func updateComment(_ id: UUID, content: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            logger.warning("Comment \(id) not found for update")
            return
        }

        comments[index].content = content
        comments[index].modifiedAt = Date()
        logger.info("Updated comment \(id)")
    }

    /// Delete a comment and its replies.
    public func deleteComment(_ id: UUID) {
        // Delete replies first
        let replyIds = comments.filter { $0.parentId == id }.map { $0.id }
        for replyId in replyIds {
            deleteComment(replyId)
        }

        // Delete the comment
        comments.removeAll { $0.id == id }
        logger.info("Deleted comment \(id)")

        if selectedCommentId == id {
            selectedCommentId = nil
        }
    }

    /// Toggle the resolved state of a comment.
    public func toggleResolved(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            return
        }

        comments[index].isResolved.toggle()
        comments[index].modifiedAt = Date()
        logger.info("Toggled resolved state for \(id): \(self.comments[index].isResolved)")
    }

    /// Resolve a comment and optionally all its replies.
    public func resolve(_ id: UUID, includeReplies: Bool = true) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            return
        }

        comments[index].isResolved = true
        comments[index].modifiedAt = Date()

        if includeReplies {
            // Resolve all replies
            for i in comments.indices {
                if comments[i].parentId == id {
                    comments[i].isResolved = true
                    comments[i].modifiedAt = Date()
                }
            }
        }

        logger.info("Resolved comment \(id)")
    }

    /// Unresolve a comment (reopen it).
    public func unresolve(_ id: UUID) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else {
            return
        }

        comments[index].isResolved = false
        comments[index].modifiedAt = Date()
        logger.info("Unresolved comment \(id)")
    }

    /// Add a reply to an existing comment.
    @discardableResult
    public func addReply(to parentId: UUID, content: String) -> Comment? {
        guard let parent = comments.first(where: { $0.id == parentId }) else {
            logger.warning("Parent comment \(parentId) not found")
            return nil
        }

        let reply = Comment(
            author: localDisplayName,
            authorId: localAuthorId,
            content: content,
            textRange: parent.textRange,
            parentId: parentId
        )

        comments.append(reply)
        logger.info("Added reply \(reply.id) to \(parentId)")

        return reply
    }

    // MARK: - Navigation

    /// Navigate to a comment (select and scroll to it).
    public func navigateTo(_ comment: Comment) {
        selectedCommentId = comment.id
        NotificationCenter.default.post(
            name: .navigateToComment,
            object: comment
        )
    }

    /// Get the comment at a given text position.
    public func comment(at position: Int) -> Comment? {
        comments.first { comment in
            comment.textRange.start <= position && position <= comment.textRange.end
        }
    }

    /// Get all comments overlapping a given range.
    public func comments(in range: TextRange) -> [Comment] {
        comments.filter { comment in
            comment.textRange.start < range.end && range.start < comment.textRange.end
        }
    }

    // MARK: - Document Sync

    /// Adjust all comment ranges after a text edit.
    public func adjustRanges(forEditAt position: Int, lengthDelta: Int) {
        for i in comments.indices {
            comments[i].textRange.adjustForEdit(at: position, lengthDelta: lengthDelta)
        }
    }

    /// Load comments from serialized data.
    public func load(from data: Data) throws {
        comments = try JSONDecoder().decode([Comment].self, from: data)
        logger.info("Loaded \(self.comments.count) comments")
    }

    /// Serialize comments for storage.
    public func serialize() throws -> Data {
        try JSONEncoder().encode(comments)
    }

    /// Clear all comments.
    public func clear() {
        comments.removeAll()
        selectedCommentId = nil
        logger.info("Cleared all comments")
    }

    // MARK: - Import/Export

    /// Export comments to a human-readable format.
    public func exportToText() -> String {
        var lines: [String] = []
        lines.append("# Comments Export")
        lines.append("Generated: \(Date().formatted())")
        lines.append("")

        for thread in filteredThreads {
            lines.append("---")
            lines.append("[\(thread.rootComment.isResolved ? "RESOLVED" : "OPEN")] @ position \(thread.textRange.start)")
            lines.append("\(thread.rootComment.author) (\(thread.rootComment.createdAt.formatted())):")
            lines.append(thread.rootComment.content)

            for reply in thread.replies {
                lines.append("")
                lines.append("  ↳ \(reply.author) (\(reply.createdAt.formatted())):")
                lines.append("    \(reply.content)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when user should navigate to a comment
    static let navigateToComment = Notification.Name("navigateToComment")
    // Note: addCommentAtSelection and toggleCommentsSidebar are defined in ImprintApp.swift
}
