//
//  MockCredentialManager.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import Foundation
@testable import PublicationManagerCore

/// Mock credential manager for testing without Keychain dependency.
public actor MockCredentialManager: CredentialProviding {

    // MARK: - Storage

    private var storage: [String: String] = [:]

    // MARK: - Call Tracking

    public private(set) var storeCallCount = 0
    public private(set) var retrieveCallCount = 0
    public private(set) var deleteCallCount = 0
    public private(set) var lastStoredSourceID: String?
    public private(set) var lastStoredType: CredentialType?
    public private(set) var lastStoredValue: String?

    // MARK: - Configuration

    /// Set to true to make store() throw an error
    public var shouldFailStorage = false

    // MARK: - Initialization

    public init() {}

    /// Initialize with pre-populated credentials
    public init(credentials: [String: [CredentialType: String]]) {
        for (sourceID, creds) in credentials {
            for (type, value) in creds {
                let key = makeKey(sourceID: sourceID, type: type)
                storage[key] = value
            }
        }
    }

    // MARK: - Storage Methods

    public func store(
        _ value: String,
        for sourceID: String,
        type: CredentialType
    ) async throws {
        storeCallCount += 1
        lastStoredSourceID = sourceID
        lastStoredType = type
        lastStoredValue = value

        if shouldFailStorage {
            throw CredentialError.storageFailed
        }

        let key = makeKey(sourceID: sourceID, type: type)
        storage[key] = value
    }

    public func storeAPIKey(_ apiKey: String, for sourceID: String) async throws {
        try await store(apiKey, for: sourceID, type: .apiKey)
    }

    public func storeEmail(_ email: String, for sourceID: String) async throws {
        try await store(email, for: sourceID, type: .email)
    }

    // MARK: - Retrieval Methods

    public func retrieve(for sourceID: String, type: CredentialType) async -> String? {
        retrieveCallCount += 1
        let key = makeKey(sourceID: sourceID, type: type)
        return storage[key]
    }

    public func apiKey(for sourceID: String) async -> String? {
        await retrieve(for: sourceID, type: .apiKey)
    }

    public func email(for sourceID: String) async -> String? {
        await retrieve(for: sourceID, type: .email)
    }

    public func hasCredential(for sourceID: String, type: CredentialType) async -> Bool {
        await retrieve(for: sourceID, type: type) != nil
    }

    // MARK: - Deletion Methods

    public func delete(for sourceID: String, type: CredentialType) async {
        deleteCallCount += 1
        let key = makeKey(sourceID: sourceID, type: type)
        storage.removeValue(forKey: key)
    }

    public func deleteAll(for sourceID: String) async {
        for type in CredentialType.allCases {
            await delete(for: sourceID, type: type)
        }
    }

    // MARK: - Validation (nonisolated to match real implementation)

    public nonisolated func validate(_ value: String, type: CredentialType) -> Bool {
        switch type {
        case .apiKey:
            return !value.isEmpty && value.count >= 8 && value.count <= 256
        case .email:
            let emailRegex = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
            return value.range(of: emailRegex, options: .regularExpression) != nil
        }
    }

    // MARK: - Test Helpers

    /// Reset all tracked state
    public func reset() {
        storage.removeAll()
        storeCallCount = 0
        retrieveCallCount = 0
        deleteCallCount = 0
        lastStoredSourceID = nil
        lastStoredType = nil
        lastStoredValue = nil
        shouldFailStorage = false
    }

    /// Get all stored credentials (for test verification)
    public var allCredentials: [String: String] {
        storage
    }

    // MARK: - Private Helpers

    private func makeKey(sourceID: String, type: CredentialType) -> String {
        "\(sourceID).\(type.keychainSuffix)"
    }
}
