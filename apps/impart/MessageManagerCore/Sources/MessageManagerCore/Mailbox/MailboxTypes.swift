//
//  MailboxTypes.swift
//  MessageManagerCore
//
//  Email mailbox/folder models.
//

import Foundation
import ImpartRustCore

// MARK: - Mailbox

/// Email mailbox (folder).
public struct Mailbox: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let accountId: UUID
    public let name: String
    public let fullPath: String
    public let role: MailboxRole
    public let delimiter: String
    public let messageCount: Int
    public let unreadCount: Int
    public let isSubscribed: Bool
    public let canSelect: Bool

    public init(
        id: UUID = UUID(),
        accountId: UUID,
        name: String,
        fullPath: String? = nil,
        role: MailboxRole = .custom,
        delimiter: String = "/",
        messageCount: Int = 0,
        unreadCount: Int = 0,
        isSubscribed: Bool = true,
        canSelect: Bool = true
    ) {
        self.id = id
        self.accountId = accountId
        self.name = name
        self.fullPath = fullPath ?? name
        self.role = role
        self.delimiter = delimiter
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.isSubscribed = isSubscribed
        self.canSelect = canSelect
    }

    /// Create from Rust mailbox type.
    public init(from rustMailbox: RustMailbox, accountId: UUID) {
        self.id = UUID()
        self.accountId = accountId
        self.name = rustMailbox.name.components(separatedBy: rustMailbox.delimiter).last ?? rustMailbox.name
        self.fullPath = rustMailbox.name
        self.role = MailboxRole.detect(from: rustMailbox.name, flags: rustMailbox.flags)
        self.delimiter = rustMailbox.delimiter
        self.messageCount = Int(rustMailbox.messageCount)
        self.unreadCount = Int(rustMailbox.unseenCount)
        self.isSubscribed = !rustMailbox.flags.contains("\\Noselect")
        self.canSelect = !rustMailbox.flags.contains("\\Noselect")
    }

    /// SF Symbol for the mailbox type.
    public var iconName: String {
        role.iconName
    }

    /// Whether this is a system mailbox.
    public var isSystemMailbox: Bool {
        role != .custom
    }
}

// MARK: - Mailbox Role

/// Standard mailbox roles (RFC 6154).
public enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox = "inbox"
    case drafts = "drafts"
    case sent = "sent"
    case archive = "archive"
    case trash = "trash"
    case spam = "spam"
    case allMail = "all"
    case starred = "starred"
    case custom = "custom"

    /// Detect role from mailbox name and IMAP flags.
    public static func detect(from name: String, flags: [String] = []) -> MailboxRole {
        // Check IMAP special-use flags first (RFC 6154)
        for flag in flags {
            switch flag.lowercased() {
            case "\\inbox": return .inbox
            case "\\drafts": return .drafts
            case "\\sent": return .sent
            case "\\archive": return .archive
            case "\\trash": return .trash
            case "\\junk": return .spam
            case "\\all": return .allMail
            case "\\flagged": return .starred
            default: continue
            }
        }

        // Fall back to name matching
        let lowercased = name.lowercased()
        switch lowercased {
        case "inbox": return .inbox
        case "drafts", "[gmail]/drafts": return .drafts
        case "sent", "sent mail", "sent items", "[gmail]/sent mail": return .sent
        case "archive", "[gmail]/all mail": return .archive
        case "trash", "deleted items", "[gmail]/trash": return .trash
        case "spam", "junk", "junk mail", "[gmail]/spam": return .spam
        case "starred", "[gmail]/starred": return .starred
        default: return .custom
        }
    }

    /// SF Symbol for the mailbox role.
    public var iconName: String {
        switch self {
        case .inbox: return "tray.fill"
        case .drafts: return "doc.fill"
        case .sent: return "paperplane.fill"
        case .archive: return "archivebox.fill"
        case .trash: return "trash.fill"
        case .spam: return "exclamationmark.shield.fill"
        case .allMail: return "tray.full.fill"
        case .starred: return "star.fill"
        case .custom: return "folder.fill"
        }
    }

    /// Display name for the role.
    public var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .drafts: return "Drafts"
        case .sent: return "Sent"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .spam: return "Spam"
        case .allMail: return "All Mail"
        case .starred: return "Starred"
        case .custom: return "Folder"
        }
    }

    /// Sort order for displaying system mailboxes.
    public var sortOrder: Int {
        switch self {
        case .inbox: return 0
        case .starred: return 1
        case .drafts: return 2
        case .sent: return 3
        case .archive: return 4
        case .spam: return 5
        case .trash: return 6
        case .allMail: return 7
        case .custom: return 100
        }
    }
}

// MARK: - Mailbox Tree

/// Hierarchical mailbox structure.
public struct MailboxNode: Identifiable, Sendable {
    public let id: UUID
    public let mailbox: Mailbox
    public var children: [MailboxNode]

    public init(mailbox: Mailbox, children: [MailboxNode] = []) {
        self.id = mailbox.id
        self.mailbox = mailbox
        self.children = children
    }

    /// Build tree from flat list of mailboxes.
    public static func buildTree(from mailboxes: [Mailbox]) -> [MailboxNode] {
        // Group by parent path
        var nodesByPath: [String: MailboxNode] = [:]
        var roots: [MailboxNode] = []

        // Sort by path length to process parents before children
        let sorted = mailboxes.sorted { $0.fullPath.count < $1.fullPath.count }

        for mailbox in sorted {
            let node = MailboxNode(mailbox: mailbox)
            nodesByPath[mailbox.fullPath] = node

            // Find parent
            let components = mailbox.fullPath.components(separatedBy: mailbox.delimiter)
            if components.count > 1 {
                let parentPath = components.dropLast().joined(separator: mailbox.delimiter)
                if var parent = nodesByPath[parentPath] {
                    parent.children.append(node)
                    nodesByPath[parentPath] = parent
                } else {
                    roots.append(node)
                }
            } else {
                roots.append(node)
            }
        }

        // Sort roots by role, then name
        return roots.sorted { lhs, rhs in
            if lhs.mailbox.role.sortOrder != rhs.mailbox.role.sortOrder {
                return lhs.mailbox.role.sortOrder < rhs.mailbox.role.sortOrder
            }
            return lhs.mailbox.name.localizedCaseInsensitiveCompare(rhs.mailbox.name) == .orderedAscending
        }
    }
}
