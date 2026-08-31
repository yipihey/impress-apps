//
//  PDFURLResolverV2Tests.swift
//  PublicationManagerCoreTests
//
//  The resolver's DOI → arXiv-id derivation. This is the Swift mirror of
//  `extract_arxiv_id` in `crates/imbib-core/src/publishers/rules.rs` — the
//  two prefix lists must stay in step, so extend both test suites together.
//

import XCTest
@testable import PublicationManagerCore

final class PDFURLResolverV2Tests: XCTestCase {

    func testArXivOwnDOIExtracts() {
        XCTAssertEqual(
            PDFURLResolverV2.extractArXivIDFromDOI("10.48550/arXiv.2401.12345"),
            "2401.12345"
        )
        // Prefix match is case-insensitive; the suffix keeps its casing.
        XCTAssertEqual(
            PDFURLResolverV2.extractArXivIDFromDOI("10.48550/ARXIV.2401.12345"),
            "2401.12345"
        )
    }

    func testOverlayJournalDOIExtracts() {
        // The Open Journal of Astrophysics is an arXiv overlay: the DOI
        // suffix IS the arXiv id. Its own hosted PDF endpoint serves empty
        // bodies, so this derivation is what makes such papers fetchable.
        XCTAssertEqual(
            PDFURLResolverV2.extractArXivIDFromDOI("10.21105/astro.2106.03528"),
            "2106.03528"
        )
    }

    func testNonEmbeddingDOIsExtractNothing() {
        // JOSS shares the 10.21105 registrant but is not an arXiv overlay.
        XCTAssertNil(PDFURLResolverV2.extractArXivIDFromDOI("10.21105/joss.01234"))
        XCTAssertNil(PDFURLResolverV2.extractArXivIDFromDOI("10.1038/nature12373"))
        XCTAssertNil(PDFURLResolverV2.extractArXivIDFromDOI(""))
    }
}
