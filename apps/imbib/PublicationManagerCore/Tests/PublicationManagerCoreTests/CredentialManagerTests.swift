//
//  CredentialManagerTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class CredentialManagerTests: XCTestCase {

    // MARK: - Properties

    private var credentialManager: CredentialManager!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        // Use unique prefix for test isolation
        credentialManager = CredentialManager(keyPrefix: "test.credentials.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        credentialManager = nil
        try await super.tearDown()
    }

    // MARK: - Store and Retrieve Tests

    func testStore_apiKey_canBeRetrieved() async throws {
        // Given
        let apiKey = "test-api-key-12345"
        let sourceID = "test-source"

        // When
        try await credentialManager.store(apiKey, for: sourceID, type: .apiKey)

        // Then
        let retrieved = await credentialManager.apiKey(for: sourceID)
        XCTAssertEqual(retrieved, apiKey)
    }

    func testStore_email_canBeRetrieved() async throws {
        // Given
        let email = "test@example.com"
        let sourceID = "test-source"

        // When
        try await credentialManager.store(email, for: sourceID, type: .email)

        // Then
        let retrieved = await credentialManager.email(for: sourceID)
        XCTAssertEqual(retrieved, email)
    }

    func testStoreAPIKey_convenience_works() async throws {
        // Given
        let apiKey = "convenience-test-key"
        let sourceID = "test-source"

        // When
        try await credentialManager.storeAPIKey(apiKey, for: sourceID)

        // Then
        let retrieved = await credentialManager.apiKey(for: sourceID)
        XCTAssertEqual(retrieved, apiKey)
    }

    func testStoreEmail_convenience_works() async throws {
        // Given
        let email = "convenience@example.com"
        let sourceID = "test-source"

        // When
        try await credentialManager.storeEmail(email, for: sourceID)

        // Then
        let retrieved = await credentialManager.email(for: sourceID)
        XCTAssertEqual(retrieved, email)
    }

    func testRetrieve_nonExistent_returnsNil() async {
        // When
        let result = await credentialManager.apiKey(for: "nonexistent-source")

        // Then
        XCTAssertNil(result)
    }

    // MARK: - Has Credential Tests

    func testHasCredential_existing_returnsTrue() async throws {
        // Given
        let sourceID = "test-source"
        try await credentialManager.store("test-key", for: sourceID, type: .apiKey)

        // When
        let hasCredential = await credentialManager.hasCredential(for: sourceID, type: .apiKey)

        // Then
        XCTAssertTrue(hasCredential)
    }

    func testHasCredential_nonExistent_returnsFalse() async {
        // When
        let hasCredential = await credentialManager.hasCredential(for: "nonexistent", type: .apiKey)

        // Then
        XCTAssertFalse(hasCredential)
    }

    func testHasCredential_differentType_returnsFalse() async throws {
        // Given - store API key but check for email
        let sourceID = "test-source"
        try await credentialManager.store("test-key", for: sourceID, type: .apiKey)

        // When
        let hasEmail = await credentialManager.hasCredential(for: sourceID, type: .email)

        // Then
        XCTAssertFalse(hasEmail)
    }

    // MARK: - Delete Tests

    func testDelete_removesCredential() async throws {
        // Given
        let sourceID = "test-source"
        try await credentialManager.store("test-key", for: sourceID, type: .apiKey)

        // Verify it exists
        let beforeDelete = await credentialManager.hasCredential(for: sourceID, type: .apiKey)
        XCTAssertTrue(beforeDelete)

        // When
        await credentialManager.delete(for: sourceID, type: .apiKey)

        // Then
        let afterDelete = await credentialManager.hasCredential(for: sourceID, type: .apiKey)
        XCTAssertFalse(afterDelete)
    }

    func testDeleteAll_removesAllTypesForSource() async throws {
        // Given
        let sourceID = "test-source"
        try await credentialManager.store("test-key", for: sourceID, type: .apiKey)
        try await credentialManager.store("test@example.com", for: sourceID, type: .email)

        // When
        await credentialManager.deleteAll(for: sourceID)

        // Then
        let hasApiKey = await credentialManager.hasCredential(for: sourceID, type: .apiKey)
        let hasEmail = await credentialManager.hasCredential(for: sourceID, type: .email)
        XCTAssertFalse(hasApiKey)
        XCTAssertFalse(hasEmail)
    }

    // MARK: - Validation Tests

    func testValidate_apiKey_valid_returnsTrue() {
        // Given - key with 8+ characters
        let validKey = "abcdefgh12345"

        // When
        let isValid = credentialManager.validate(validKey, type: .apiKey)

        // Then
        XCTAssertTrue(isValid)
    }

    func testValidate_apiKey_tooShort_returnsFalse() {
        // Given - key with < 8 characters
        let shortKey = "abc"

        // When
        let isValid = credentialManager.validate(shortKey, type: .apiKey)

        // Then
        XCTAssertFalse(isValid)
    }

    func testValidate_apiKey_empty_returnsFalse() {
        // When
        let isValid = credentialManager.validate("", type: .apiKey)

        // Then
        XCTAssertFalse(isValid)
    }

    func testValidate_apiKey_tooLong_returnsFalse() {
        // Given - key with > 256 characters
        let longKey = String(repeating: "a", count: 300)

        // When
        let isValid = credentialManager.validate(longKey, type: .apiKey)

        // Then
        XCTAssertFalse(isValid)
    }

    func testValidate_email_valid_returnsTrue() {
        // Given
        let validEmails = [
            "test@example.com",
            "user.name@domain.org",
            "user+tag@subdomain.domain.co.uk"
        ]

        // When/Then
        for email in validEmails {
            XCTAssertTrue(credentialManager.validate(email, type: .email), "Expected \(email) to be valid")
        }
    }

    func testValidate_email_invalid_returnsFalse() {
        // Given
        let invalidEmails = [
            "not-an-email",
            "@nodomain.com",
            "missing@",
            "spaces in@email.com",
            ""
        ]

        // When/Then
        for email in invalidEmails {
            XCTAssertFalse(credentialManager.validate(email, type: .email), "Expected \(email) to be invalid")
        }
    }

    // MARK: - Multiple Sources Tests

    func testStore_multipleSources_isolatedStorage() async throws {
        // Given
        let source1 = "source-one"
        let source2 = "source-two"
        let key1 = "key-for-source-one"
        let key2 = "key-for-source-two"

        // When
        try await credentialManager.store(key1, for: source1, type: .apiKey)
        try await credentialManager.store(key2, for: source2, type: .apiKey)

        // Then - each source has its own key
        let retrieved1 = await credentialManager.apiKey(for: source1)
        let retrieved2 = await credentialManager.apiKey(for: source2)
        XCTAssertEqual(retrieved1, key1)
        XCTAssertEqual(retrieved2, key2)
    }

    func testDelete_oneSource_doesNotAffectOther() async throws {
        // Given
        let source1 = "source-one"
        let source2 = "source-two"
        try await credentialManager.store("key1", for: source1, type: .apiKey)
        try await credentialManager.store("key2", for: source2, type: .apiKey)

        // When - delete source1
        await credentialManager.delete(for: source1, type: .apiKey)

        // Then - source2 still has its key
        let source1Key = await credentialManager.apiKey(for: source1)
        let source2Key = await credentialManager.apiKey(for: source2)
        XCTAssertNil(source1Key)
        XCTAssertEqual(source2Key, "key2")
    }
}
