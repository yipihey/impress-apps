//
//  ConversationTypes.swift
//  MessageManagerCore
//
//  Enums for conversation modes and message intents.
//  Supports Claude Code-style development conversations.
//

import Foundation

// MARK: - Conversation Mode

/// Mode of a research conversation, determining its presentation and behavior.
public enum ConversationMode: String, Codable, Sendable, CaseIterable {
    /// Normal back-and-forth discussion
    case interactive

    /// Design/planning session (creates new thread in email view)
    case planning

    /// Code review checkpoint
    case review

    /// Completed/reference conversation
    case archival

    /// Human-readable display name for the mode.
    public var displayName: String {
        switch self {
        case .interactive: return "Chat"
        case .planning: return "Planning"
        case .review: return "Review"
        case .archival: return "Archive"
        }
    }

    /// SF Symbol icon name for the mode.
    public var iconName: String {
        switch self {
        case .interactive: return "bubble.left.and.bubble.right"
        case .planning: return "doc.text.magnifyingglass"
        case .review: return "checkmark.circle"
        case .archival: return "archivebox"
        }
    }

    /// Whether this mode should show as a separate thread in email view.
    public var showsAsThread: Bool {
        switch self {
        case .planning, .review: return true
        case .interactive, .archival: return false
        }
    }

    /// Whether messages in this mode should support collapsible threading.
    public var supportsThreading: Bool {
        switch self {
        case .planning: return true
        case .interactive, .review, .archival: return false
        }
    }
}

// MARK: - Message Intent

/// Intent/purpose of a message in a conversation.
/// Determines how the message is displayed and processed.
public enum MessageIntent: String, Codable, Sendable, CaseIterable {
    /// Regular discussion message
    case converse

    /// Request to perform an action
    case execute

    /// Result of an execution
    case result

    /// Suggested approach or plan
    case proposal

    /// User acceptance or rejection
    case approval

    /// Structured plan content
    case plan

    /// Error report
    case error

    /// Human-readable display name for the intent.
    public var displayName: String {
        switch self {
        case .converse: return "Message"
        case .execute: return "Execute"
        case .result: return "Result"
        case .proposal: return "Proposal"
        case .approval: return "Decision"
        case .plan: return "Plan"
        case .error: return "Error"
        }
    }

    /// SF Symbol icon name for the intent.
    public var iconName: String {
        switch self {
        case .converse: return "text.bubble"
        case .execute: return "play.circle"
        case .result: return "checkmark.square"
        case .proposal: return "lightbulb"
        case .approval: return "hand.thumbsup"
        case .plan: return "list.bullet.clipboard"
        case .error: return "exclamationmark.triangle"
        }
    }

    /// Whether this intent should be visually highlighted.
    public var isHighlighted: Bool {
        switch self {
        case .execute, .proposal, .plan, .error: return true
        case .converse, .result, .approval: return false
        }
    }

    /// Color hint for the intent (semantic name, not actual color).
    public var colorHint: String {
        switch self {
        case .converse: return "primary"
        case .execute: return "blue"
        case .result: return "green"
        case .proposal: return "orange"
        case .approval: return "purple"
        case .plan: return "indigo"
        case .error: return "red"
        }
    }
}

