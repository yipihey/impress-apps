//
//  Errors.swift
//  MessageManagerCore
//
//  Domain errors for impart message management.
//

import Foundation

// MARK: - Account Errors

/// Errors related to email account operations.
public enum AccountError: LocalizedError {
    case invalidCredentials
    case connectionFailed(underlying: Error)
    case authenticationFailed(reason: String)
    case accountNotFound(id: UUID)
    case duplicateAccount(email: String)
    case keychainError(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .accountNotFound(let id):
            return "Account not found: \(id)"
        case .duplicateAccount(let email):
            return "Account already exists for \(email)"
        case .keychainError(let error):
            return "Keychain error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Mailbox Errors

/// Errors related to mailbox operations.
public enum MailboxError: LocalizedError {
    case mailboxNotFound(name: String)
    case syncFailed(mailbox: String, underlying: Error)
    case createFailed(name: String, underlying: Error)
    case deleteFailed(name: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .mailboxNotFound(let name):
            return "Mailbox not found: \(name)"
        case .syncFailed(let mailbox, let error):
            return "Failed to sync \(mailbox): \(error.localizedDescription)"
        case .createFailed(let name, let error):
            return "Failed to create mailbox \(name): \(error.localizedDescription)"
        case .deleteFailed(let name, let error):
            return "Failed to delete mailbox \(name): \(error.localizedDescription)"
        }
    }
}

// MARK: - Message Errors

/// Errors related to message operations.
public enum MessageError: LocalizedError {
    case messageNotFound(id: UUID)
    case fetchFailed(underlying: Error)
    case sendFailed(underlying: Error)
    case parseFailed(reason: String)
    case attachmentTooLarge(size: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .messageNotFound(let id):
            return "Message not found: \(id)"
        case .fetchFailed(let error):
            return "Failed to fetch message: \(error.localizedDescription)"
        case .sendFailed(let error):
            return "Failed to send message: \(error.localizedDescription)"
        case .parseFailed(let reason):
            return "Failed to parse message: \(reason)"
        case .attachmentTooLarge(let size, let limit):
            return "Attachment too large: \(size) bytes exceeds \(limit) byte limit"
        }
    }
}

// MARK: - Sync Errors

/// Errors related to synchronization.
public enum SyncError: LocalizedError {
    case notConnected
    case syncInProgress
    case conflictDetected(local: Date, remote: Date)
    case quotaExceeded
    case accountNotFound
    case folderNotFound
    case syncFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        case .syncInProgress:
            return "Sync already in progress"
        case .conflictDetected(let local, let remote):
            return "Sync conflict: local modified at \(local), remote at \(remote)"
        case .quotaExceeded:
            return "Storage quota exceeded"
        case .accountNotFound:
            return "Account not found"
        case .folderNotFound:
            return "Folder not found"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        }
    }
}
