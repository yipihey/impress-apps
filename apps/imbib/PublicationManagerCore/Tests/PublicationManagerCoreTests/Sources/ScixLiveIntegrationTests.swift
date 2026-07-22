//
//  ScixLiveIntegrationTests.swift
//  PublicationManagerCoreTests
//
//  Live end-to-end integration for the SciX/ADS sources: real token → the Rust
//  scix-client FFI (reqwest inside Rust) → the real SciX/ADS API →
//  ScixConversions → domain types. This is the round-trip the old mock-based
//  tests only pretended to exercise (the FFI ignores URLProtocol mocks).
//
//  These require a live token and are SKIPPED cleanly without one (see
//  requireLiveToken), so CI/tokenless shells stay green. Assertions are
//  STRUCTURAL — non-empty, well-formed — never exact field values, so they
//  don't break when the live corpus shifts. Deterministic parsing/mapping is
//  covered token-free by ScixConversionsTests; this layer proves the wire path.
//

import XCTest
@testable import PublicationManagerCore

final class ScixLiveIntegrationTests: XCTestCase {

    // MARK: - SciX search

    func testLiveSciXSearch_returnsWellFormedResults() async throws {
        let token = try requireLiveToken()
        let credentials = MockCredentialManager()
        try await credentials.storeAPIKey(token, for: "scix")
        let source = SciXSource(credentialManager: credentials)

        let results = try await source.search(query: "gravitational waves", maxResults: 5)

        XCTAssertFalse(results.isEmpty, "A live SciX search should return results")
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.sourceID, "scix")
        XCTAssertFalse(first.title.isEmpty, "A result should carry a title")
        XCTAssertFalse((first.bibcode ?? "").isEmpty, "A SciX result should carry a bibcode")
    }

    // MARK: - ADS enrichment

    func testLiveADSEnrich_resolvesBibcode() async throws {
        let token = try requireLiveToken()
        let credentials = MockCredentialManager()
        try await credentials.storeAPIKey(token, for: "ads")
        let source = ADSSource(credentialManager: credentials)

        // A stable, well-known arXiv paper ("Attention Is All You Need").
        let result = try await source.enrich(
            identifiers: [.arxiv: "1706.03762"], existingData: nil)

        let bibcode = result.resolvedIdentifiers[.bibcode] ?? ""
        XCTAssertFalse(bibcode.isEmpty, "enrich should resolve a bibcode for a known arXiv id")
    }
}
