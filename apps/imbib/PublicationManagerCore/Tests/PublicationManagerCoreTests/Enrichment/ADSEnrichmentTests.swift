//
//  ADSEnrichmentTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class ADSEnrichmentTests: XCTestCase {

    var session: URLSession!
    var credentialManager: MockCredentialManager!
    var source: ADSSource!

    override func setUp() async throws {
        try await super.setUp()

        MockURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        credentialManager = MockCredentialManager()
        try await credentialManager.storeAPIKey("test-api-key-12345", for: "ads")

        source = ADSSource(session: session, credentialManager: credentialManager)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
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

    // MARK: - Enrich Success Tests

    func testEnrichWithBibcode() async throws {
        let fixtureData = loadFixture("ads_work")
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("bibcode") == true)
            XCTAssertTrue(request.allHTTPHeaderFields?["Authorization"]?.contains("Bearer") == true)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "2017arXiv170603762V"]
        let result = try await source.enrich(identifiers: identifiers, existingData: nil)

        XCTAssertEqual(result.data.citationCount, 98000)
        XCTAssertEqual(result.data.source, .ads)
    }

    func testEnrichWithDOI() async throws {
        let fixtureData = loadFixture("ads_work")
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("doi") == true)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let identifiers: [IdentifierType: String] = [.doi: "10.48550/arxiv.1706.03762"]
        let result = try await source.enrich(identifiers: identifiers, existingData: nil)

        XCTAssertEqual(result.data.citationCount, 98000)
    }

    func testEnrichWithArXiv() async throws {
        let fixtureData = loadFixture("ads_work")
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("arXiv") == true)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let identifiers: [IdentifierType: String] = [.arxiv: "1706.03762"]
        let result = try await source.enrich(identifiers: identifiers, existingData: nil)

        XCTAssertEqual(result.data.citationCount, 98000)
    }

    func testEnrichReturnsAbstract() async throws {
        let fixtureData = loadFixture("ads_work")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "2017arXiv170603762V"]
        let result = try await source.enrich(identifiers: identifiers, existingData: nil)

        XCTAssertNotNil(result.data.abstract)
        XCTAssertTrue(result.data.abstract?.contains("Transformer") == true)
    }

    func testEnrichReturnsReferenceCount() async throws {
        // The new implementation makes separate API calls for basic info and full references.
        // This test verifies the reference count is returned from the basic info query.
        let fixtureData = loadFixture("ads_work")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "2017arXiv170603762V"]
        let result = try await source.enrich(identifiers: identifiers, existingData: nil)

        // Reference count should be extracted from the initial query
        XCTAssertEqual(result.data.referenceCount, 3)
        // Full references are fetched in a separate API call - they may be nil or partial
        // depending on the mock response (which returns the same fixture for all calls)
    }

    // MARK: - Minimal Response Tests

    func testEnrichWithMinimalResponse() async throws {
        let fixtureData = loadFixture("ads_minimal")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "2023arXiv230112345A"]
        let result = try await source.enrich(identifiers: identifiers, existingData: nil)

        XCTAssertEqual(result.data.citationCount, 0)
        XCTAssertNil(result.data.abstract)
        XCTAssertNil(result.data.references)
        XCTAssertNil(result.data.referenceCount)
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

    func testEnrichAddsBibcodeToResolvedIdentifiers() async throws {
        let fixtureData = loadFixture("ads_work")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "2017arXiv170603762V"]
        let result = try await source.enrich(identifiers: identifiers, existingData: nil)

        XCTAssertEqual(result.resolvedIdentifiers[.bibcode], "2017arXiv170603762V")
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

    func testEnrichNotFound() async {
        let fixtureData = loadFixture("ads_not_found")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "nonexistent"]

        do {
            _ = try await source.enrich(identifiers: identifiers, existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            if case .notFound = error {
                // Expected
            } else {
                XCTFail("Expected notFound error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrich401Unauthorized() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "test"]

        do {
            _ = try await source.enrich(identifiers: identifiers, existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            if case .authenticationRequired = error {
                // Expected
            } else {
                XCTFail("Expected authenticationRequired error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichRateLimited() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "test"]

        do {
            _ = try await source.enrich(identifiers: identifiers, existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            if case .rateLimited = error {
                // Expected
            } else {
                XCTFail("Expected rateLimited error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichMalformedJSON() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "invalid json".data(using: .utf8))
        }

        let identifiers: [IdentifierType: String] = [.bibcode: "test"]

        do {
            _ = try await source.enrich(identifiers: identifiers, existingData: nil)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            if case .parseError = error {
                // Expected
            } else {
                XCTFail("Expected parseError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichRequiresAPIKey() async throws {
        // Create source with no API key
        let emptyCredentialManager = MockCredentialManager()
        let sourceNoKey = ADSSource(session: session, credentialManager: emptyCredentialManager)

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

    // MARK: - Merge Tests

    func testEnrichMergesWithExistingData() async throws {
        let fixtureData = loadFixture("ads_minimal")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, fixtureData)
        }

        let existingData = EnrichmentData(
            citationCount: 999,
            abstract: "Existing abstract",
            source: .ads
        )

        let identifiers: [IdentifierType: String] = [.bibcode: "2023arXiv230112345A"]
        let result = try await source.enrich(identifiers: identifiers, existingData: existingData)

        // New data (citationCount: 0) takes precedence
        XCTAssertEqual(result.data.citationCount, 0)

        // Existing abstract is kept since minimal has nil
        XCTAssertEqual(result.data.abstract, "Existing abstract")

        // Source is the new enrichment source
        XCTAssertEqual(result.data.source, .ads)
    }

    // MARK: - Helper

    private func loadFixture(_ name: String) -> Data {
        // Use #file to get the current file's directory and construct relative path to Fixtures
        let currentFile = URL(fileURLWithPath: #file)
        let fixturesDir = currentFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
        let fixtureURL = fixturesDir.appendingPathComponent("\(name).json")
        return try! Data(contentsOf: fixtureURL)
    }
}
