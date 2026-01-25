//
//  SettingsViewModelTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

/// Tests for SettingsViewModel credential management.
@MainActor
final class SettingsViewModelTests: XCTestCase {

    private var mockCredentialManager: MockCredentialManager!
    private var sourceManager: SourceManager!
    private var mockSource: MockSourcePlugin!
    private var viewModel: SettingsViewModel!

    override func setUp() async throws {
        try await super.setUp()

        mockCredentialManager = MockCredentialManager()

        // Use a unique prefix to avoid test pollution
        let testPrefix = "test.\(UUID().uuidString)"
        let credentialManager = CredentialManager(keyPrefix: testPrefix)
        sourceManager = SourceManager(credentialManager: credentialManager)

        // Register mock source requiring API key
        mockSource = MockSourcePlugin(
            id: "test-source",
            name: "Test Source",
            credentialRequirement: .apiKey
        )
        await sourceManager.register(mockSource)

        viewModel = SettingsViewModel(
            sourceManager: sourceManager,
            credentialManager: credentialManager
        )
    }

    override func tearDown() async throws {
        viewModel = nil
        sourceManager = nil
        mockSource = nil
        mockCredentialManager = nil
        try await super.tearDown()
    }

    // MARK: - Initial State Tests

    func testViewModel_initialState() {
        XCTAssertTrue(viewModel.sourceCredentials.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
    }

    // MARK: - Load Tests

    func testLoadCredentialStatus_loadsAllSources() async {
        // When
        await viewModel.loadCredentialStatus()

        // Then
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.sourceCredentials.isEmpty)

        // Find our test source
        let testSource = viewModel.sourceCredentials.first { $0.sourceID == "test-source" }
        XCTAssertNotNil(testSource)
        XCTAssertEqual(testSource?.status, .missing)
    }

    // MARK: - Save API Key Tests

    func testSaveAPIKey_valid_storesKey() async throws {
        // Given
        let validAPIKey = "valid-api-key-12345678"

        // When
        try await viewModel.saveAPIKey(validAPIKey, for: "test-source")

        // Then
        let storedKey = await viewModel.getAPIKey(for: "test-source")
        XCTAssertEqual(storedKey, validAPIKey)
    }

    func testSaveAPIKey_tooShort_throwsError() async {
        // Given - Too short API key
        let shortAPIKey = "short"

        // When/Then
        do {
            try await viewModel.saveAPIKey(shortAPIKey, for: "test-source")
            XCTFail("Should have thrown error for short API key")
        } catch let error as CredentialError {
            if case .invalid = error {
                // Expected
            } else {
                XCTFail("Expected invalid error type")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSaveAPIKey_empty_throwsError() async {
        // Given
        let emptyAPIKey = ""

        // When/Then
        do {
            try await viewModel.saveAPIKey(emptyAPIKey, for: "test-source")
            XCTFail("Should have thrown error for empty API key")
        } catch {
            XCTAssertTrue(error is CredentialError)
        }
    }

    // MARK: - Save Email Tests

    func testSaveEmail_valid_storesEmail() async throws {
        // Given
        let validEmail = "test@example.com"

        // When
        try await viewModel.saveEmail(validEmail, for: "test-source")

        // Then
        let storedEmail = await viewModel.getEmail(for: "test-source")
        XCTAssertEqual(storedEmail, validEmail)
    }

    func testSaveEmail_invalid_throwsError() async {
        // Given
        let invalidEmail = "not-an-email"

        // When/Then
        do {
            try await viewModel.saveEmail(invalidEmail, for: "test-source")
            XCTFail("Should have thrown error for invalid email")
        } catch {
            XCTAssertTrue(error is CredentialError)
        }
    }

    func testSaveEmail_malformed_throwsError() async {
        // Given - Missing TLD
        let malformedEmail = "missing@domain"

        // When/Then
        do {
            try await viewModel.saveEmail(malformedEmail, for: "test-source")
            XCTFail("Should have thrown error for malformed email")
        } catch {
            XCTAssertTrue(error is CredentialError)
        }
    }

    // MARK: - Delete Tests

    func testDeleteCredentials_removesStoredCredentials() async throws {
        // Given
        try await viewModel.saveAPIKey("api-key-to-delete-12345678", for: "test-source")
        let beforeDelete = await viewModel.getAPIKey(for: "test-source")
        XCTAssertNotNil(beforeDelete)

        // When
        await viewModel.deleteCredentials(for: "test-source")

        // Then
        let afterDelete = await viewModel.getAPIKey(for: "test-source")
        XCTAssertNil(afterDelete)
    }

    // MARK: - Retrieval Tests

    func testGetAPIKey_existingKey_returnsKey() async throws {
        // Given
        let apiKey = "stored-api-key-12345678"
        try await viewModel.saveAPIKey(apiKey, for: "test-source")

        // When
        let retrieved = await viewModel.getAPIKey(for: "test-source")

        // Then
        XCTAssertEqual(retrieved, apiKey)
    }

    func testGetAPIKey_nonExistent_returnsNil() async {
        // When
        let retrieved = await viewModel.getAPIKey(for: "nonexistent-source")

        // Then
        XCTAssertNil(retrieved)
    }

    func testGetEmail_existingEmail_returnsEmail() async throws {
        // Given
        let email = "stored@example.com"
        try await viewModel.saveEmail(email, for: "test-source")

        // When
        let retrieved = await viewModel.getEmail(for: "test-source")

        // Then
        XCTAssertEqual(retrieved, email)
    }

    func testGetEmail_nonExistent_returnsNil() async {
        // When
        let retrieved = await viewModel.getEmail(for: "nonexistent-source")

        // Then
        XCTAssertNil(retrieved)
    }
}
