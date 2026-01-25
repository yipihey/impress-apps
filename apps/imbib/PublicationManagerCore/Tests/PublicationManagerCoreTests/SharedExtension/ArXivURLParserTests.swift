//
//  ArXivURLParserTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-07.
//

import XCTest
@testable import PublicationManagerCore

final class ArXivURLParserTests: XCTestCase {

    // MARK: - Paper URL Tests (New Format)

    func testParsePaperURL_newFormat_extractsArXivID() {
        let url = URL(string: "https://arxiv.org/abs/2301.12345")!
        let result = ArXivURLParser.parse(url)

        if case .paper(let arxivID) = result {
            XCTAssertEqual(arxivID, "2301.12345")
        } else {
            XCTFail("Expected paper type, got \(String(describing: result))")
        }
    }

    func testParsePaperURL_newFormatWithVersion_extractsFullID() {
        let url = URL(string: "https://arxiv.org/abs/2301.12345v2")!
        let result = ArXivURLParser.parse(url)

        if case .paper(let arxivID) = result {
            XCTAssertEqual(arxivID, "2301.12345v2")
        } else {
            XCTFail("Expected paper type, got \(String(describing: result))")
        }
    }

    func testParsePaperURL_newFormatFiveDigits_extractsArXivID() {
        let url = URL(string: "https://arxiv.org/abs/2301.00001")!
        let result = ArXivURLParser.parse(url)

        if case .paper(let arxivID) = result {
            XCTAssertEqual(arxivID, "2301.00001")
        } else {
            XCTFail("Expected paper type, got \(String(describing: result))")
        }
    }

    // MARK: - Paper URL Tests (Old Format)

    func testParsePaperURL_oldFormat_extractsArXivID() {
        let url = URL(string: "https://arxiv.org/abs/hep-th/9901001")!
        let result = ArXivURLParser.parse(url)

        if case .paper(let arxivID) = result {
            XCTAssertEqual(arxivID, "hep-th/9901001")
        } else {
            XCTFail("Expected paper type, got \(String(describing: result))")
        }
    }

    func testParsePaperURL_oldFormatWithVersion_extractsFullID() {
        let url = URL(string: "https://arxiv.org/abs/hep-th/9901001v2")!
        let result = ArXivURLParser.parse(url)

        if case .paper(let arxivID) = result {
            XCTAssertEqual(arxivID, "hep-th/9901001v2")
        } else {
            XCTFail("Expected paper type, got \(String(describing: result))")
        }
    }

    // MARK: - PDF URL Tests

    func testParsePDFURL_withoutExtension_extractsArXivID() {
        let url = URL(string: "https://arxiv.org/pdf/2301.12345")!
        let result = ArXivURLParser.parse(url)

        if case .pdf(let arxivID) = result {
            XCTAssertEqual(arxivID, "2301.12345")
        } else {
            XCTFail("Expected pdf type, got \(String(describing: result))")
        }
    }

    func testParsePDFURL_withExtension_extractsArXivID() {
        let url = URL(string: "https://arxiv.org/pdf/2301.12345.pdf")!
        let result = ArXivURLParser.parse(url)

        if case .pdf(let arxivID) = result {
            XCTAssertEqual(arxivID, "2301.12345")
        } else {
            XCTFail("Expected pdf type, got \(String(describing: result))")
        }
    }

    func testParsePDFURL_withVersionAndExtension_extractsArXivID() {
        let url = URL(string: "https://arxiv.org/pdf/2301.12345v2.pdf")!
        let result = ArXivURLParser.parse(url)

        if case .pdf(let arxivID) = result {
            XCTAssertEqual(arxivID, "2301.12345v2")
        } else {
            XCTFail("Expected pdf type, got \(String(describing: result))")
        }
    }

    // MARK: - Search URL Tests

    func testParseSearchURL_basicQuery_extractsQuery() {
        let url = URL(string: "https://arxiv.org/search/?query=machine+learning&searchtype=all")!
        let result = ArXivURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "machine+learning")
        } else {
            XCTFail("Expected search type, got \(String(describing: result))")
        }
    }

    func testParseSearchURL_withCategory_extractsQuery() {
        let url = URL(string: "https://arxiv.org/search/cs?query=neural+networks&searchtype=all")!
        let result = ArXivURLParser.parse(url)

        if case .search(let query, _) = result {
            XCTAssertEqual(query, "neural+networks")
        } else {
            XCTFail("Expected search type, got \(String(describing: result))")
        }
    }

    func testParseSearchURL_missingQuery_returnsNil() {
        let url = URL(string: "https://arxiv.org/search/?searchtype=all")!
        let result = ArXivURLParser.parse(url)

        XCTAssertNil(result)
    }

    // MARK: - Category List URL Tests

    func testParseCategoryListURL_recentTimeframe_extractsCategory() {
        let url = URL(string: "https://arxiv.org/list/cs.LG/recent")!
        let result = ArXivURLParser.parse(url)

        if case .categoryList(let category, let timeframe) = result {
            XCTAssertEqual(category, "cs.LG")
            XCTAssertEqual(timeframe, "recent")
        } else {
            XCTFail("Expected categoryList type, got \(String(describing: result))")
        }
    }

    func testParseCategoryListURL_newTimeframe_extractsCategory() {
        let url = URL(string: "https://arxiv.org/list/astro-ph.GA/new")!
        let result = ArXivURLParser.parse(url)

        if case .categoryList(let category, let timeframe) = result {
            XCTAssertEqual(category, "astro-ph.GA")
            XCTAssertEqual(timeframe, "new")
        } else {
            XCTFail("Expected categoryList type, got \(String(describing: result))")
        }
    }

    func testParseCategoryListURL_yearMonthTimeframe_extractsCategory() {
        let url = URL(string: "https://arxiv.org/list/hep-th/2301")!
        let result = ArXivURLParser.parse(url)

        if case .categoryList(let category, let timeframe) = result {
            XCTAssertEqual(category, "hep-th")
            XCTAssertEqual(timeframe, "2301")
        } else {
            XCTFail("Expected categoryList type, got \(String(describing: result))")
        }
    }

    func testParseCategoryListURL_noTimeframe_defaultsToRecent() {
        let url = URL(string: "https://arxiv.org/list/cs.AI/")!
        let result = ArXivURLParser.parse(url)

        if case .categoryList(let category, let timeframe) = result {
            XCTAssertEqual(category, "cs.AI")
            XCTAssertEqual(timeframe, "recent")
        } else {
            XCTFail("Expected categoryList type, got \(String(describing: result))")
        }
    }

    // MARK: - Host Variant Tests

    func testParseURL_wwwHost_recognizesURL() {
        let url = URL(string: "https://www.arxiv.org/abs/2301.12345")!
        let result = ArXivURLParser.parse(url)

        XCTAssertNotNil(result)
        if case .paper(let arxivID) = result {
            XCTAssertEqual(arxivID, "2301.12345")
        }
    }

    func testParseURL_exportHost_recognizesURL() {
        let url = URL(string: "https://export.arxiv.org/abs/2301.12345")!
        let result = ArXivURLParser.parse(url)

        XCTAssertNotNil(result)
        if case .paper(let arxivID) = result {
            XCTAssertEqual(arxivID, "2301.12345")
        }
    }

    // MARK: - Invalid URL Tests

    func testParseURL_nonArxivHost_returnsNil() {
        let url = URL(string: "https://example.com/abs/2301.12345")!
        let result = ArXivURLParser.parse(url)

        XCTAssertNil(result)
    }

    func testParseURL_invalidPath_returnsNil() {
        let url = URL(string: "https://arxiv.org/unknown/2301.12345")!
        let result = ArXivURLParser.parse(url)

        XCTAssertNil(result)
    }

    func testParseURL_emptyAbsPath_returnsNil() {
        let url = URL(string: "https://arxiv.org/abs/")!
        let result = ArXivURLParser.parse(url)

        XCTAssertNil(result)
    }

    func testParseURL_invalidArxivIDFormat_returnsNil() {
        let url = URL(string: "https://arxiv.org/abs/invalid")!
        let result = ArXivURLParser.parse(url)

        XCTAssertNil(result)
    }

    // MARK: - isArXivURL Tests

    func testIsArXivURL_validPaperURL_returnsTrue() {
        let url = URL(string: "https://arxiv.org/abs/2301.12345")!
        XCTAssertTrue(ArXivURLParser.isArXivURL(url))
    }

    func testIsArXivURL_validPDFURL_returnsTrue() {
        let url = URL(string: "https://arxiv.org/pdf/2301.12345.pdf")!
        XCTAssertTrue(ArXivURLParser.isArXivURL(url))
    }

    func testIsArXivURL_validSearchURL_returnsTrue() {
        let url = URL(string: "https://arxiv.org/search/?query=test")!
        XCTAssertTrue(ArXivURLParser.isArXivURL(url))
    }

    func testIsArXivURL_invalidURL_returnsFalse() {
        let url = URL(string: "https://google.com")!
        XCTAssertFalse(ArXivURLParser.isArXivURL(url))
    }

    // MARK: - URL Extension Tests

    func testURLExtension_isArXivURL() {
        let validURL = URL(string: "https://arxiv.org/abs/2301.12345")!
        let invalidURL = URL(string: "https://example.com")!

        XCTAssertTrue(validURL.isArXivURL)
        XCTAssertFalse(invalidURL.isArXivURL)
    }

    func testURLExtension_arxivURLType() {
        let url = URL(string: "https://arxiv.org/abs/2301.12345")!
        let urlType = url.arxivURLType

        XCTAssertNotNil(urlType)
        if case .paper(let id) = urlType {
            XCTAssertEqual(id, "2301.12345")
        }
    }
}
