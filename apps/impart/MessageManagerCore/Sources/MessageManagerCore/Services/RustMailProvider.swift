//
//  RustMailProvider.swift
//  MessageManagerCore
//
//  MailProvider implementation using Rust IMAP/SMTP clients.
//

import Foundation
import ImpartRustCore

// MARK: - Rust Mail Provider

/// MailProvider implementation backed by Rust IMAP/SMTP clients.
public actor RustMailProvider: MailProvider {
    private let config: Account
    private var isConnected = false
    private let keychainService: KeychainService

    public init(account: Account, keychainService: KeychainService = .shared) {
        self.config = account
        self.keychainService = keychainService
    }

    // MARK: - Connection

    public func connect() async throws {
        guard !isConnected else { return }

        // Validate we have credentials
        guard keychainService.hasPassword(for: config.id) else {
            throw MailProviderError.authenticationFailed
        }

        // In a full implementation, this would create the Rust IMAP client
        // let password = try keychainService.getPassword(for: config.id)
        // let rustConfig = makeRustConfig()
        // imapClient = try FfiImapClient(config: rustConfig, password: password)

        isConnected = true
    }

    public func disconnect() async {
        // In a full implementation, disconnect from IMAP server
        // imapClient?.disconnect()
        isConnected = false
    }

    // MARK: - Mailboxes

    public func fetchMailboxes() async throws -> [Mailbox] {
        guard isConnected else {
            throw MailProviderError.notConnected
        }

        // In a full implementation, this would call Rust FFI:
        // let rustMailboxes = try imapClient.listMailboxes()
        // return rustMailboxes.map { Mailbox(from: $0, accountId: config.id) }

        // Return placeholder data
        return [
            Mailbox(
                accountId: config.id,
                name: "INBOX",
                fullPath: "INBOX",
                role: .inbox
            ),
            Mailbox(
                accountId: config.id,
                name: "Sent",
                fullPath: "[Gmail]/Sent Mail",
                role: .sent
            ),
            Mailbox(
                accountId: config.id,
                name: "Drafts",
                fullPath: "[Gmail]/Drafts",
                role: .drafts
            ),
            Mailbox(
                accountId: config.id,
                name: "Trash",
                fullPath: "[Gmail]/Trash",
                role: .trash
            )
        ]
    }

    // MARK: - Messages

    public func fetchMessages(mailbox: Mailbox, range: MessageRange) async throws -> [Message] {
        guard isConnected else {
            throw MailProviderError.notConnected
        }

        // In a full implementation:
        // let envelopes = try imapClient.fetchEnvelopes(
        //     mailboxName: mailbox.fullPath,
        //     start: range.start,
        //     count: range.count
        // )
        // return envelopes.map { $0.toSwiftMessage(accountId: config.id, mailboxId: mailbox.id) }

        // Return empty for now
        return []
    }

    public func fetchMessageContent(id: UUID) async throws -> MessageContent {
        guard isConnected else {
            throw MailProviderError.notConnected
        }

        // In a full implementation:
        // let parsed = try imapClient.fetchMessage(mailboxName: mailbox.fullPath, uid: uid)
        // return MessageContent(from: parsed)

        throw MailProviderError.notImplemented
    }

    // MARK: - Actions

    public func send(_ draft: DraftMessage) async throws {
        let password = try keychainService.getPassword(for: config.id)

        // In a full implementation:
        // let rustConfig = makeRustConfig()
        // let smtp = try FfiSmtpClient(config: rustConfig, password: password)
        // let ffiDraft = FfiDraftMessage(from: draft, fromEmail: config.email)
        // try smtp.send(draft: ffiDraft)
        // smtp.disconnect()

        // For now, just validate the draft
        guard !draft.to.isEmpty else {
            throw MailProviderError.invalidDraft("No recipients")
        }
        guard !draft.subject.isEmpty else {
            throw MailProviderError.invalidDraft("No subject")
        }

        // Pretend to send
        _ = password
    }

    public func setRead(_ messageIds: [UUID], read: Bool) async throws {
        guard isConnected else {
            throw MailProviderError.notConnected
        }

        // In a full implementation, set \Seen flag via IMAP
        throw MailProviderError.notImplemented
    }

    public func move(_ messageIds: [UUID], to mailbox: Mailbox) async throws {
        guard isConnected else {
            throw MailProviderError.notConnected
        }

        // In a full implementation, move via IMAP
        throw MailProviderError.notImplemented
    }

    public func delete(_ messageIds: [UUID]) async throws {
        guard isConnected else {
            throw MailProviderError.notConnected
        }

        // In a full implementation, move to trash or permanently delete
        throw MailProviderError.notImplemented
    }

    // MARK: - Helpers

    private func makeRustConfig() -> RustAccountConfig {
        RustAccountConfig(
            id: config.id.uuidString,
            email: config.email,
            displayName: config.displayName,
            imapHost: config.imapSettings.host,
            imapPort: config.imapSettings.port,
            smtpHost: config.smtpSettings.host,
            smtpPort: config.smtpSettings.port,
            imapTls: config.imapSettings.security == .tls,
            smtpStarttls: config.smtpSettings.security == .starttls
        )
    }
}

// MARK: - Errors

public enum MailProviderError: LocalizedError {
    case notConnected
    case notImplemented
    case authenticationFailed
    case invalidDraft(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to mail server"
        case .notImplemented:
            return "Feature not yet implemented"
        case .authenticationFailed:
            return "Authentication failed"
        case .invalidDraft(let reason):
            return "Invalid draft: \(reason)"
        }
    }
}

// MARK: - Rust Config Bridge

/// Bridge type matching Rust AccountConfig.
struct RustAccountConfig {
    let id: String
    let email: String
    let displayName: String
    let imapHost: String
    let imapPort: UInt16
    let smtpHost: String
    let smtpPort: UInt16
    let imapTls: Bool
    let smtpStarttls: Bool
}
