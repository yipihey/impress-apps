//
//  AccountTypes.swift
//  MessageManagerCore
//
//  Email account models and configuration types.
//

import Foundation

// MARK: - Account Protocol

/// Protocol for email account providers.
public protocol MailProvider: Sendable {
    /// Connect to the mail server.
    func connect() async throws

    /// Disconnect from the mail server.
    func disconnect() async

    /// Fetch list of mailboxes.
    func fetchMailboxes() async throws -> [Mailbox]

    /// Fetch messages from a mailbox.
    func fetchMessages(mailbox: Mailbox, range: MessageRange) async throws -> [Message]

    /// Fetch full message content.
    func fetchMessageContent(id: UUID) async throws -> MessageContent

    /// Send a message.
    func send(_ draft: DraftMessage) async throws

    /// Mark messages as read/unread.
    func setRead(_ messageIds: [UUID], read: Bool) async throws

    /// Move messages to another mailbox.
    func move(_ messageIds: [UUID], to mailbox: Mailbox) async throws

    /// Delete messages.
    func delete(_ messageIds: [UUID]) async throws
}

// MARK: - Account Configuration

/// Email account configuration.
public struct Account: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var email: String
    public var displayName: String
    public var imapSettings: IMAPSettings
    public var smtpSettings: SMTPSettings
    public var isEnabled: Bool
    public var lastSyncDate: Date?
    public var signature: String?

    public init(
        id: UUID = UUID(),
        email: String,
        displayName: String = "",
        imapSettings: IMAPSettings,
        smtpSettings: SMTPSettings,
        isEnabled: Bool = true,
        lastSyncDate: Date? = nil,
        signature: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName.isEmpty ? email : displayName
        self.imapSettings = imapSettings
        self.smtpSettings = smtpSettings
        self.isEnabled = isEnabled
        self.lastSyncDate = lastSyncDate
        self.signature = signature
    }
}

// MARK: - IMAP Settings

/// IMAP server configuration.
public struct IMAPSettings: Codable, Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var security: ConnectionSecurity
    public var username: String

    public init(
        host: String,
        port: UInt16 = 993,
        security: ConnectionSecurity = .tls,
        username: String
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }

    /// Common IMAP presets
    public static func gmail(email: String) -> IMAPSettings {
        IMAPSettings(host: "imap.gmail.com", port: 993, security: .tls, username: email)
    }

    public static func outlook(email: String) -> IMAPSettings {
        IMAPSettings(host: "outlook.office365.com", port: 993, security: .tls, username: email)
    }

    public static func icloud(email: String) -> IMAPSettings {
        IMAPSettings(host: "imap.mail.me.com", port: 993, security: .tls, username: email)
    }

    public static func fastmail(email: String) -> IMAPSettings {
        IMAPSettings(host: "imap.fastmail.com", port: 993, security: .tls, username: email)
    }
}

// MARK: - SMTP Settings

/// SMTP server configuration.
public struct SMTPSettings: Codable, Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var security: ConnectionSecurity
    public var username: String

    public init(
        host: String,
        port: UInt16 = 587,
        security: ConnectionSecurity = .starttls,
        username: String
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }

    /// Common SMTP presets
    public static func gmail(email: String) -> SMTPSettings {
        SMTPSettings(host: "smtp.gmail.com", port: 587, security: .starttls, username: email)
    }

    public static func outlook(email: String) -> SMTPSettings {
        SMTPSettings(host: "smtp.office365.com", port: 587, security: .starttls, username: email)
    }

    public static func icloud(email: String) -> SMTPSettings {
        SMTPSettings(host: "smtp.mail.me.com", port: 587, security: .starttls, username: email)
    }

    public static func fastmail(email: String) -> SMTPSettings {
        SMTPSettings(host: "smtp.fastmail.com", port: 587, security: .starttls, username: email)
    }
}

// MARK: - Connection Security

/// Connection security mode.
public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    case none = "none"
    case starttls = "starttls"
    case tls = "tls"

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .starttls: return "STARTTLS"
        case .tls: return "SSL/TLS"
        }
    }
}

// MARK: - Account Provider Detection

/// Detect provider from email domain.
public enum EmailProvider: String, CaseIterable {
    case gmail
    case outlook
    case icloud
    case fastmail
    case custom

    public static func detect(from email: String) -> EmailProvider {
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""

        switch domain {
        case "gmail.com", "googlemail.com":
            return .gmail
        case "outlook.com", "hotmail.com", "live.com", "msn.com":
            return .outlook
        case "icloud.com", "me.com", "mac.com":
            return .icloud
        case "fastmail.com", "fastmail.fm":
            return .fastmail
        default:
            return .custom
        }
    }

    public func defaultSettings(for email: String) -> (imap: IMAPSettings, smtp: SMTPSettings) {
        switch self {
        case .gmail:
            return (.gmail(email: email), .gmail(email: email))
        case .outlook:
            return (.outlook(email: email), .outlook(email: email))
        case .icloud:
            return (.icloud(email: email), .icloud(email: email))
        case .fastmail:
            return (.fastmail(email: email), .fastmail(email: email))
        case .custom:
            // User must provide settings
            return (
                IMAPSettings(host: "", username: email),
                SMTPSettings(host: "", username: email)
            )
        }
    }
}
