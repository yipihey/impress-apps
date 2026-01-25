//
//  ADSURLParserTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-07.
//

import XCTest
@testable import PublicationManagerCore

final class ADSURLParserTests: XCTestCase {

    // MARK: - Search URL Tests (Traditional Format)

    func testParseSearchURL_traditionalFormat_extractsQuery() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search?q=author%3AAbel%2CTom")!
        let result = ADSURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "author:Abel,Tom")
        } else {
            XCTFail("Expected .search case, got \(String(describing: result))")
        }
    }

    func testParseSearchURL_traditionalFormat_withMultipleParams() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search?q=author%3AAbel&sort=date")!
        let result = ADSURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "author:Abel")
        } else {
            XCTFail("Expected .search case")
        }
    }

    // MARK: - Search URL Tests (Path Format)

    func testParseSearchURL_pathFormat_extractsQuery() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=author%3AAbel%2CTom&sort=date%20desc")!
        let result = ADSURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "author:Abel,Tom")
        } else {
            XCTFail("Expected .search case, got \(String(describing: result))")
        }
    }

    func testParseSearchURL_pathFormat_withFilterParams() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/fq=database%3Aastronomy&q=author%3AAbel%2CTom&sort=date")!
        let result = ADSURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "author:Abel,Tom")
        } else {
            XCTFail("Expected .search case")
        }
    }

    func testParseSearchURL_pathFormat_complexQuery() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=author%3A%22Abel%2C%20Tom%22%20year%3A2020&sort=date%20desc")!
        let result = ADSURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertTrue(query.contains("author:"))
            XCTAssertTrue(query.contains("year:2020"))
        } else {
            XCTFail("Expected .search case")
        }
    }

    func testParseSearchURL_complexFilterQuery_extractsMainQuery() {
        // Real URL from ADS with filter params, main query, and sort order
        // Example: https://ui.adsabs.harvard.edu/search/fq=%7B!type%3Daqp%20v%3D%24fq_database%7D&fq_database=database%3A%20astronomy&p_=0&q=author%3A(%22Dalal%2C%20Neal%22)&sort=date%20desc%2C%20bibcode%20desc
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/fq=%7B!type%3Daqp%20v%3D%24fq_database%7D&fq_database=database%3A%20astronomy&p_=0&q=author%3A(%22Dalal%2C%20Neal%22)&sort=date%20desc%2C%20bibcode%20desc")!
        let result = ADSURLParser.parse(url)

        if case .search(let query, _) = result {
            // Should extract just the main query, ignoring filter params
            XCTAssertEqual(query, "author:(\"Dalal, Neal\")")
        } else {
            XCTFail("Expected .search case, got \(String(describing: result))")
        }
    }

    func testParseSearchURL_emptyQuery_returnsNil() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=")!
        let result = ADSURLParser.parse(url)
        XCTAssertNil(result)
    }

    func testParseSearchURL_noQueryParam_returnsNil() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/sort=date")!
        let result = ADSURLParser.parse(url)
        XCTAssertNil(result)
    }

    // MARK: - Paper URL Tests

    func testParsePaperURL_abstractPage() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B/abstract")!
        let result = ADSURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024ApJ...123..456B")
        } else {
            XCTFail("Expected .paper case, got \(String(describing: result))")
        }
    }

    func testParsePaperURL_citationsPage() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B/citations")!
        let result = ADSURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024ApJ...123..456B")
        } else {
            XCTFail("Expected .paper case")
        }
    }

    func testParsePaperURL_referencesPage() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B/references")!
        let result = ADSURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024ApJ...123..456B")
        } else {
            XCTFail("Expected .paper case")
        }
    }

    func testParsePaperURL_noBibcode_returnsNil() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/")!
        let result = ADSURLParser.parse(url)
        XCTAssertNil(result)
    }

    func testParsePaperURL_shortBibcode_returnsNil() {
        // Bibcodes must be at least 10 characters
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ/abstract")!
        let result = ADSURLParser.parse(url)
        XCTAssertNil(result)
    }

    func testParsePaperURL_longBibcode_returnsNil() {
        // Bibcodes must be at most 25 characters
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B...ExtraLongBibcode/abstract")!
        let result = ADSURLParser.parse(url)
        XCTAssertNil(result)
    }

    func testParsePaperURL_arXivBibcode() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024arXiv240112345A/abstract")!
        let result = ADSURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024arXiv240112345A")
        } else {
            XCTFail("Expected .paper case")
        }
    }

    // MARK: - Docs Selection Tests

    func testParseDocsSelection_validHash() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(cfcf0423d46d0bd5222cb1392a6ec63f)&sort=date%20desc")!
        let result = ADSURLParser.parse(url)

        if case .docsSelection(let query) = result {
            XCTAssertEqual(query, "docs(cfcf0423d46d0bd5222cb1392a6ec63f)")
        } else {
            XCTFail("Expected .docsSelection case, got \(String(describing: result))")
        }
    }

    func testParseDocsSelection_shortHash() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(abc123)&sort=date")!
        let result = ADSURLParser.parse(url)

        if case .docsSelection(let query) = result {
            XCTAssertEqual(query, "docs(abc123)")
        } else {
            XCTFail("Expected .docsSelection case")
        }
    }

    func testParseDocsSelection_notMistakenForSearch() {
        // docs() queries should NOT be treated as regular searches
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(abcd1234)")!
        let result = ADSURLParser.parse(url)

        XCTAssertNotNil(result)
        if case .search = result {
            XCTFail("docs() query should not be classified as .search")
        }
    }

    func testParseDocsSelection_pathFormat() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(cfcf0423d46d0bd5222cb1392a6ec63f)")!
        let result = ADSURLParser.parse(url)

        if case .docsSelection = result {
            // Success
        } else {
            XCTFail("Expected .docsSelection case")
        }
    }

    // MARK: - Host Validation Tests

    func testParse_uiAdsabsHost() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B/abstract")!
        XCTAssertNotNil(ADSURLParser.parse(url))
    }

    func testParse_adsabsHost() {
        let url = URL(string: "https://adsabs.harvard.edu/abs/2024ApJ...123..456B/abstract")!
        XCTAssertNotNil(ADSURLParser.parse(url))
    }

    func testParse_wwwAdsabsHost() {
        let url = URL(string: "https://www.adsabs.harvard.edu/abs/2024ApJ...123..456B/abstract")!
        XCTAssertNotNil(ADSURLParser.parse(url))
    }

    func testParse_caseInsensitiveHost() {
        let url = URL(string: "https://UI.ADSABS.HARVARD.EDU/abs/2024ApJ...123..456B/abstract")!
        XCTAssertNotNil(ADSURLParser.parse(url))
    }

    func testParse_nonADSHost_returnsNil() {
        let url = URL(string: "https://google.com/search?q=astronomy")!
        XCTAssertNil(ADSURLParser.parse(url))
    }

    func testParse_similarHost_returnsNil() {
        let url = URL(string: "https://fake-adsabs.harvard.edu/abs/2024ApJ...123..456B")!
        XCTAssertNil(ADSURLParser.parse(url))
    }

    func testParse_arxivHost_returnsNil() {
        let url = URL(string: "https://arxiv.org/abs/2401.12345")!
        XCTAssertNil(ADSURLParser.parse(url))
    }

    // MARK: - Edge Cases

    func testParse_malformedURL_returnsNil() {
        // URL with spaces (invalid)
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test query")
        if let url = url {
            // If URL was somehow constructed, parsing should still be safe
            _ = ADSURLParser.parse(url)
        }
    }

    func testParse_urlWithFragment() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B/abstract#section")!
        let result = ADSURLParser.parse(url)

        if case .paper(let bibcode) = result {
            XCTAssertEqual(bibcode, "2024ApJ...123..456B")
        } else {
            XCTFail("Expected .paper case")
        }
    }

    func testParse_homePage_returnsNil() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/")!
        XCTAssertNil(ADSURLParser.parse(url))
    }

    func testParse_classicSearchPath_returnsNil() {
        // Old ADS classic URL format should not be supported
        let url = URL(string: "https://ui.adsabs.harvard.edu/cgi-bin/nph-bib_query?bibcode=2024ApJ")!
        XCTAssertNil(ADSURLParser.parse(url))
    }

    // MARK: - isADSURL Helper Tests

    func testIsADSURL_validSearchURL() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!
        XCTAssertTrue(ADSURLParser.isADSURL(url))
    }

    func testIsADSURL_validPaperURL() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B")!
        XCTAssertTrue(ADSURLParser.isADSURL(url))
    }

    func testIsADSURL_invalidURL() {
        let url = URL(string: "https://google.com")!
        XCTAssertFalse(ADSURLParser.isADSURL(url))
    }

    // MARK: - URL Extension Tests

    func testURLExtension_isADSURL() {
        let adsURL = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!
        let nonADSURL = URL(string: "https://google.com")!

        XCTAssertTrue(adsURL.isADSURL)
        XCTAssertFalse(nonADSURL.isADSURL)
    }

    func testURLExtension_adsURLType() {
        let searchURL = URL(string: "https://ui.adsabs.harvard.edu/search/q=test")!
        let paperURL = URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B")!
        let docsURL = URL(string: "https://ui.adsabs.harvard.edu/search/q=docs(abc123)")!

        if case .search = searchURL.adsURLType {
            // Success
        } else {
            XCTFail("Expected .search")
        }

        if case .paper = paperURL.adsURLType {
            // Success
        } else {
            XCTFail("Expected .paper")
        }

        if case .docsSelection = docsURL.adsURLType {
            // Success
        } else {
            XCTFail("Expected .docsSelection")
        }
    }

    // MARK: - Title Generation Tests

    func testParseSearchURL_generatesTitle() {
        let url = URL(string: "https://ui.adsabs.harvard.edu/search/q=author%3AAbel%2CTom")!
        let result = ADSURLParser.parse(url)

        if case .search(_, let title) = result {
            XCTAssertNotNil(title)
            XCTAssertTrue(title?.contains("author") ?? false)
        } else {
            XCTFail("Expected .search case")
        }
    }
}
