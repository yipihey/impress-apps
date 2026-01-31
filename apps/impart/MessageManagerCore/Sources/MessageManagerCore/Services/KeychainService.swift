//
//  KeychainService.swift
//  MessageManagerCore
//
//  Secure credential storage using Keychain.
//

import Foundation
import KeychainSwift

// MARK: - Keychain Service

/// Service for securely storing email account credentials.
public final class KeychainService: Sendable {
    public static let shared = KeychainService()

    private let keychain: KeychainSwift
    private let prefix = "com.impress.impart."

    public init() {
        let kc = KeychainSwift()
        kc.synchronizable = false
        self.keychain = kc
    }

    /// Store password for an account.
    public func setPassword(_ password: String, for accountId: UUID) throws {
        let key = prefix + accountId.uuidString
        guard keychain.set(password, forKey: key) else {
            throw KeychainError.saveFailed
        }
    }

    /// Retrieve password for an account.
    public func getPassword(for accountId: UUID) throws -> String {
        let key = prefix + accountId.uuidString
        guard let password = keychain.get(key) else {
            throw KeychainError.notFound
        }
        return password
    }

    /// Delete password for an account.
    public func deletePassword(for accountId: UUID) {
        let key = prefix + accountId.uuidString
        keychain.delete(key)
    }

    /// Check if password exists for an account.
    public func hasPassword(for accountId: UUID) -> Bool {
        let key = prefix + accountId.uuidString
        return keychain.get(key) != nil
    }
}

// MARK: - Errors

public enum KeychainError: LocalizedError {
    case saveFailed
    case notFound

    public var errorDescription: String? {
        switch self {
        case .saveFailed:
            return "Failed to save to Keychain"
        case .notFound:
            return "Credential not found in Keychain"
        }
    }
}
