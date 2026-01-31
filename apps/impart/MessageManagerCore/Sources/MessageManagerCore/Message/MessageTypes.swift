//
//  MessageTypes.swift
//  MessageManagerCore
//
//  Email message models and related types.
//

import Foundation
import ImpartRustCore

// MARK: - Message

/// Email message for display.
public struct Message: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let accountId: UUID
    public let mailboxId: UUID
    public let uid: UInt32
    public let messageId: String?
    public let inReplyTo: String?
    public let references: [String]
    public let subject: String
    public let from: [EmailAddress]
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]
    public let date: Date
    public let receivedDate: Date
    public let snippet: String
    public let isRead: Bool
    public let isStarred: Bool
    public let hasAttachments: Bool
    public let labels: [String]

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        mailboxId: UUID,
        uid: UInt32,
        messageId: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String,
        from: [EmailAddress],
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        date: Date,
        receivedDate: Date = Date(),
        snippet: String = "",
        isRead: Bool = false,
        isStarred: Bool = false,
        hasAttachments: Bool = false,
        labels: [String] = []
    ) {
        self.id = id
        self.accountId = accountId
        self.mailboxId = mailboxId
        self.uid = uid
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.date = date
        self.receivedDate = receivedDate
        self.snippet = snippet
        self.isRead = isRead
        self.isStarred = isStarred
        self.hasAttachments = hasAttachments
        self.labels = labels
    }

    /// Display string for From field.
    public var fromDisplayString: String {
        from.first?.displayString ?? "Unknown"
    }

    /// Short display date (relative for recent, absolute otherwise).
    public var displayDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Email Address

/// Email address with optional display name.
public struct EmailAddress: Codable, Sendable, Hashable {
    public let name: String?
    public let email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }

    public init(from rustAddress: RustAddress) {
        self.name = rustAddress.name
        self.email = rustAddress.email
    }

    public var displayString: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return email
    }

    public var fullDisplayString: String {
        if let name = name, !name.isEmpty {
            return "\(name) <\(email)>"
        }
        return email
    }
}

// MARK: - Message Content

/// Full message content including body and attachments.
public struct MessageContent: Sendable {
    public let messageId: UUID
    public let textBody: String?
    public let htmlBody: String?
    public let attachments: [Attachment]

    public init(
        messageId: UUID,
        textBody: String? = nil,
        htmlBody: String? = nil,
        attachments: [Attachment] = []
    ) {
        self.messageId = messageId
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
    }

    /// Preferred body for display (HTML if available, otherwise text).
    public var preferredBody: String? {
        htmlBody ?? textBody
    }

    /// Plain text body (stripped HTML if only HTML available).
    public var plainTextBody: String? {
        if let text = textBody {
            return text
        }
        // TODO: Strip HTML tags from htmlBody
        return htmlBody
    }
}

// MARK: - Attachment

/// Email attachment.
public struct Attachment: Identifiable, Sendable {
    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let size: Int
    public let contentId: String?
    public let isInline: Bool

    public init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        size: Int,
        contentId: String? = nil,
        isInline: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentId = contentId
        self.isInline = isInline
    }

    /// Human-readable file size.
    public var displaySize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    /// SF Symbol name for the file type.
    public var iconName: String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":
            return "doc.fill"
        case "doc", "docx":
            return "doc.text.fill"
        case "xls", "xlsx":
            return "tablecells.fill"
        case "ppt", "pptx":
            return "slider.horizontal.below.rectangle"
        case "jpg", "jpeg", "png", "gif", "heic":
            return "photo.fill"
        case "mp3", "wav", "aac":
            return "waveform"
        case "mp4", "mov", "avi":
            return "play.rectangle.fill"
        case "zip", "tar", "gz":
            return "doc.zipper"
        default:
            return "paperclip"
        }
    }
}

// MARK: - Draft Message

/// Message being composed.
public struct DraftMessage: Identifiable, Sendable {
    public let id: UUID
    public var accountId: UUID
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var body: String
    public var isHTML: Bool
    public var attachments: [DraftAttachment]
    public var inReplyTo: String?
    public var references: [String]

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String = "",
        body: String = "",
        isHTML: Bool = false,
        attachments: [DraftAttachment] = [],
        inReplyTo: String? = nil,
        references: [String] = []
    ) {
        self.id = id
        self.accountId = accountId
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.isHTML = isHTML
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// Create a reply to another message.
    public static func reply(to message: Message, accountId: UUID, content: MessageContent? = nil) -> DraftMessage {
        var refs = message.references
        if let messageId = message.messageId {
            refs.append(messageId)
        }

        let quotedBody: String
        if let textBody = content?.textBody {
            let lines = textBody.components(separatedBy: .newlines)
            quotedBody = lines.map { "> \($0)" }.joined(separator: "\n")
        } else {
            quotedBody = ""
        }

        let replySubject = message.subject.hasPrefix("Re: ") ? message.subject : "Re: \(message.subject)"

        return DraftMessage(
            accountId: accountId,
            to: message.from,
            subject: replySubject,
            body: "\n\n\(quotedBody)",
            inReplyTo: message.messageId,
            references: refs
        )
    }

    /// Create a forward of another message.
    public static func forward(message: Message, accountId: UUID, content: MessageContent? = nil) -> DraftMessage {
        let forwardHeader = """
        ---------- Forwarded message ----------
        From: \(message.from.map(\.fullDisplayString).joined(separator: ", "))
        Date: \(message.date)
        Subject: \(message.subject)
        To: \(message.to.map(\.fullDisplayString).joined(separator: ", "))

        """

        let forwardBody = forwardHeader + (content?.plainTextBody ?? "")
        let forwardSubject = message.subject.hasPrefix("Fwd: ") ? message.subject : "Fwd: \(message.subject)"

        return DraftMessage(
            accountId: accountId,
            subject: forwardSubject,
            body: forwardBody
        )
    }
}

/// Attachment in a draft message.
public struct DraftAttachment: Identifiable, Sendable {
    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

// MARK: - Message Range

/// Range of messages to fetch.
public struct MessageRange: Sendable {
    public let start: UInt32
    public let count: UInt32

    public init(start: UInt32, count: UInt32) {
        self.start = start
        self.count = count
    }

    /// First page of messages.
    public static let firstPage = MessageRange(start: 1, count: 50)

    /// Next page after current.
    public func nextPage() -> MessageRange {
        MessageRange(start: start + count, count: count)
    }
}

// MARK: - Thread

/// Conversation thread containing related messages.
public struct Thread: Identifiable, Sendable {
    public let id: UUID
    public let subject: String
    public let participants: [EmailAddress]
    public let messageCount: Int
    public let unreadCount: Int
    public let latestDate: Date
    public let snippet: String
    public let messageIds: [UUID]

    public init(
        id: UUID = UUID(),
        subject: String,
        participants: [EmailAddress],
        messageCount: Int,
        unreadCount: Int,
        latestDate: Date,
        snippet: String,
        messageIds: [UUID]
    ) {
        self.id = id
        self.subject = subject
        self.participants = participants
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.latestDate = latestDate
        self.snippet = snippet
        self.messageIds = messageIds
    }

    /// Display string for participants.
    public var participantsDisplayString: String {
        participants.prefix(3).map(\.displayString).joined(separator: ", ")
    }

    /// Whether the thread has unread messages.
    public var hasUnread: Bool {
        unreadCount > 0
    }
}
