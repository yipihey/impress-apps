//
//  SciXSourceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-08.
//

import XCTest
@testable import PublicationManagerCore

final class SciXSourceTests: XCTestCase {

    var source: SciXSource!
    var mockCredentialManager: MockCredentialManager!

    override func setUp() async throws {
        try await super.setUp()
        mockCredentialManager = MockCredentialManager()
        // Set up a test API key
        try await mockCredentialManager.storeAPIKey("test-api-key-12345678", for: "scix")

        source = SciXSource(credentialManager: mockCredentialManager)
    }

    override func tearDown() async throws {
        source = nil
        mockCredentialManager = nil
        try await super.tearDown()
    }

    // MARK: - Metadata Tests

    func testMetadata_id() {
        XCTAssertEqual(source.metadata.id, "scix")
    }

    func testMetadata_name() {
        XCTAssertEqual(source.metadata.name, "SciX")
    }

    func testMetadata_requiresAPIKey() {
        XCTAssertEqual(source.metadata.credentialRequirement, .apiKey)
    }

    func testMetadata_hasRegistrationURL() {
        XCTAssertNotNil(source.metadata.registrationURL)
        XCTAssertEqual(
            source.metadata.registrationURL?.absoluteString,
            "https://scixplorer.org/user/settings/token"
        )
    }

    func testMetadata_supportsRIS() async {
        let supportsRIS = await source.supportsRIS
        XCTAssertTrue(supportsRIS)
    }

    // MARK: - Error Handling Tests

    func testSearch_withoutAPIKey_throwsAuthenticationRequired() async throws {
        // Given - remove API key
        await mockCredentialManager.delete(for: "scix", type: .apiKey)

        // When/Then
        do {
            _ = try await source.search(query: "test")
            XCTFail("Should throw authentication error")
        } catch let error as SourceError {
            if case .authenticationRequired(let source) = error {
                XCTAssertEqual(source, "scix")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - BrowserURLProvider Tests

    func testBrowserURL_sourceID() async throws {
        let sourceID = SciXSource.sourceID
        XCTAssertEqual(sourceID, "scix")
    }
}
