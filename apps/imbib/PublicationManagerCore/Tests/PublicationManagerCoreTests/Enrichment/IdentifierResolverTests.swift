//
//  IdentifierResolverTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class IdentifierResolverTests: XCTestCase {

    var resolver: IdentifierResolver!

    override func setUp() async throws {
        resolver = IdentifierResolver()
    }

    // MARK: - Resolution Tests

    func testResolveWithDOI() async {
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]
        let resolved = await resolver.resolve(identifiers)

        XCTAssertEqual(resolved.doi, "10.1234/test")
        XCTAssertEqual(resolved.semanticScholarID, "DOI:10.1234/test")
        XCTAssertNotNil(resolved.openAlexID)
    }

    func testResolveWithArXiv() async {
        let identifiers: [IdentifierType: String] = [.arxiv: "2301.12345"]
        let resolved = await resolver.resolve(identifiers)

        XCTAssertEqual(resolved.arxivID, "2301.12345")
        XCTAssertEqual(resolved.semanticScholarID, "ARXIV:2301.12345")
    }

    func testResolveWithPMID() async {
        let identifiers: [IdentifierType: String] = [.pmid: "12345678"]
        let resolved = await resolver.resolve(identifiers)

        XCTAssertEqual(resolved.pmid, "12345678")
        XCTAssertEqual(resolved.semanticScholarID, "PMID:12345678")
    }

    func testResolvePreservesExistingIdentifiers() async {
        let identifiers: [IdentifierType: String] = [
            .doi: "10.1234/test",
            .arxiv: "2301.12345",
            .bibcode: "2020ApJ...123...45A"
        ]
        let resolved = await resolver.resolve(identifiers)

        // All original identifiers preserved
        XCTAssertEqual(resolved.doi, "10.1234/test")
        XCTAssertEqual(resolved.arxivID, "2301.12345")
        XCTAssertEqual(resolved.bibcode, "2020ApJ...123...45A")
    }

    func testResolveDoesNotOverwriteExisting() async {
        let identifiers: [IdentifierType: String] = [
            .doi: "10.1234/test",
            .semanticScholar: "existing-s2-id"  // Already has S2 ID
        ]
        let resolved = await resolver.resolve(identifiers)

        // Should not overwrite existing S2 ID
        XCTAssertEqual(resolved.semanticScholarID, "existing-s2-id")
    }

    // MARK: - Direct Resolution Methods

    func testResolveToSemanticScholarDOI() async {
        let result = await resolver.resolveToSemanticScholar(doi: "10.1234/test")
        XCTAssertEqual(result, "DOI:10.1234/test")
    }

    func testResolveToSemanticScholarArXiv() async {
        let result = await resolver.resolveToSemanticScholar(arxivID: "2301.12345")
        XCTAssertEqual(result, "ARXIV:2301.12345")
    }

    func testResolveToSemanticScholarPMID() async {
        let result = await resolver.resolveToSemanticScholar(pmid: "12345678")
        XCTAssertEqual(result, "PMID:12345678")
    }

    // MARK: - Can Resolve Tests

    func testCanResolveToADS() async {
        // Bibcode
        var canResolve = await resolver.canResolve([.bibcode: "2020ApJ...123...45A"], to: .ads)
        XCTAssertTrue(canResolve)

        // DOI
        canResolve = await resolver.canResolve([.doi: "10.1234/test"], to: .ads)
        XCTAssertTrue(canResolve)

        // arXiv
        canResolve = await resolver.canResolve([.arxiv: "2301.12345"], to: .ads)
        XCTAssertTrue(canResolve)

        // S2 only - not supported
        canResolve = await resolver.canResolve([.semanticScholar: "abc123"], to: .ads)
        XCTAssertFalse(canResolve)
    }

    // MARK: - Preferred Identifier Tests

    func testPreferredIdentifierForADS() async {
        // Bibcode is most preferred
        var result = await resolver.preferredIdentifier(
            from: [.bibcode: "2020ApJ...123...45A", .doi: "10.1234/test"],
            for: .ads
        )
        XCTAssertEqual(result?.type, .bibcode)

        // DOI is second choice
        result = await resolver.preferredIdentifier(
            from: [.doi: "10.1234/test", .arxiv: "2301.12345"],
            for: .ads
        )
        XCTAssertEqual(result?.type, .doi)

        // arXiv is third choice
        result = await resolver.preferredIdentifier(
            from: [.arxiv: "2301.12345"],
            for: .ads
        )
        XCTAssertEqual(result?.type, .arxiv)
    }

    // MARK: - Cache Tests

    func testCacheHit() async {
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]

        // First resolution
        _ = await resolver.resolve(identifiers)

        // Second resolution should use cache
        let resolved = await resolver.resolve(identifiers)
        XCTAssertEqual(resolved.semanticScholarID, "DOI:10.1234/test")

        let cacheSize = await resolver.cacheSize
        XCTAssertEqual(cacheSize, 1)
    }

    func testClearCache() async {
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]
        _ = await resolver.resolve(identifiers)

        var cacheSize = await resolver.cacheSize
        XCTAssertEqual(cacheSize, 1)

        await resolver.clearCache()

        cacheSize = await resolver.cacheSize
        XCTAssertEqual(cacheSize, 0)
    }

    func testCacheEviction() async {
        let smallCacheResolver = IdentifierResolver(maxCacheSize: 10)

        // Fill cache beyond limit
        for i in 0..<15 {
            let identifiers: [IdentifierType: String] = [.doi: "10.1234/test\(i)"]
            _ = await smallCacheResolver.resolve(identifiers)
        }

        let cacheSize = await smallCacheResolver.cacheSize
        XCTAssertLessThanOrEqual(cacheSize, 10)
    }

    // MARK: - Identifier Type Extension Tests

    func testIdentifierTypeURLPrefix() {
        XCTAssertEqual(IdentifierType.doi.urlPrefix, "https://doi.org/")
        XCTAssertEqual(IdentifierType.arxiv.urlPrefix, "https://arxiv.org/abs/")
        XCTAssertEqual(IdentifierType.pmid.urlPrefix, "https://pubmed.ncbi.nlm.nih.gov/")
        XCTAssertEqual(IdentifierType.bibcode.urlPrefix, "https://ui.adsabs.harvard.edu/abs/")
        XCTAssertEqual(IdentifierType.semanticScholar.urlPrefix, "https://www.semanticscholar.org/paper/")
        XCTAssertEqual(IdentifierType.openAlex.urlPrefix, "https://openalex.org/works/")
    }

    func testIdentifierTypeURL() {
        let doiURL = IdentifierType.doi.url(for: "10.1234/test")
        XCTAssertEqual(doiURL?.absoluteString, "https://doi.org/10.1234/test")

        let arxivURL = IdentifierType.arxiv.url(for: "2301.12345")
        XCTAssertEqual(arxivURL?.absoluteString, "https://arxiv.org/abs/2301.12345")

        let bibcodeURL = IdentifierType.bibcode.url(for: "2020ApJ...123...45A")
        XCTAssertEqual(bibcodeURL?.absoluteString, "https://ui.adsabs.harvard.edu/abs/2020ApJ...123...45A")
    }

    // MARK: - Empty Identifiers

    func testResolveEmptyIdentifiers() async {
        let identifiers: [IdentifierType: String] = [:]
        let resolved = await resolver.resolve(identifiers)
        XCTAssertTrue(resolved.isEmpty)
    }

    func testCanResolveEmptyIdentifiers() async {
        let canResolve = await resolver.canResolve([:], to: .ads)
        XCTAssertFalse(canResolve)
    }

    func testPreferredIdentifierEmptyIdentifiers() async {
        let result = await resolver.preferredIdentifier(from: [:], for: .ads)
        XCTAssertNil(result)
    }
}
