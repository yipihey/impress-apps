//
//  ADSSourceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class ADSSourceTests: XCTestCase {

    var source: ADSSource!
    var mockCredentialManager: MockCredentialManager!

    override func setUp() async throws {
        try await super.setUp()
        mockCredentialManager = MockCredentialManager()
        // Set up a test API key
        try await mockCredentialManager.storeAPIKey("test-api-key-12345678", for: "ads")

        source = ADSSource(credentialManager: mockCredentialManager)
    }

    override func tearDown() async throws {
        source = nil
        mockCredentialManager = nil
        try await super.tearDown()
    }

    // MARK: - Metadata Tests

    func testMetadata_id() {
        XCTAssertEqual(source.metadata.id, "ads")
    }

    func testMetadata_name() {
        XCTAssertEqual(source.metadata.name, "NASA ADS")
    }

    func testMetadata_requiresAPIKey() {
        XCTAssertEqual(source.metadata.credentialRequirement, .apiKey)
    }

    func testMetadata_hasRegistrationURL() {
        XCTAssertNotNil(source.metadata.registrationURL)
        XCTAssertEqual(
            source.metadata.registrationURL?.absoluteString,
            "https://ui.adsabs.harvard.edu/user/settings/token"
        )
    }

    // MARK: - Error Handling Tests

    func testSearch_withoutAPIKey_throwsAuthenticationRequired() async throws {
        // Given - remove API key
        await mockCredentialManager.delete(for: "ads", type: .apiKey)

        // When/Then
        do {
            _ = try await source.search(query: "test")
            XCTFail("Should throw authentication error")
        } catch let error as SourceError {
            if case .authenticationRequired(let source) = error {
                XCTAssertEqual(source, "ads")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
}
