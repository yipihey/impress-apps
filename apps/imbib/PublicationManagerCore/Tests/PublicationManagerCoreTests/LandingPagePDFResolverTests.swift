//
//  LandingPagePDFResolverTests.swift
//  PublicationManagerCoreTests
//
//  Tests for landing page PDF resolution and publisher HTML parsing.
//

import XCTest
@testable import PublicationManagerCore

final class LandingPagePDFResolverTests: XCTestCase {

    // MARK: - PublisherHTMLParsers Tests

    func testParserID_IOPScience_returnsIOP() {
        let parsers = PublisherHTMLParsers()
        XCTAssertEqual(parsers.parserID(for: "iopscience.iop.org"), "iop")
    }

    func testParserID_APS_returnsAPS() {
        let parsers = PublisherHTMLParsers()
        XCTAssertEqual(parsers.parserID(for: "journals.aps.org"), "aps")
        XCTAssertEqual(parsers.parserID(for: "link.aps.org"), "aps")
    }

    func testParserID_Nature_returnsNature() {
        let parsers = PublisherHTMLParsers()
        XCTAssertEqual(parsers.parserID(for: "www.nature.com"), "nature")
        XCTAssertEqual(parsers.parserID(for: "nature.com"), "nature")
    }

    func testParserID_Oxford_returnsOxford() {
        let parsers = PublisherHTMLParsers()
        XCTAssertEqual(parsers.parserID(for: "academic.oup.com"), "oxford")
    }

    func testParserID_Elsevier_returnsElsevier() {
        let parsers = PublisherHTMLParsers()
        XCTAssertEqual(parsers.parserID(for: "www.sciencedirect.com"), "elsevier")
    }

    func testParserID_Unknown_returnsGeneric() {
        let parsers = PublisherHTMLParsers()
        XCTAssertEqual(parsers.parserID(for: "unknown-publisher.com"), "generic")
    }

    // MARK: - Meta Tag Extraction Tests

    func testParse_citationPdfUrl_extractsURL() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <head>
        <meta name="citation_pdf_url" content="https://example.com/paper.pdf">
        </head>
        </html>
        """
        let baseURL = URL(string: "https://example.com/article")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "example.com")

        XCTAssertEqual(result?.absoluteString, "https://example.com/paper.pdf")
    }

    func testParse_citationPdfUrl_contentBeforeName_extractsURL() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <head>
        <meta content="https://example.com/paper.pdf" name="citation_pdf_url">
        </head>
        </html>
        """
        let baseURL = URL(string: "https://example.com/article")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "example.com")

        XCTAssertEqual(result?.absoluteString, "https://example.com/paper.pdf")
    }

    // MARK: - IOP Parser Tests

    func testParse_IOP_articleURL_appendsPDF() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <head>
        <meta name="citation_pdf_url" content="https://iopscience.iop.org/article/10.3847/1538-4357/ac5c5b/pdf">
        </head>
        </html>
        """
        let baseURL = URL(string: "https://iopscience.iop.org/article/10.3847/1538-4357/ac5c5b")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "iopscience.iop.org")

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.absoluteString.contains("/pdf") ?? false)
    }

    func testParse_IOP_noMetaTag_constructsFromPath() {
        let parsers = PublisherHTMLParsers()
        let html = "<html><body>Article content</body></html>"
        let baseURL = URL(string: "https://iopscience.iop.org/article/10.3847/1538-4357/ac5c5b")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "iopscience.iop.org")

        XCTAssertEqual(result?.absoluteString, "https://iopscience.iop.org/article/10.3847/1538-4357/ac5c5b/pdf")
    }

    // MARK: - APS Parser Tests

    func testParse_APS_abstractURL_convertsToPDF() {
        let parsers = PublisherHTMLParsers()
        let html = "<html><body>Article content</body></html>"
        let baseURL = URL(string: "https://journals.aps.org/prd/abstract/10.1103/PhysRevD.105.023520")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "journals.aps.org")

        XCTAssertEqual(result?.absoluteString, "https://journals.aps.org/prd/pdf/10.1103/PhysRevD.105.023520")
    }

    // MARK: - Nature Parser Tests

    func testParse_Nature_articlesURL_appendsPDF() {
        let parsers = PublisherHTMLParsers()
        let html = "<html><body>Article content</body></html>"
        let baseURL = URL(string: "https://www.nature.com/articles/s41586-024-07386-0")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "www.nature.com")

        XCTAssertEqual(result?.absoluteString, "https://www.nature.com/articles/s41586-024-07386-0.pdf")
    }

    func testParse_Nature_dataTrackAttribute_extractsURL() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <body>
        <a data-track-action="download pdf" href="https://www.nature.com/articles/s41586-024-07386-0.pdf">Download PDF</a>
        </body>
        </html>
        """
        let baseURL = URL(string: "https://www.nature.com/articles/s41586-024-07386-0")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "www.nature.com")

        XCTAssertEqual(result?.absoluteString, "https://www.nature.com/articles/s41586-024-07386-0.pdf")
    }

    // MARK: - Science Parser Tests

    func testParse_Science_doiURL_constructsPDFPath() {
        let parsers = PublisherHTMLParsers()
        let html = "<html><body>Article content</body></html>"
        let baseURL = URL(string: "https://www.science.org/doi/10.1126/science.abc1234")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "www.science.org")

        XCTAssertEqual(result?.absoluteString, "https://www.science.org/doi/pdf/10.1126/science.abc1234")
    }

    // MARK: - Generic Parser Tests

    func testParse_generic_downloadPDFLink_extractsURL() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <body>
        <a href="/download/paper.pdf">Download PDF</a>
        </body>
        </html>
        """
        let baseURL = URL(string: "https://example.com/article/123")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "example.com")

        XCTAssertEqual(result?.absoluteString, "https://example.com/download/paper.pdf")
    }

    func testParse_generic_pdfExtensionLink_extractsURL() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <body>
        <p>Read our paper</p>
        <a href="https://cdn.example.com/papers/fulltext.pdf">Full Text</a>
        </body>
        </html>
        """
        let baseURL = URL(string: "https://example.com/article/123")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "example.com")

        XCTAssertEqual(result?.absoluteString, "https://cdn.example.com/papers/fulltext.pdf")
    }

    // MARK: - HTML Entity Decoding Tests

    func testParse_decodesHTMLEntities() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <head>
        <meta name="citation_pdf_url" content="https://example.com/article?id=123&amp;format=pdf">
        </head>
        </html>
        """
        let baseURL = URL(string: "https://example.com/article")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "example.com")

        XCTAssertEqual(result?.absoluteString, "https://example.com/article?id=123&format=pdf")
    }

    // MARK: - Relative URL Tests

    func testParse_relativePath_resolvesAgainstBaseURL() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <head>
        <meta name="citation_pdf_url" content="/papers/123/fulltext.pdf">
        </head>
        </html>
        """
        let baseURL = URL(string: "https://example.com/articles/123")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "example.com")

        XCTAssertEqual(result?.absoluteString, "https://example.com/papers/123/fulltext.pdf")
    }

    // MARK: - Edge Cases

    func testParse_emptyHTML_returnsNil() {
        let parsers = PublisherHTMLParsers()
        let baseURL = URL(string: "https://example.com/article")!

        let result = parsers.parse(html: "", baseURL: baseURL, publisherHost: "example.com")

        XCTAssertNil(result)
    }

    func testParse_noPDFLinks_returnsNil() {
        let parsers = PublisherHTMLParsers()
        let html = """
        <html>
        <body>
        <a href="/about">About</a>
        <a href="/contact">Contact</a>
        </body>
        </html>
        """
        let baseURL = URL(string: "https://example.com/article")!

        let result = parsers.parse(html: html, baseURL: baseURL, publisherHost: "example.com")

        XCTAssertNil(result)
    }

    // MARK: - Publisher Rule Scraping Support Tests

    func testPublisherRule_supportsLandingPageScraping_defaultTrue() {
        let rule = PublisherRule(
            id: "test",
            name: "Test Publisher",
            doiPrefixes: ["10.1234/"]
        )

        XCTAssertTrue(rule.supportsLandingPageScraping)
    }

    func testPublisherRule_htmlParserID_canBeSet() {
        let rule = PublisherRule(
            id: "test",
            name: "Test Publisher",
            doiPrefixes: ["10.1234/"],
            htmlParserID: "custom-parser"
        )

        XCTAssertEqual(rule.htmlParserID, "custom-parser")
    }

    func testDefaultRules_IOPHasHtmlParserID() {
        guard let rule = DefaultPublisherRules.rule(forDOI: "10.3847/1538-4357/ac5c5b") else {
            XCTFail("Expected to find IOP rule")
            return
        }

        XCTAssertEqual(rule.htmlParserID, "iop")
        XCTAssertTrue(rule.supportsLandingPageScraping)
    }

    func testDefaultRules_arXivDisablesLandingPageScraping() {
        guard let rule = DefaultPublisherRules.rule(forDOI: "10.48550/arXiv.2301.12345") else {
            XCTFail("Expected to find arXiv rule")
            return
        }

        XCTAssertFalse(rule.supportsLandingPageScraping)
    }

    // MARK: - ResolvedPDFSourceType Tests

    func testResolvedPDFSourceType_landingPage_displayName() {
        let source = ResolvedPDFSource(
            type: .landingPage,
            url: URL(string: "https://example.com/paper.pdf")!,
            name: "Test Publisher"
        )

        // landingPage should display as "Publisher" (same as .publisher)
        XCTAssertEqual(ResolvedPDFSourceType.landingPage.displayName, "Publisher")
        XCTAssertEqual(source.displayName, "Test Publisher")
    }
}
