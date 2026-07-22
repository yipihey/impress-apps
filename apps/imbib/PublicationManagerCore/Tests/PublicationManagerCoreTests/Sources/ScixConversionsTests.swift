//
//  ScixConversionsTests.swift
//  PublicationManagerCoreTests
//
//  Deterministic tests for the ScixPaper/ScixFfiError → domain-type conversion
//  layer (ScixConversions.swift). This is the durable replacement for the old
//  SciX/ADS "source" tests, which mocked URLSession responses — dead weight
//  since the sources migrated to the Rust FFI (which ignores URLProtocol mocks
//  and reqwests inside Rust). All the parsing/mapping logic those tests meant
//  to exercise now lives in these pure functions, so we feed fixtures straight
//  through them: no network, no token, no skips.
//

import XCTest
import ImpressScixCore
@testable import PublicationManagerCore

final class ScixConversionsTests: XCTestCase {

    // MARK: - Fixtures

    private func makePaper(
        bibcode: String = "2024ApJ...123..456A",
        title: String = "Test Paper",
        authors: [String] = ["Author, Test"],
        year: Int32? = 2024,
        publication: String? = "The Astrophysical Journal",
        doi: String? = nil,
        arxivId: String? = nil,
        abstractText: String? = nil,
        citationCount: Int32? = nil,
        pdfLinks: [ScixPdfLink] = [],
        webUrl: String = "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456A",
        isOpenAccess: Bool = false,
        doctype: String? = "article"
    ) -> ScixPaper {
        ScixPaper(
            bibcode: bibcode,
            title: title,
            authors: authors.map { ScixAuthor(name: $0, familyName: $0, givenName: nil) },
            year: year,
            publication: publication,
            doi: doi,
            arxivId: arxivId,
            abstractText: abstractText,
            citationCount: citationCount,
            pdfLinks: pdfLinks,
            webUrl: webUrl,
            isOpenAccess: isOpenAccess,
            doctype: doctype
        )
    }

    // MARK: - toSearchResult: core field mapping

    func testToSearchResult_mapsCoreFields() {
        let paper = makePaper(
            bibcode: "2024ApJ...123..456A",
            title: "A Test Paper",
            authors: ["Smith, J.", "Doe, A."],
            year: 2024,
            publication: "The Astrophysical Journal",
            doi: "10.1234/test",
            arxivId: "2401.12345",
            abstractText: "An abstract."
        )
        let result = paper.toSearchResult(sourceID: "scix")

        XCTAssertEqual(result.id, "2024ApJ...123..456A")
        XCTAssertEqual(result.bibcode, "2024ApJ...123..456A")
        XCTAssertEqual(result.sourceID, "scix")
        XCTAssertEqual(result.title, "A Test Paper")
        XCTAssertEqual(result.authors, ["Smith, J.", "Doe, A."])
        XCTAssertEqual(result.year, 2024)
        XCTAssertEqual(result.venue, "The Astrophysical Journal")
        XCTAssertEqual(result.abstract, "An abstract.")
        XCTAssertEqual(result.doi, "10.1234/test")
        XCTAssertEqual(result.arxivID, "2401.12345")
    }

    func testToSearchResult_nilYearStaysNil() {
        let result = makePaper(year: nil).toSearchResult()
        XCTAssertNil(result.year)
    }

    // MARK: - toSearchResult: web URLs differ by source

    func testToSearchResult_scixWebURL_usesScixplorer() {
        let result = makePaper(bibcode: "2024ApJ...123..456A").toSearchResult(sourceID: "scix")
        XCTAssertEqual(result.sourceID, "scix")
        XCTAssertEqual(result.webURL?.absoluteString, "https://scixplorer.org/abs/2024ApJ...123..456A")
    }

    func testToSearchResult_adsWebURL_usesPaperWebUrl() {
        let result = makePaper(webUrl: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456A")
            .toSearchResult(sourceID: "ads")
        XCTAssertEqual(result.sourceID, "ads")
        XCTAssertEqual(result.webURL?.absoluteString, "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456A")
        XCTAssertEqual(
            result.bibtexURL?.absoluteString,
            "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456A/exportcitation"
        )
    }

    // MARK: - toPdfLinks: fallback synthesis when the FFI returns no links

    func testPdfLinks_arXivFallback_preferredFirst() {
        // arXiv + DOI, no explicit links → arXiv preprint comes first, so
        // pdfURL is the arXiv PDF (mirrors the retired testParseDoc_withArXivID).
        let result = makePaper(doi: "10.1234/test", arxivId: "2401.12345").toSearchResult()
        XCTAssertEqual(result.pdfURL?.absoluteString, "https://arxiv.org/pdf/2401.12345.pdf")
        XCTAssertEqual(result.pdfLinks.first?.type, .preprint)
    }

    func testPdfLinks_doiFallback_whenNoArXiv() {
        let result = makePaper(doi: "10.1234/example.2024.12345", arxivId: nil).toSearchResult()
        XCTAssertNil(result.arxivID)
        XCTAssertEqual(result.pdfURL?.absoluteString, "https://doi.org/10.1234/example.2024.12345")
        XCTAssertEqual(result.pdfLinks.first?.type, .publisher)
    }

    func testPdfLinks_noIdentifiers_noPdfURL() {
        let result = makePaper(doi: nil, arxivId: nil).toSearchResult()
        XCTAssertNil(result.pdfURL, "A paper with neither arXiv nor DOI should have no PDF URL")
        XCTAssertTrue(result.pdfLinks.isEmpty)
    }

    // MARK: - toPdfLinks: explicit FFI link-type mapping

    func testPdfLinks_explicitLinks_mapLinkTypes() {
        let links = [
            ScixPdfLink(url: "https://arxiv.org/pdf/2401.12345.pdf", linkType: "ArXiv", label: "arXiv"),
            ScixPdfLink(url: "https://ui.adsabs.harvard.edu/scan", linkType: "AdsScan", label: "ADS Scan"),
            ScixPdfLink(url: "https://journal.example/pdf", linkType: "Publisher", label: "Publisher"),
        ]
        let result = makePaper(pdfLinks: links).toSearchResult(sourceID: "ads")

        XCTAssertEqual(result.pdfLinks.count, 3)
        XCTAssertEqual(result.pdfLinks[0].type, .preprint)   // ArXiv → preprint
        XCTAssertEqual(result.pdfLinks[1].type, .adsScan)    // AdsScan → adsScan
        XCTAssertEqual(result.pdfLinks[2].type, .publisher)  // default → publisher
        XCTAssertTrue(result.pdfLinks.allSatisfy { $0.sourceID == "ads" })
    }

    // MARK: - toPaperStub (enrichment view of a paper)

    func testToPaperStub_mapsEnrichmentFields() {
        let paper = makePaper(
            year: 2023,
            publication: "MNRAS",
            doi: "10.1093/mnras/xyz",
            arxivId: "2301.00001",
            abstractText: "The abstract.",
            citationCount: 98_000,
            isOpenAccess: true
        )
        let stub = paper.toPaperStub()

        XCTAssertEqual(stub.id, paper.bibcode)
        XCTAssertEqual(stub.year, 2023)
        XCTAssertEqual(stub.venue, "MNRAS")
        XCTAssertEqual(stub.doi, "10.1093/mnras/xyz")
        XCTAssertEqual(stub.arxivID, "2301.00001")
        XCTAssertEqual(stub.abstract, "The abstract.")
        XCTAssertEqual(stub.citationCount, 98_000)
        XCTAssertEqual(stub.isOpenAccess, true)
    }

    func testToPaperStub_notOpenAccess_isNilNotFalse() {
        // The stub carries nil (unknown) rather than false so callers don't
        // render a misleading "closed access" badge from a default.
        let stub = makePaper(isOpenAccess: false).toPaperStub()
        XCTAssertNil(stub.isOpenAccess)
    }

    func testToPaperStub_nilCitationCountStaysNil() {
        let stub = makePaper(citationCount: nil).toPaperStub()
        XCTAssertNil(stub.citationCount)
    }

    // MARK: - ScixFfiError → SourceError

    func testSourceError_unauthorized() {
        assertSourceError(.Unauthorized, isAuthRequiredFor: "scix")
    }

    func testSourceError_notFound() {
        if case .notFound = ScixFfiError.NotFound.toSourceError(sourceID: "ads") {} else {
            XCTFail("NotFound should map to .notFound")
        }
    }

    func testSourceError_rateLimited() {
        if case .rateLimited = ScixFfiError.RateLimited.toSourceError(sourceID: "ads") {} else {
            XCTFail("RateLimited should map to .rateLimited")
        }
    }

    func testSourceError_networkError() {
        let err = ScixFfiError.NetworkError(message: "boom").toSourceError(sourceID: "ads")
        if case .networkError = err {} else { XCTFail("NetworkError should map to .networkError") }
    }

    func testSourceError_apiError_mapsToParseError() {
        let err = ScixFfiError.ApiError(message: "unexpected response shape").toSourceError(sourceID: "ads")
        if case .parseError(let msg) = err {
            XCTAssertEqual(msg, "unexpected response shape")
        } else {
            XCTFail("Non-auth ApiError should map to .parseError")
        }
    }

    // MARK: - ScixFfiError → EnrichmentError

    func testEnrichmentError_unauthorized() {
        if case .authenticationRequired(let s) = ScixFfiError.Unauthorized.toEnrichmentError(sourceID: "ads") {
            XCTAssertEqual(s, "ads")
        } else {
            XCTFail("Unauthorized should map to .authenticationRequired")
        }
    }

    func testEnrichmentError_notFound() {
        if case .notFound = ScixFfiError.NotFound.toEnrichmentError(sourceID: "ads") {} else {
            XCTFail("NotFound should map to .notFound")
        }
    }

    func testEnrichmentError_apiError_mapsToParseError() {
        if case .parseError = ScixFfiError.ApiError(message: "bad json").toEnrichmentError(sourceID: "ads") {} else {
            XCTFail("Non-auth ApiError should map to .parseError")
        }
    }

    // MARK: - Helpers

    private func assertSourceError(
        _ ffi: ScixFfiError,
        isAuthRequiredFor sourceID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .authenticationRequired(let s) = ffi.toSourceError(sourceID: sourceID) {
            XCTAssertEqual(s, sourceID, file: file, line: line)
        } else {
            XCTFail("Expected .authenticationRequired(\(sourceID))", file: file, line: line)
        }
    }
}
