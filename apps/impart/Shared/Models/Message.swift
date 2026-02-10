//
//  Message.swift
//  impart (Shared)
//
//  Shared message display model for cross-platform UI.
//

import Foundation
import MessageManagerCore
import ImpressMailStyle

// MARK: - Display Message

/// Lightweight message model for display in lists.
/// This is used by the shared MessageRow view.
public struct DisplayMessage: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let from: String
    public let to: String
    public let subject: String
    public let snippet: String
    public let date: Date
    public let isRead: Bool
    public let isStarred: Bool
    public let hasAttachments: Bool
    public let attachmentCount: Int
    public let threadCount: Int

    public init(
        id: UUID = UUID(),
        from: String,
        to: String = "",
        subject: String,
        snippet: String = "",
        date: Date = Date(),
        isRead: Bool = false,
        isStarred: Bool = false,
        hasAttachments: Bool = false,
        attachmentCount: Int = 0,
        threadCount: Int = 1
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.isRead = isRead
        self.isStarred = isStarred
        self.hasAttachments = hasAttachments
        self.attachmentCount = attachmentCount
        self.threadCount = threadCount
    }

    /// Formatted date string for display (delegates to MailStyleTokens).
    public var displayDate: String {
        MailStyleTokens.formatRelativeDate(date)
    }

    /// Whether this represents a thread with multiple messages.
    public var isThread: Bool {
        threadCount > 1
    }
}

// MARK: - MailStyleItem Conformance

extension DisplayMessage: MailStyleItem {
    public var headerText: String { from }
    public var titleText: String { subject }
    public var previewText: String? { snippet.isEmpty ? nil : snippet }
    public var trailingBadgeText: String? { threadCount > 1 ? "(\(threadCount))" : nil }
    public var hasAttachment: Bool { hasAttachments }
}

// MARK: - Conversion from MessageManagerCore.Message

extension DisplayMessage {
    /// Create from MessageManagerCore Message.
    public init(from message: Message) {
        self.init(
            id: message.id,
            from: message.fromDisplayString,
            to: message.to.map(\.displayString).joined(separator: ", "),
            subject: message.subject,
            snippet: message.snippet,
            date: message.date,
            isRead: message.isRead,
            isStarred: message.isStarred,
            hasAttachments: message.hasAttachments,
            attachmentCount: 0,
            threadCount: 1
        )
    }
}

// MARK: - Sample Data

extension DisplayMessage {
    /// Sample messages for previews.
    public static var samples: [DisplayMessage] {
        [
            DisplayMessage(
                from: "Alice Smith",
                subject: "Project update",
                snippet: "Hi, just wanted to give you a quick update on the project progress...",
                date: Date().addingTimeInterval(-3600),
                isRead: false,
                hasAttachments: true,
                attachmentCount: 2
            ),
            DisplayMessage(
                from: "Bob Johnson",
                subject: "Re: Meeting tomorrow",
                snippet: "That time works for me. See you then!",
                date: Date().addingTimeInterval(-7200),
                isRead: true,
                threadCount: 5
            ),
            DisplayMessage(
                from: "Carol Williams",
                subject: "Paper submission deadline",
                snippet: "Reminder: The deadline for the paper submission is next Friday...",
                date: Date().addingTimeInterval(-86400),
                isRead: false,
                isStarred: true
            ),
            DisplayMessage(
                from: "arXiv.org",
                subject: "Daily arXiv digest",
                snippet: "New submissions in cs.AI, cs.LG, and related subjects...",
                date: Date().addingTimeInterval(-172800),
                isRead: true
            )
        ]
    }
}
