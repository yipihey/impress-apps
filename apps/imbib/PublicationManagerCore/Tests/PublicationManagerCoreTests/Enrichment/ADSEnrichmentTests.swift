//
//  ADSEnrichmentTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class ADSEnrichmentTests: XCTestCase {

    var credentialManager: MockCredentialManager!
    var source: ADSSource!

    override func setUp() async throws {
        try await super.setUp()

        credentialManager = MockCredentialManager()
        try await credentialManager.storeAPIKey("test-api-key-12345", for: "ads")

        source = ADSSource(credentialManager: credentialManager)
    }

    // MARK: - Capabilities Tests

    func testEnrichmentCapabilities() async {
        let caps = await source.enrichmentCapabilities

        XCTAssertTrue(caps.contains(.citationCount))
        XCTAssertTrue(caps.contains(.references))
        XCTAssertTrue(caps.contains(.abstract))
    }

    func testDoesNotSupportPDFURL() async {
        let caps = await source.enrichmentCapabilities
        XCTAssertFalse(caps.contains(.pdfURL))
    }

    func testDoesNotSupportOpenAccess() async {
        let caps = await source.enrichmentCapabilities
        XCTAssertFalse(caps.contains(.openAccess))
    }

    func testSupportsCitations() async {
        let caps = await source.enrichmentCapabilities
        XCTAssertTrue(caps.contains(.citations))
    }

    // MARK: - Identifier Resolution Tests

    func testResolveIdentifierWithBibcode() async throws {
        let identifiers: [IdentifierType: String] = [.bibcode: "2017arXiv170603762V"]
        let resolved = try await source.resolveIdentifier(from: identifiers)

        XCTAssertEqual(resolved[.bibcode], "2017arXiv170603762V")
    }

    func testResolveIdentifierFromDOI() async throws {
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]
        let resolved = try await source.resolveIdentifier(from: identifiers)

        XCTAssertEqual(resolved[.doi], "10.1234/test")
        XCTAssertNotNil(resolved[.bibcode])
        XCTAssertTrue(resolved[.bibcode]?.contains("doi:") == true)
    }

    func testResolveIdentifierFromArXiv() async throws {
        let identifiers: [IdentifierType: String] = [.arxiv: "1706.03762"]
        let resolved = try await source.resolveIdentifier(from: identifiers)

        XCTAssertEqual(resolved[.arxiv], "1706.03762")
        XCTAssertNotNil(resolved[.bibcode])
        XCTAssertTrue(resolved[.bibcode]?.contains("arXiv:") == true)
    }

    // MARK: - Error Handling Tests

    func testEnrichWithNoIdentifiers() async {
        let identifiers: [IdentifierType: String] = [:]

        do {
            _ = try await source.enrich(identifiers: identifiers, existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            if case .noIdentifier = error {
                // Expected
            } else {
                XCTFail("Expected noIdentifier error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichWithUnsupportedIdentifier() async {
        // PubMed ID is not directly supported by ADS
        let identifiers: [IdentifierType: String] = [.pmid: "12345678"]

        do {
            _ = try await source.enrich(identifiers: identifiers, existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            if case .noIdentifier = error {
                // Expected
            } else {
                XCTFail("Expected noIdentifier error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichRequiresAPIKey() async throws {
        // Create source with no API key
        let emptyCredentialManager = MockCredentialManager()
        let sourceNoKey = ADSSource(credentialManager: emptyCredentialManager)

        let identifiers: [IdentifierType: String] = [.bibcode: "test"]

        do {
            _ = try await sourceNoKey.enrich(identifiers: identifiers, existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            if case .authenticationRequired(let source) = error {
                XCTAssertEqual(source, "ads")
            } else {
                XCTFail("Expected authenticationRequired error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

}
