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
    var mockSession: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        mockCredentialManager = MockCredentialManager()
        // Set up a test API key
        try await mockCredentialManager.storeAPIKey("test-api-key-12345678", for: "ads")

        MockURLProtocol.reset()
        mockSession = MockURLProtocol.mockURLSession()

        source = ADSSource(session: mockSession, credentialManager: mockCredentialManager)
    }

    override func tearDown() async throws {
        source = nil
        mockSession = nil
        mockCredentialManager = nil
        MockURLProtocol.reset()
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

    // MARK: - PDF URL Tests

    func testParseDoc_withArXivID_generateArXivPDFURL() async throws {
        // Given - mock response with arXiv paper
        let responseJSON: [String: Any] = [
            "response": [
                "docs": [
                    [
                        "bibcode": "2024arXiv240112345A",
                        "title": ["A Test Paper on arXiv"],
                        "author": ["Author, Test"],
                        "year": 2024,
                        "identifier": ["arXiv:2401.12345", "doi:10.1234/test"]
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        // When
        let results = try await source.search(query: "test")

        // Then
        XCTAssertEqual(results.count, 1)
        let result = results.first!
        XCTAssertEqual(result.arxivID, "2401.12345")
        XCTAssertNotNil(result.pdfURL)
        XCTAssertEqual(result.pdfURL?.absoluteString, "https://arxiv.org/pdf/2401.12345.pdf")
    }

    func testParseDoc_withoutArXivID_generateADSGatewayURL() async throws {
        // Given - mock response without arXiv ID but with DOI
        // ADSSource uses DOI resolver (not link_gateway) for papers without arXiv
        let responseJSON: [String: Any] = [
            "response": [
                "docs": [
                    [
                        "bibcode": "2024ApJ...123..456A",
                        "title": ["A Journal Paper"],
                        "author": ["Author, Test"],
                        "year": 2024,
                        "pub": "The Astrophysical Journal",
                        "doi": ["10.1234/example.2024.12345"]
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        // When
        let results = try await source.search(query: "test")

        // Then - Uses DOI resolver URL (more reliable than deprecated link_gateway)
        XCTAssertEqual(results.count, 1)
        let result = results.first!
        XCTAssertNil(result.arxivID)
        XCTAssertNotNil(result.pdfURL)
        XCTAssertEqual(
            result.pdfURL?.absoluteString,
            "https://doi.org/10.1234/example.2024.12345"
        )
    }

    func testParseDoc_pdfURL_requiresArXivOrDOI() async throws {
        // Given - papers with and without identifiers
        // ADSSource only generates PDF URLs for papers with arXiv ID or DOI
        // (link_gateway URLs were removed as unreliable)
        let responseJSON: [String: Any] = [
            "response": [
                "docs": [
                    [
                        "bibcode": "2024arXiv240112345A",
                        "title": ["arXiv Paper"],
                        "identifier": ["arXiv:2401.12345"]
                    ],
                    [
                        "bibcode": "2024ApJ...123..456A",
                        "title": ["Journal Paper with DOI"],
                        "doi": ["10.1234/journal.2024"]
                    ],
                    [
                        "bibcode": "2024MNRAS.500.1000B",
                        "title": ["Journal Paper without identifiers"]
                        // No arXiv, no DOI - no PDF URL
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        // When
        let results = try await source.search(query: "test")

        // Then
        XCTAssertEqual(results.count, 3)

        // arXiv paper has arXiv URL
        let arxivResult = results.first { $0.id == "2024arXiv240112345A" }!
        XCTAssertNotNil(arxivResult.pdfURL)
        XCTAssertEqual(arxivResult.pdfURL?.absoluteString, "https://arxiv.org/pdf/2401.12345.pdf")

        // Journal paper with DOI has DOI URL
        let journalWithDOI = results.first { $0.id == "2024ApJ...123..456A" }!
        XCTAssertNotNil(journalWithDOI.pdfURL)
        XCTAssertEqual(journalWithDOI.pdfURL?.absoluteString, "https://doi.org/10.1234/journal.2024")

        // Journal paper without identifiers has no PDF URL
        let journalWithoutID = results.first { $0.id == "2024MNRAS.500.1000B" }!
        XCTAssertNil(journalWithoutID.pdfURL, "Paper without arXiv/DOI should not have PDF URL")
    }

    // MARK: - Year Parsing Tests

    func testParseDoc_yearAsInt_parsesCorrectly() async throws {
        // Given - year as Int
        let responseJSON: [String: Any] = [
            "response": [
                "docs": [
                    [
                        "bibcode": "2024ApJ...123..456A",
                        "title": ["Test Paper"],
                        "author": ["Author, Test"],
                        "year": 2024  // Int format
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        // When
        let results = try await source.search(query: "test")

        // Then
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.year, 2024)
    }

    func testParseDoc_yearAsString_parsesCorrectly() async throws {
        // Given - year as String (ADS sometimes returns this format)
        let responseJSON: [String: Any] = [
            "response": [
                "docs": [
                    [
                        "bibcode": "2024ApJ...123..456A",
                        "title": ["Test Paper"],
                        "author": ["Author, Test"],
                        "year": "2024"  // String format
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        // When
        let results = try await source.search(query: "test")

        // Then
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.year, 2024)
    }

    // MARK: - arXiv ID Extraction Tests

    func testExtractArXivID_withArXivPrefix() async throws {
        // Given
        let responseJSON: [String: Any] = [
            "response": [
                "docs": [
                    [
                        "bibcode": "2024arXiv240112345A",
                        "title": ["Test"],
                        "identifier": ["arXiv:2401.12345"]
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        // When
        let results = try await source.search(query: "test")

        // Then
        XCTAssertEqual(results.first?.arxivID, "2401.12345")
    }

    func testExtractArXivID_withNewFormat() async throws {
        // Given - new format without prefix
        let responseJSON: [String: Any] = [
            "response": [
                "docs": [
                    [
                        "bibcode": "2024arXiv240112345A",
                        "title": ["Test"],
                        "identifier": ["2401.12345"]
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        // When
        let results = try await source.search(query: "test")

        // Then
        XCTAssertEqual(results.first?.arxivID, "2401.12345")
    }

    // MARK: - Web URL Tests

    func testParseDoc_hasWebURL() async throws {
        // Given
        let responseJSON: [String: Any] = [
            "response": [
                "docs": [
                    [
                        "bibcode": "2024ApJ...123..456A",
                        "title": ["Test Paper"]
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        // When
        let results = try await source.search(query: "test")

        // Then
        XCTAssertEqual(
            results.first?.webURL?.absoluteString,
            "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456A"
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

    func testSearch_401Response_throwsAuthenticationRequired() async throws {
        // Given
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, nil)
        }

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
