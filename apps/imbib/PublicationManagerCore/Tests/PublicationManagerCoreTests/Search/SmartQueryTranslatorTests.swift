//
//  SmartQueryTranslatorTests.swift
//  PublicationManagerCoreTests
//
//  Tests for SmartQueryTranslator — deterministic NL → ADS query translation.
//

import XCTest
@testable import PublicationManagerCore

final class SmartQueryTranslatorTests: XCTestCase {

    // MARK: - Empty / Nil Input

    func testTranslate_emptyInput_returnsNil() {
        XCTAssertNil(SmartQueryTranslator.translate(""))
    }

    func testTranslate_whitespaceInput_returnsNil() {
        XCTAssertNil(SmartQueryTranslator.translate("   "))
    }

    // MARK: - ADS Passthrough

    func testTranslate_adsQuery_passthrough() {
        let result = SmartQueryTranslator.translate("author:\"Einstein\" AND abs:\"relativity\"")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("author:"))
        XCTAssertTrue(result!.query.contains("abs:"))
        XCTAssertTrue(result!.interpretation.contains("Direct ADS query"))
    }

    func testTranslate_shorthandExpansion() {
        let result = SmartQueryTranslator.translate("a:Einstein")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("author:"))
    }

    func testTranslate_functionalOperator_passthrough() {
        let result = SmartQueryTranslator.translate("citations(bibcode:2024ApJ...123..456A)")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("citations("))
    }

    // MARK: - Identifier Passthrough

    func testTranslate_doi() {
        let result = SmartQueryTranslator.translate("10.1234/some.paper.2024")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("doi:"))
        XCTAssertEqual(result!.interpretation, "DOI lookup")
    }

    func testTranslate_arxiv() {
        let result = SmartQueryTranslator.translate("2301.12345")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("identifier:2301.12345"))
        XCTAssertEqual(result!.interpretation, "arXiv paper lookup")
    }

    func testTranslate_bibcode() {
        let result = SmartQueryTranslator.translate("2024ApJ...123..456A")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("bibcode:"))
        XCTAssertEqual(result!.interpretation, "Bibcode lookup")
    }

    // MARK: - Natural Language: Topics

    func testTranslate_topicSearch() {
        let result = SmartQueryTranslator.translate("dark matter")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("abs:\"dark matter\""))
    }

    func testTranslate_multiWordTopic() {
        let result = SmartQueryTranslator.translate("galaxy rotation curves")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("abs:\"galaxy rotation curves\""))
    }

    // MARK: - Natural Language: Authors

    func testTranslate_singleAuthor() {
        let result = SmartQueryTranslator.translate("papers by Einstein")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("author:\"Einstein\""))
    }

    func testTranslate_fullNameAuthor() {
        let result = SmartQueryTranslator.translate("papers by Albert Einstein")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("author:\"Einstein, A\""))
    }

    // MARK: - Natural Language: Years

    func testTranslate_standaloneYear() {
        let result = SmartQueryTranslator.translate("cosmology 2024")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("year:2024"))
    }

    func testTranslate_hyphenatedYearRange() {
        let result = SmartQueryTranslator.translate("papers 2020-2024")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("year:2020-2024"))
    }

    func testTranslate_spacedYearRange() {
        let result = SmartQueryTranslator.translate("papers 2020 to 2024")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("year:2020-2024"))
    }

    func testTranslate_sinceYear() {
        let result = SmartQueryTranslator.translate("papers since 2020")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("year:2020-"))
    }

    func testTranslate_decade_1970s() {
        let result = SmartQueryTranslator.translate("galaxy rotation curves 1970s")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("year:1968-1982"))
    }

    func testTranslate_recentPapers() {
        let result = SmartQueryTranslator.translate("recent dark energy")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("year:"))
    }

    func testTranslate_lastNYears() {
        let result = SmartQueryTranslator.translate("papers last 3 years")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("year:"))
    }

    // MARK: - Natural Language: Refereed

    func testTranslate_refereedInText() {
        let result = SmartQueryTranslator.translate("CMB anisotropy refereed")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("property:refereed"))
        XCTAssertTrue(result!.query.contains("abs:"))
    }

    func testTranslate_refereedToggle() {
        let result = SmartQueryTranslator.translate("dark matter", refereedOnly: true)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("property:refereed"))
    }

    func testTranslate_refereedNotDuplicated() {
        let result = SmartQueryTranslator.translate(
            "author:\"Einstein\" property:refereed",
            refereedOnly: true
        )
        XCTAssertNotNil(result)
        let count = result!.query.components(separatedBy: "property:refereed").count - 1
        XCTAssertEqual(count, 1)
    }

    // MARK: - Complex Queries

    func testTranslate_topicAuthorYear() {
        let result = SmartQueryTranslator.translate("dark energy by Riess since 2020")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("abs:\"dark energy\""))
        XCTAssertTrue(result!.query.contains("author:\"Riess\""))
        XCTAssertTrue(result!.query.contains("year:2020-"))
    }

    // MARK: - Synonym Expansion

    func testTranslate_noSynonymsByDefault() {
        let result = SmartQueryTranslator.translate("CMB")
        XCTAssertNotNil(result)
        // Original casing preserved, no synonym expansion
        XCTAssertTrue(result!.query.contains("abs:\"CMB\""))
        XCTAssertFalse(result!.query.contains("cosmic microwave background"))
    }

    func testTranslate_withSynonymExpansion() {
        let result = SmartQueryTranslator.translate("CMB", expandSynonyms: true)
        XCTAssertNotNil(result)
        // Should expand to include cosmic microwave background
        XCTAssertTrue(result!.query.contains("cosmic microwave background"))
        // Should search both title and abs
        XCTAssertTrue(result!.query.contains("title:"))
        XCTAssertTrue(result!.query.contains("abs:"))
    }

    func testTranslate_synonymExpansion_darkMatter() {
        let result = SmartQueryTranslator.translate("dark matter", expandSynonyms: true)
        XCTAssertNotNil(result)
        // Should expand with DM, WIMP, CDM, etc.
        XCTAssertTrue(result!.query.contains("DM") || result!.query.contains("WIMP") || result!.query.contains("CDM"))
    }

    // MARK: - Query Description

    func testDescribeQuery_authorAndTopic() {
        let desc = SmartQueryTranslator.describeQuery("abs:\"dark energy\" author:\"Riess\" year:2020-2026")
        XCTAssertTrue(desc.contains("by Riess"))
        XCTAssertTrue(desc.contains("about dark energy"))
        XCTAssertTrue(desc.contains("from 2020-2026"))
    }

    func testDescribeQuery_refereed() {
        let desc = SmartQueryTranslator.describeQuery("abs:\"CMB\" property:refereed")
        XCTAssertTrue(desc.contains("refereed only"))
    }

    func testDescribeQuery_emptyQuery() {
        let desc = SmartQueryTranslator.describeQuery("something_unusual")
        XCTAssertEqual(desc, "Custom ADS query")
    }

    // MARK: - Normalization Applied

    func testTranslate_normalizationApplied() {
        // Shorthand should be expanded by normalizer
        let result = SmartQueryTranslator.translate("a:Einstein")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("author:Einstein"))
        XCTAssertFalse(result!.query.contains("a:Einstein"))
    }

    // MARK: - Edge Cases: Author Detection

    func testTranslate_authorWithoutByKeyword_treatedAsTopic() {
        // Without "by", a bare name is treated as a topic word, not an author
        let result = SmartQueryTranslator.translate("Riess dark energy")
        XCTAssertNotNil(result)
        // Should NOT produce author: — "by" keyword is required for author detection
        XCTAssertFalse(result!.query.contains("author:"))
        XCTAssertTrue(result!.query.contains("abs:"))
    }

    // MARK: - Edge Cases: Decade Bounds

    func testTranslate_decade_outOfRange_treatedAsTopic() {
        // "9999s" should not be treated as a valid decade
        let result = SmartQueryTranslator.translate("9999s")
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.query.contains("year:"))
    }

    func testTranslate_decade_2020s() {
        let result = SmartQueryTranslator.translate("exoplanets 2020s")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("year:2018-2032"))
    }

    // MARK: - Original Casing Preserved

    func testTranslate_topicPreservesCasing() {
        let result = SmartQueryTranslator.translate("JWST deep field")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.query.contains("abs:\"JWST deep field\""))
    }

    // MARK: - Multi-Author Description

    func testDescribeQuery_multipleAuthors() {
        let desc = SmartQueryTranslator.describeQuery(
            "author:\"Riess\" author:\"Perlmutter\" abs:\"dark energy\""
        )
        XCTAssertTrue(desc.contains("Riess"))
        XCTAssertTrue(desc.contains("Perlmutter"))
        XCTAssertTrue(desc.contains("&"))
    }

    func testDescribeQuery_multipleTopics() {
        let desc = SmartQueryTranslator.describeQuery(
            "abs:\"dark energy\" abs:\"supernovae\""
        )
        XCTAssertTrue(desc.contains("dark energy"))
        XCTAssertTrue(desc.contains("supernovae"))
    }

    // MARK: - Normalizer Corrections in Interpretation

    func testTranslate_normalizerCorrectionsInInterpretation() {
        // a: shorthand triggers normalizer correction
        let result = SmartQueryTranslator.translate("a:Einstein")
        XCTAssertNotNil(result)
        // Interpretation should mention the shorthand expansion
        XCTAssertTrue(result!.interpretation.contains("Expanded"))
    }
}
