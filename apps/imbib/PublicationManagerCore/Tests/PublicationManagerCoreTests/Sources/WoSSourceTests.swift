//
//  WoSSourceTests.swift
//  PublicationManagerCoreTests
//
//  Tests for Web of Science source plugin.
//

import XCTest
@testable import PublicationManagerCore

final class WoSSourceTests: XCTestCase {

    var source: WoSSource!
    var mockCredentialManager: MockCredentialManager!
    var mockSession: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        mockCredentialManager = MockCredentialManager()
        // Set up a test API key
        try await mockCredentialManager.storeAPIKey("test-wos-api-key-12345678", for: "wos")

        MockURLProtocol.reset()
        mockSession = MockURLProtocol.mockURLSession()

        source = WoSSource(session: mockSession, credentialManager: mockCredentialManager)
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
        XCTAssertEqual(source.metadata.id, "wos")
    }

    func testMetadata_name() {
        XCTAssertEqual(source.metadata.name, "Web of Science")
    }

    func testMetadata_requiresAPIKey() {
        XCTAssertEqual(source.metadata.credentialRequirement, .apiKey)
    }

    func testMetadata_hasRegistrationURL() {
        XCTAssertNotNil(source.metadata.registrationURL)
        XCTAssertEqual(
            source.metadata.registrationURL?.absoluteString,
            "https://developer.clarivate.com/apis/wos-starter"
        )
    }

    func testMetadata_supportsRIS() async {
        let supportsRIS = await source.supportsRIS
        XCTAssertTrue(supportsRIS)
    }

    // MARK: - Search Response Parsing Tests

    func testSearch_parsesResponse() async throws {
        // Given - mock WoS search response
        let responseJSON: [String: Any] = [
            "queryResult": [
                "queryId": "test-query-id",
                "recordsSearched": 100000,
                "recordsFound": 2,
                "records": [
                    [
                        "uid": "WOS:000123456789012",
                        "title": ["value": "Quantum Computing Applications"],
                        "source": [
                            "sourceTitle": "Nature",
                            "publishYear": 2024,
                            "volume": "625",
                            "issue": "7993",
                            "pages": ["range": "100-105"]
                        ],
                        "names": [
                            "authors": [
                                ["displayName": "Einstein, Albert", "lastName": "Einstein", "firstName": "Albert"],
                                ["displayName": "Bohr, Niels", "lastName": "Bohr", "firstName": "Niels"]
                            ]
                        ],
                        "identifiers": [
                            "doi": "10.1038/nature12345",
                            "issn": "0028-0836"
                        ],
                        "citations": ["count": 150],
                        "keywords": [
                            "authorKeywords": ["quantum", "computing", "algorithms"]
                        ]
                    ],
                    [
                        "uid": "WOS:000987654321098",
                        "title": ["value": "Machine Learning for Science"],
                        "source": [
                            "sourceTitle": "Science",
                            "publishYear": 2023
                        ],
                        "names": [
                            "authors": [
                                ["displayName": "Turing, Alan"]
                            ]
                        ],
                        "identifiers": [
                            "doi": "10.1126/science.abc1234"
                        ]
                    ]
                ]
            ]
        ]

        MockURLProtocol.requestHandler = { request in
            // Verify API key header
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-ApiKey"), "test-wos-api-key-12345678")

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
        let results = try await source.search(query: "TS=quantum computing")

        // Then
        XCTAssertEqual(results.count, 2)

        let firstResult = results.first!
        XCTAssertEqual(firstResult.id, "000123456789012")  // UT without WOS: prefix
        XCTAssertEqual(firstResult.sourceID, "wos")
        XCTAssertEqual(firstResult.title, "Quantum Computing Applications")
        XCTAssertEqual(firstResult.authors, ["Einstein, Albert", "Bohr, Niels"])
        XCTAssertEqual(firstResult.year, 2024)
        XCTAssertEqual(firstResult.venue, "Nature")
        XCTAssertEqual(firstResult.doi, "10.1038/nature12345")
    }

    func testSearch_handlesEmptyResults() async throws {
        // Given - empty response
        let responseJSON: [String: Any] = [
            "queryResult": [
                "queryId": "test-query-id",
                "recordsSearched": 100000,
                "recordsFound": 0,
                "records": [] as [[String: Any]]
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
        let results = try await source.search(query: "TS=nonexistent")

        // Then
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Error Handling Tests

    func testSearch_withoutAPIKey_throwsAuthenticationRequired() async throws {
        // Given - remove API key
        await mockCredentialManager.delete(for: "wos", type: .apiKey)

        // When/Then
        do {
            _ = try await source.search(query: "test")
            XCTFail("Should throw authentication error")
        } catch let error as SourceError {
            if case .authenticationRequired(let source) = error {
                XCTAssertEqual(source, "wos")
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
                XCTAssertEqual(source, "wos")
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testSearch_429Response_throwsRateLimited() async throws {
        // Given
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, nil)
        }

        // When/Then
        do {
            _ = try await source.search(query: "test")
            XCTFail("Should throw rate limited error")
        } catch let error as SourceError {
            if case .rateLimited = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - BibTeX Generation Tests

    func testGenerateBibTeX_hasCorrectFields() {
        // Given
        let record = WoSRecord(
            uid: "WOS:000123456789012",
            title: WoSTitle(value: "Test Paper Title"),
            types: ["Article"],
            sourceTypes: nil,
            source: WoSJournalSource(
                sourceTitle: "Nature",
                publishYear: 2024,
                publishMonth: "Jan",
                volume: "625",
                issue: "7993",
                pages: WoSPages(range: "100-105", begin: "100", end: "105", count: 6),
                articleNo: nil
            ),
            names: WoSNames(
                authors: [
                    WoSAuthor(displayName: "Einstein, Albert", wosStandard: nil, firstName: "Albert", lastName: "Einstein", orcid: nil, researcherId: nil)
                ],
                inventors: nil
            ),
            links: nil,
            citations: WoSCitationInfo(count: 150),
            identifiers: WoSIdentifiers(doi: "10.1038/nature12345", issn: "0028-0836", eissn: nil, isbn: nil, pmid: nil),
            keywords: WoSKeywords(authorKeywords: ["quantum", "computing"], keywordsPlus: nil)
        )

        // When
        let entry = WoSResponseParser.generateBibTeX(from: record)

        // Then
        XCTAssertEqual(entry.entryType, "article")
        XCTAssertEqual(entry.fields["title"], "Test Paper Title")
        XCTAssertEqual(entry.fields["author"], "Einstein, Albert")
        XCTAssertEqual(entry.fields["journal"], "Nature")
        XCTAssertEqual(entry.fields["year"], "2024")
        XCTAssertEqual(entry.fields["volume"], "625")
        XCTAssertEqual(entry.fields["number"], "7993")
        XCTAssertEqual(entry.fields["pages"], "100-105")
        XCTAssertEqual(entry.fields["doi"], "10.1038/nature12345")
        XCTAssertEqual(entry.fields["keywords"], "quantum, computing")
        XCTAssertEqual(entry.fields["wos-ut"], "000123456789012")
    }

    // MARK: - Entry Type Mapping Tests

    func testEntryTypeMapping_article() {
        let entryType = WoSEntryType(wosType: "Article")
        XCTAssertEqual(entryType.bibtexType, "article")
        XCTAssertEqual(entryType.risType, "JOUR")
    }

    func testEntryTypeMapping_book() {
        let entryType = WoSEntryType(wosType: "Book")
        XCTAssertEqual(entryType.bibtexType, "book")
        XCTAssertEqual(entryType.risType, "BOOK")
    }

    func testEntryTypeMapping_proceedingsPaper() {
        let entryType = WoSEntryType(wosType: "Proceedings Paper")
        XCTAssertEqual(entryType.bibtexType, "inproceedings")
        XCTAssertEqual(entryType.risType, "CONF")
    }

    func testEntryTypeMapping_review() {
        let entryType = WoSEntryType(wosType: "Review")
        XCTAssertEqual(entryType.bibtexType, "article")
        XCTAssertEqual(entryType.risType, "JOUR")
    }

    // MARK: - Query Field Tests

    func testQueryField_knownFields() {
        let knownFields = WoSQueryField.allCases.map { $0.rawValue }

        XCTAssertTrue(knownFields.contains("TS"))  // Topic
        XCTAssertTrue(knownFields.contains("TI"))  // Title
        XCTAssertTrue(knownFields.contains("AU"))  // Author
        XCTAssertTrue(knownFields.contains("DO"))  // DOI
        XCTAssertTrue(knownFields.contains("PY"))  // Year
        XCTAssertTrue(knownFields.contains("SO"))  // Source
    }

    func testQueryField_displayNames() {
        XCTAssertEqual(WoSQueryField.topic.displayName, "Topic")
        XCTAssertEqual(WoSQueryField.author.displayName, "Author")
        XCTAssertEqual(WoSQueryField.year.displayName, "Year")
    }
}
