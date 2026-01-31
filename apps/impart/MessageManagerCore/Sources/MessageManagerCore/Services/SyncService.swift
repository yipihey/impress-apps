//
//  SyncService.swift
//  MessageManagerCore
//
//  Synchronizes messages between server and local Core Data store.
//

import Foundation
import CoreData
import OSLog

private let syncLogger = Logger(subsystem: "com.impress.impart", category: "sync")

// MARK: - Sync Service

/// Service for synchronizing email between server and local storage.
public actor SyncService {
    private let persistence: PersistenceController
    private var providers: [UUID: RustMailProvider] = [:]

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - Provider Management

    /// Get or create a mail provider for an account.
    public func provider(for account: Account) -> RustMailProvider {
        if let existing = providers[account.id] {
            return existing
        }
        let provider = RustMailProvider(account: account)
        providers[account.id] = provider
        return provider
    }

    /// Remove provider for an account.
    public func removeProvider(for accountId: UUID) {
        providers.removeValue(forKey: accountId)
    }

    // MARK: - Sync Operations

    /// Sync all mailboxes for an account.
    public func syncMailboxes(for account: Account) async throws -> [Mailbox] {
        let provider = provider(for: account)
        try await provider.connect()
        defer { Task { await provider.disconnect() } }

        let mailboxes = try await provider.fetchMailboxes()

        // Save to Core Data
        try await persistence.performBackgroundTask { context in
            let fetchRequest = CDAccount.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "email == %@", account.email)

            guard let cdAccount = try context.fetch(fetchRequest).first else {
                throw SyncError.accountNotFound
            }

            // Clear existing folders and recreate
            if let existingFolders = cdAccount.folders {
                for folder in existingFolders {
                    context.delete(folder)
                }
            }

            for mailbox in mailboxes {
                let cdFolder = CDFolder(context: context)
                cdFolder.id = mailbox.id
                cdFolder.name = mailbox.name
                cdFolder.fullPath = mailbox.fullPath
                cdFolder.messageCount = Int32(mailbox.messageCount)
                cdFolder.unreadCount = Int32(mailbox.unreadCount)
                cdFolder.account = cdAccount
                cdFolder.roleRaw = mailbox.role.rawValue
            }

            try context.save()
        }

        syncLogger.info("Synced \(mailboxes.count) mailboxes for \(account.email)")
        return mailboxes
    }

    /// Sync messages from a mailbox.
    public func syncMessages(
        for account: Account,
        mailbox: Mailbox,
        range: MessageRange = .firstPage
    ) async throws -> [Message] {
        let provider = provider(for: account)
        try await provider.connect()
        defer { Task { await provider.disconnect() } }

        let messages = try await provider.fetchMessages(mailbox: mailbox, range: range)

        // Save to Core Data
        try await persistence.performBackgroundTask { context in
            let folderRequest = CDFolder.fetchRequest()
            folderRequest.predicate = NSPredicate(
                format: "fullPath == %@ AND account.email == %@",
                mailbox.fullPath,
                account.email
            )

            guard let cdFolder = try context.fetch(folderRequest).first else {
                throw SyncError.folderNotFound
            }

            for message in messages {
                // Check if message already exists
                let existingRequest = CDMessage.fetchRequest()
                existingRequest.predicate = NSPredicate(
                    format: "uid == %d AND folder == %@",
                    message.uid,
                    cdFolder
                )

                let cdMessage: CDMessage
                if let existing = try context.fetch(existingRequest).first {
                    cdMessage = existing
                } else {
                    cdMessage = CDMessage(context: context)
                    cdMessage.id = message.id
                }

                cdMessage.uid = Int32(message.uid)
                cdMessage.messageId = message.messageId
                cdMessage.inReplyTo = message.inReplyTo
                cdMessage.subject = message.subject
                cdMessage.snippet = message.snippet
                cdMessage.date = message.date
                cdMessage.receivedDate = message.receivedDate
                cdMessage.isRead = message.isRead
                cdMessage.isStarred = message.isStarred
                cdMessage.hasAttachments = message.hasAttachments
                cdMessage.folder = cdFolder

                // Encode addresses
                cdMessage.fromJSON = encodeAddresses(message.from)
                cdMessage.toJSON = encodeAddresses(message.to)
                cdMessage.ccJSON = encodeAddresses(message.cc)
                cdMessage.bccJSON = encodeAddresses(message.bcc)

                // Encode references
                if let data = try? JSONEncoder().encode(message.references),
                   let json = String(data: data, encoding: .utf8) {
                    cdMessage.referencesJSON = json
                }
            }

            try context.save()
        }

        syncLogger.info("Synced \(messages.count) messages from \(mailbox.name)")
        return messages
    }

    /// Send a message.
    public func send(_ draft: DraftMessage, from account: Account) async throws {
        let provider = provider(for: account)
        try await provider.send(draft)
        syncLogger.info("Sent message: \(draft.subject)")
    }

    /// Mark messages as read.
    public func markAsRead(_ messageIds: [UUID], read: Bool, for account: Account) async throws {
        let provider = provider(for: account)
        try await provider.connect()
        defer { Task { await provider.disconnect() } }

        try await provider.setRead(messageIds, read: read)

        // Update local store
        try await persistence.performBackgroundTask { context in
            let request = CDMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", messageIds)

            let messages = try context.fetch(request)
            for message in messages {
                message.isRead = read
            }

            try context.save()
        }

        syncLogger.info("Marked \(messageIds.count) messages as \(read ? "read" : "unread")")
    }

    // MARK: - Helpers

    private func encodeAddresses(_ addresses: [EmailAddress]) -> String {
        guard let data = try? JSONEncoder().encode(addresses),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

// MARK: - Sync Errors

public enum SyncError: LocalizedError {
    case accountNotFound
    case folderNotFound
    case syncFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "Account not found"
        case .folderNotFound:
            return "Folder not found"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        }
    }
}

// MARK: - CDAccount Fetch Request

extension CDAccount {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDAccount> {
        NSFetchRequest<CDAccount>(entityName: "CDAccount")
    }
}

extension CDFolder {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDFolder> {
        NSFetchRequest<CDFolder>(entityName: "CDFolder")
    }
}

extension CDMessage {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDMessage> {
        NSFetchRequest<CDMessage>(entityName: "CDMessage")
    }
}
