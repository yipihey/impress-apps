//
//  SciXURLParserTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-08.
//

import XCTest
@testable import PublicationManagerCore

final class SciXURLParserTests: XCTestCase {

    // MARK: - Search URL Tests (Traditional Format)

    func testParseSearchURL_traditionalFormat_extractsQuery() {
        let url = URL(string: "https://scixplorer.org/search?q=author%3AAbel%2CTom")!
        let result = SciXURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "author:Abel,Tom")
        } else {
            XCTFail("Expected .search case, got \(String(describing: result))")
        }
    }

    func testParseSearchURL_traditionalFormat_withMultipleParams() {
        let url = URL(string: "https://scixplorer.org/search?q=author%3AAbel&sort=date")!
        let result = SciXURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "author:Abel")
        } else {
            XCTFail("Expected .search case")
        }
    }

    // MARK: - Search URL Tests (Path Format)

    func testParseSearchURL_pathFormat_extractsQuery() {
        let url = URL(string: "https://scixplorer.org/search/q=author%3AAbel%2CTom&sort=date%20desc")!
        let result = SciXURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "author:Abel,Tom")
        } else {
            XCTFail("Expected .search case, got \(String(describing: result))")
        }
    }

    func testParseSearchURL_pathFormat_withFilterParams() {
        let url = URL(string: "https://scixplorer.org/search/fq=database%3Aastronomy&q=author%3AAbel%2CTom&sort=date")!
        let result = SciXURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "author:Abel,Tom")
        } else {
            XCTFail("Expected .search case")
        }
    }

    func testParseSearchURL_pathFormat_complexQuery() {
        let url = URL(string: "https://scixplorer.org/search/q=author%3A%22Abel%2C%20Tom%22%20year%3A2020&sort=date%20desc")!
        let result = SciXURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertTrue(query.contains("author:"))
            XCTAssertTrue(query.contains("year:2020"))
        } else {
            XCTFail("Expected .search case")
        }
    }

    func testParseSearchURL_emptyQuery_returnsNil() {
        let url = URL(string: "https://scixplorer.org/search/q=")!
        let result = SciXURLParser.parse(url)
        XCTAssertNil(result)
    }

    func testParseSearchURL_noQueryParam_returnsNil() {
        let url = URL(string: "https://scixplorer.org/search/sort=date")!
        let result = SciXURLParser.parse(url)
        XCTAssertNil(result)
    }

    // MARK: - Paper URL Tests

    func testParsePaperURL_abstractPage() {
        let url = URL(string: "https://scixplorer.org/abs/2024ApJ...123..456B/abstract")!
        let result = SciXURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024ApJ...123..456B")
        } else {
            XCTFail("Expected .paper case, got \(String(describing: result))")
        }
    }

    func testParsePaperURL_citationsPage() {
        let url = URL(string: "https://scixplorer.org/abs/2024ApJ...123..456B/citations")!
        let result = SciXURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024ApJ...123..456B")
        } else {
            XCTFail("Expected .paper case")
        }
    }

    func testParsePaperURL_referencesPage() {
        let url = URL(string: "https://scixplorer.org/abs/2024ApJ...123..456B/references")!
        let result = SciXURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024ApJ...123..456B")
        } else {
            XCTFail("Expected .paper case")
        }
    }

    func testParsePaperURL_noBibcode_returnsNil() {
        let url = URL(string: "https://scixplorer.org/abs/")!
        let result = SciXURLParser.parse(url)
        XCTAssertNil(result)
    }

    func testParsePaperURL_shortBibcode_returnsNil() {
        // Bibcodes must be at least 10 characters
        let url = URL(string: "https://scixplorer.org/abs/2024ApJ/abstract")!
        let result = SciXURLParser.parse(url)
        XCTAssertNil(result)
    }

    func testParsePaperURL_longBibcode_returnsNil() {
        // Bibcodes must be at most 25 characters
        let url = URL(string: "https://scixplorer.org/abs/2024ApJ...123..456B...ExtraLongBibcode/abstract")!
        let result = SciXURLParser.parse(url)
        XCTAssertNil(result)
    }

    func testParsePaperURL_arXivBibcode() {
        let url = URL(string: "https://scixplorer.org/abs/2024arXiv240112345A/abstract")!
        let result = SciXURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024arXiv240112345A")
        } else {
            XCTFail("Expected .paper case")
        }
    }

    // MARK: - Docs Selection Tests

    func testParseDocsSelection_validHash() {
        let url = URL(string: "https://scixplorer.org/search/q=docs(cfcf0423d46d0bd5222cb1392a6ec63f)&sort=date%20desc")!
        let result = SciXURLParser.parse(url)

        if case .docsSelection(let query) = result {
            XCTAssertEqual(query, "docs(cfcf0423d46d0bd5222cb1392a6ec63f)")
        } else {
            XCTFail("Expected .docsSelection case, got \(String(describing: result))")
        }
    }

    func testParseDocsSelection_shortHash() {
        let url = URL(string: "https://scixplorer.org/search/q=docs(abc123)&sort=date")!
        let result = SciXURLParser.parse(url)

        if case .docsSelection(let query) = result {
            XCTAssertEqual(query, "docs(abc123)")
        } else {
            XCTFail("Expected .docsSelection case")
        }
    }

    func testParseDocsSelection_notMistakenForSearch() {
        // docs() queries should NOT be treated as regular searches
        let url = URL(string: "https://scixplorer.org/search/q=docs(abcd1234)")!
        let result = SciXURLParser.parse(url)

        XCTAssertNotNil(result)
        if case .search = result {
            XCTFail("docs() query should not be classified as .search")
        }
    }

    func testParseDocsSelection_pathFormat() {
        let url = URL(string: "https://scixplorer.org/search/q=docs(cfcf0423d46d0bd5222cb1392a6ec63f)")!
        let result = SciXURLParser.parse(url)

        if case .docsSelection = result {
            // Success
        } else {
            XCTFail("Expected .docsSelection case")
        }
    }

    // MARK: - Host Validation Tests

    func testParse_scixplorerHost() {
        let url = URL(string: "https://scixplorer.org/abs/2024ApJ...123..456B/abstract")!
        XCTAssertNotNil(SciXURLParser.parse(url))
    }

    func testParse_wwwScixplorerHost() {
        let url = URL(string: "https://www.scixplorer.org/abs/2024ApJ...123..456B/abstract")!
        XCTAssertNotNil(SciXURLParser.parse(url))
    }

    func testParse_caseInsensitiveHost() {
        let url = URL(string: "https://SCIXPLORER.ORG/abs/2024ApJ...123..456B/abstract")!
        XCTAssertNotNil(SciXURLParser.parse(url))
    }

    func testParse_nonSciXHost_returnsNil() {
        let url = URL(string: "https://google.com/search?q=astronomy")!
        XCTAssertNil(SciXURLParser.parse(url))
    }

    func testParse_adsHost_returnsNil() {
        // SciX parser should NOT match ADS URLs
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B")!
        XCTAssertNil(SciXURLParser.parse(url))
    }

    func testParse_arxivHost_returnsNil() {
        let url = URL(string: "https://arxiv.org/abs/2401.12345")!
        XCTAssertNil(SciXURLParser.parse(url))
    }

    // MARK: - Edge Cases

    func testParse_urlWithFragment() {
        let url = URL(string: "https://scixplorer.org/abs/2024ApJ...123..456B/abstract#section")!
        let result = SciXURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024ApJ...123..456B")
        } else {
            XCTFail("Expected .paper case")
        }
    }

    func testParse_homePage_returnsNil() {
        let url = URL(string: "https://scixplorer.org/")!
        XCTAssertNil(SciXURLParser.parse(url))
    }

    // MARK: - isSciXURL Helper Tests

    func testIsSciXURL_validSearchURL() {
        let url = URL(string: "https://scixplorer.org/search/q=test")!
        XCTAssertTrue(SciXURLParser.isSciXURL(url))
    }

    func testIsSciXURL_validPaperURL() {
        let url = URL(string: "https://scixplorer.org/abs/2024ApJ...123..456B")!
        XCTAssertTrue(SciXURLParser.isSciXURL(url))
    }

    func testIsSciXURL_invalidURL() {
        let url = URL(string: "https://google.com")!
        XCTAssertFalse(SciXURLParser.isSciXURL(url))
    }

    // MARK: - URL Extension Tests

    func testURLExtension_isSciXURL() {
        let scixURL = URL(string: "https://scixplorer.org/search/q=test")!
        let nonSciXURL = URL(string: "https://google.com")!

        XCTAssertTrue(scixURL.isSciXURL)
        XCTAssertFalse(nonSciXURL.isSciXURL)
    }

    func testURLExtension_scixURLType() {
        let searchURL = URL(string: "https://scixplorer.org/search/q=test")!
        let paperURL = URL(string: "https://scixplorer.org/abs/2024ApJ...123..456B")!
        let docsURL = URL(string: "https://scixplorer.org/search/q=docs(abc123)")!

        if case .search = searchURL.scixURLType {
            // Success
        } else {
            XCTFail("Expected .search")
        }

        if case .paper = paperURL.scixURLType {
            // Success
        } else {
            XCTFail("Expected .paper")
        }

        if case .docsSelection = docsURL.scixURLType {
            // Success
        } else {
            XCTFail("Expected .docsSelection")
        }
    }

    // MARK: - Title Generation Tests

    func testParseSearchURL_generatesTitle() {
        let url = URL(string: "https://scixplorer.org/search/q=author%3AAbel%2CTom")!
        let result = SciXURLParser.parse(url)

        if case .search(_, let title) = result {
            XCTAssertNotNil(title)
            XCTAssertTrue(title?.contains("author") ?? false)
        } else {
            XCTFail("Expected .search case")
        }
    }
}
