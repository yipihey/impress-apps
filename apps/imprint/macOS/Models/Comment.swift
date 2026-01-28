//
//  Comment.swift
//  imprint
//
//  Model for document comments and annotations.
//  Supports threaded discussions linked to text ranges.
//

import Foundation
import SwiftUI

// MARK: - Comment

/// A comment attached to a text range in the document.
///
/// Comments can be:
/// - Linked to a specific text selection
/// - Part of a threaded discussion
/// - Resolved when addressed
public struct Comment: Identifiable, Equatable, Codable {
    /// Unique identifier
    public let id: UUID

    /// Author's display name
    public var author: String

    /// Author's unique ID (for avatar color)
    public var authorId: String

    /// Comment content
    public var content: String

    /// Range in document (character offsets)
    public var textRange: TextRange

    /// When the comment was created
    public var createdAt: Date

    /// When the comment was last modified
    public var modifiedAt: Date

    /// Whether the comment has been resolved
    public var isResolved: Bool

    /// ID of parent comment (nil for top-level comments)
    public var parentId: UUID?

    public init(
        id: UUID = UUID(),
        author: String,
        authorId: String,
        content: String,
        textRange: TextRange,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isResolved: Bool = false,
        parentId: UUID? = nil
    ) {
        self.id = id
        self.author = author
        self.authorId = authorId
        self.content = content
        self.textRange = textRange
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isResolved = isResolved
        self.parentId = parentId
    }

    /// Color for this comment's author
    public var authorColor: Color {
        Comment.colorForAuthor(authorId)
    }

    /// Get a deterministic color for an author ID
    public static func colorForAuthor(_ authorId: String) -> Color {
        let colors: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .mint]
        let hash = abs(authorId.hashValue)
        return colors[hash % colors.count]
    }
}

// MARK: - Text Range

/// A range in the document text.
public struct TextRange: Equatable, Codable, Hashable {
    /// Start position (character offset)
    public var start: Int

    /// End position (character offset)
    public var end: Int

    /// Length of the range
    public var length: Int {
        end - start
    }

    /// Whether this is a valid range
    public var isValid: Bool {
        start >= 0 && end >= start
    }

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public init(nsRange: NSRange) {
        self.start = nsRange.location
        self.end = nsRange.location + nsRange.length
    }

    public var nsRange: NSRange {
        NSRange(location: start, length: length)
    }

    /// Adjust range after text edit
    public mutating func adjustForEdit(at editPosition: Int, lengthDelta: Int) {
        if editPosition <= start {
            // Edit is before this range, shift both bounds
            start += lengthDelta
            end += lengthDelta
        } else if editPosition < end {
            // Edit is within this range, extend/shrink end
            end += lengthDelta
        }
        // Edit is after this range, no change needed
    }
}

// MARK: - Comment Thread

/// A thread of comments (top-level comment + replies).
public struct CommentThread: Identifiable {
    /// ID of the root comment
    public var id: UUID { rootComment.id }

    /// The top-level comment
    public var rootComment: Comment

    /// Replies to the root comment
    public var replies: [Comment]

    /// Total number of comments in thread
    public var count: Int {
        1 + replies.count
    }

    /// Whether all comments in thread are resolved
    public var isFullyResolved: Bool {
        rootComment.isResolved && replies.allSatisfy { $0.isResolved }
    }

    /// The text range this thread is attached to
    public var textRange: TextRange {
        rootComment.textRange
    }

    /// Most recent activity in the thread
    public var lastActivity: Date {
        ([rootComment] + replies).map { $0.modifiedAt }.max() ?? rootComment.createdAt
    }

    public init(rootComment: Comment, replies: [Comment] = []) {
        self.rootComment = rootComment
        self.replies = replies
    }
}

// MARK: - Comment Filter

/// Options for filtering comments.
public enum CommentFilter: String, CaseIterable, Identifiable {
    case all
    case unresolved
    case resolved
    case mine

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .unresolved: return "Open"
        case .resolved: return "Resolved"
        case .mine: return "My Comments"
        }
    }

    public var iconName: String {
        switch self {
        case .all: return "bubble.left.and.bubble.right"
        case .unresolved: return "bubble.left"
        case .resolved: return "checkmark.bubble"
        case .mine: return "person.bubble"
        }
    }
}

// MARK: - Comment Sort

/// Options for sorting comments.
public enum CommentSort: String, CaseIterable, Identifiable {
    case position
    case newest
    case oldest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .position: return "Position in Document"
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        }
    }
}
