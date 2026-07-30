//
//  CredentialManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import ImpressKit
import KeychainSwift
import OSLog

// MARK: - Credential Providing Protocol

/// Protocol for credential providers, enabling dependency injection in tests.
public protocol CredentialProviding: Sendable {
    func apiKey(for sourceID: String) async -> String?
    func email(for sourceID: String) async -> String?
    func hasCredential(for sourceID: String, type: CredentialType) async -> Bool
}

// MARK: - Credential Manager

/// Manages API keys and other credentials stored in the Keychain.
public actor CredentialManager: CredentialProviding {

    // MARK: - Shared Instance

    /// Shared instance for app-wide credential management
    public static let shared = CredentialManager()

    // MARK: - Properties

    /// Lazily initialized keychain to defer access until actually needed.
    /// This prevents the "access data from other apps" dialog at startup.
    private var _keychain: KeychainSwift?
    private var keychain: KeychainSwift {
        if let k = _keychain { return k }
        let k = KeychainSwift()
        k.accessGroup = nil  // Use app's default keychain (works in sandbox)
        k.synchronizable = false  // Don't sync credentials to iCloud
        _keychain = k
        return k
    }
    private let keyPrefix: String

    // MARK: - Initialization

    public init(keyPrefix: String = "com.imbib.credentials") {
        self.keyPrefix = keyPrefix
        // Don't initialize keychain here - defer until first use
    }

    // MARK: - Reachability

    /// Can THIS process read the `com.imbib.credentials.*` items without
    /// prompting?
    ///
    /// The items are ACL'd to imbib's code signature, and there is no shared
    /// keychain access group in the suite. A differently-signed host that reads
    /// them pops a SecurityAgent password prompt, and the synchronous
    /// `SecItemCopyMatching` behind `KeychainSwift` blocks the caller's
    /// cooperative-pool thread until the user answers — the bug that hung
    /// impart's `/api/logs` (imbib CLAUDE.md invariant).
    ///
    /// ADR-0022 D9 named this as a decision impress had to make BEFORE its
    /// target existed: "either it ships with imbib's keychain access group or
    /// the read moves behind a reachability check". The target now exists and
    /// this is that check — the cheaper of the two, because a shared access
    /// group would require re-signing imbib AND migrating every already-stored
    /// item into the group (items written without one are not retroactively
    /// members).
    ///
    /// It is a REACHABILITY fact, not a policy: `AppShellConfiguration`'s
    /// `permits(.search)` still says which shells surface external search, and
    /// impress still permits it. impress renders the Search section; it just
    /// does not read credentials it provably cannot open. Sibling-app
    /// credential entry stays imbib's, which is where the user set it.
    public nonisolated static var itemsAreReadableWithoutPrompting: Bool {
        Bundle.main.bundleIdentifier == SiblingApp.imbib.bundleID
    }

    // MARK: - Storage

    /// Store a credential
    public func store(
        _ value: String,
        for sourceID: String,
        type: CredentialType
    ) async throws {
        Logger.credentials.entering()
        defer { Logger.credentials.exiting() }

        let key = makeKey(sourceID: sourceID, type: type)
        let success = keychain.set(value, forKey: key)

        if success {
            Logger.credentials.info("Stored \(type.rawValue) for \(sourceID)")
        } else {
            Logger.credentials.error("Failed to store \(type.rawValue) for \(sourceID)")
            throw CredentialError.storageFailed
        }
    }

    /// Store API key
    public func storeAPIKey(_ apiKey: String, for sourceID: String) async throws {
        try await store(apiKey, for: sourceID, type: .apiKey)
    }

    /// Store email
    public func storeEmail(_ email: String, for sourceID: String) async throws {
        try await store(email, for: sourceID, type: .email)
    }

    // MARK: - Retrieval

    /// Retrieve a credential
    public func retrieve(for sourceID: String, type: CredentialType) async -> String? {
        let key = makeKey(sourceID: sourceID, type: type)
        return keychain.get(key)
    }

    /// Retrieve API key
    public func apiKey(for sourceID: String) async -> String? {
        await retrieve(for: sourceID, type: .apiKey)
    }

    /// Retrieve email
    public func email(for sourceID: String) async -> String? {
        await retrieve(for: sourceID, type: .email)
    }

    /// Check if credential exists
    public func hasCredential(for sourceID: String, type: CredentialType) async -> Bool {
        await retrieve(for: sourceID, type: type) != nil
    }

    // MARK: - Deletion

    /// Delete a credential
    public func delete(for sourceID: String, type: CredentialType) async {
        Logger.credentials.info("Deleting \(type.rawValue) for \(sourceID)")
        let key = makeKey(sourceID: sourceID, type: type)
        keychain.delete(key)
    }

    /// Delete all credentials for a source
    public func deleteAll(for sourceID: String) async {
        Logger.credentials.info("Deleting all credentials for \(sourceID)")
        for type in CredentialType.allCases {
            await delete(for: sourceID, type: type)
        }
    }

    // MARK: - Validation

    /// Validate credential format (basic checks)
    public nonisolated func validate(_ value: String, type: CredentialType) -> Bool {
        switch type {
        case .apiKey:
            // API keys should be non-empty and reasonable length
            return !value.isEmpty && value.count >= 8 && value.count <= 256

        case .email:
            // Basic email validation
            let emailRegex = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
            return value.range(of: emailRegex, options: .regularExpression) != nil
        }
    }

    // MARK: - Private Helpers

    private func makeKey(sourceID: String, type: CredentialType) -> String {
        "\(keyPrefix).\(sourceID).\(type.keychainSuffix)"
    }
}
