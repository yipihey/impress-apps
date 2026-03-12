//
//  NLSearchServiceTests.swift
//  PublicationManagerCoreTests
//
//  Tests for NLSearchService — ADS query detection, passthrough normalization,
//  deterministic translation via SmartQueryTranslator, and state management.
//

import XCTest
@testable import PublicationManagerCore

@MainActor
final class NLSearchServiceTests: XCTestCase {

    var service: NLSearchService!

    override func setUp() async throws {
        try await super.setUp()
        service = NLSearchService()
        service.skipCountPreview = true  // Avoid Keychain access dialog in tests
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - ADS Query Detection (passthrough)

    func testTranslate_adsQueryPassthrough() async {
        let query = await service.translate("author:\"Einstein\" AND abs:\"relativity\"")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("author:"))
        XCTAssertTrue(query!.contains("abs:"))
    }

    func testTranslate_shorthandExpansion() async {
        let query = await service.translate("a:Einstein")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("author:"))
    }

    func testPassthrough_setsInterpretation() async {
        _ = await service.translate("author:\"Einstein\"")
        XCTAssertTrue(service.lastInterpretation.contains("Direct ADS query"))
    }

    func testPassthrough_setsResultType() async {
        _ = await service.translate("author:\"Einstein\"")
        if case .querySearch(let q) = service.lastResultType {
            XCTAssertTrue(q.contains("author:"))
        } else {
            XCTFail("Expected .querySearch result type")
        }
    }

    // MARK: - Translation

    func testTranslate_topicSearch_producesAbsQuery() async {
        let query = await service.translate("dark matter")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("abs:\"dark matter\""))
    }

    func testTranslate_authorSearch_producesAuthorField() async {
        let query = await service.translate("papers by Einstein")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("author:\"Einstein\""))
    }

    func testTranslate_fullNameAuthor() async {
        let query = await service.translate("papers by Albert Einstein")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("author:\"Einstein, A\""))
    }

    func testTranslate_yearExtraction() async {
        let query = await service.translate("papers 2024")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:2024"))
    }

    func testTranslate_yearRange() async {
        let query = await service.translate("papers 2020-2024")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:2020-2024"))
    }

    func testTranslate_yearRangeWithTo() async {
        let query = await service.translate("papers 2020 to 2024")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:2020-2024"))
    }

    func testTranslate_sinceYear() async {
        let query = await service.translate("papers since 2020")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:2020-"))
    }

    func testTranslate_recentPapers() async {
        let query = await service.translate("recent papers")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:"))
    }

    func testTranslate_lastNYears() async {
        let query = await service.translate("papers last 3 years")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:"))
    }

    func testTranslate_decade() async {
        let query = await service.translate("galaxy rotation curves 1970s")
        XCTAssertNotNil(query)
        // Decade buffer: 1970s → 1968-1982
        XCTAssertTrue(query!.contains("year:1968-1982"))
        XCTAssertTrue(query!.contains("abs:"))
    }

    func testTranslate_refereedFilter() async {
        let query = await service.translate("refereed papers on cosmology")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("property:refereed"))
    }

    func testTranslate_doiPassthrough() async {
        let query = await service.translate("10.1234/some.paper.2024")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("doi:"))
    }

    func testTranslate_arxivPassthrough() async {
        let query = await service.translate("2401.12345")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("identifier:2401.12345"))
    }

    func testTranslate_bibcodePassthrough() async {
        let query = await service.translate("2024ApJ...123..456A")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("bibcode:"))
    }

    func testTranslate_emptyInput() async {
        let query = await service.translate("")
        XCTAssertNil(query)
    }

    func testTranslate_whitespaceInput() async {
        let query = await service.translate("   ")
        XCTAssertNil(query)
    }

    func testTranslate_complexQuery() async {
        let query = await service.translate("dark energy by Riess since 2020")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("abs:\"dark energy\""))
        XCTAssertTrue(query!.contains("author:\"Riess\""))
        XCTAssertTrue(query!.contains("year:2020-"))
    }

    // MARK: - Synonym Expansion

    func testTranslate_synonymExpansion() async {
        service.expandSynonyms = true
        let query = await service.translate("CMB")
        XCTAssertNotNil(query)
        // Should expand CMB to include "cosmic microwave background"
        XCTAssertTrue(query!.contains("cosmic microwave background") || query!.contains("CMBR"))
    }

    func testTranslate_noSynonymsByDefault() async {
        service.expandSynonyms = false
        let query = await service.translate("CMB")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("abs:\"cmb\"") || query!.contains("abs:\"CMB\""))
    }

    // MARK: - Refereed Filter

    func testRefereedFilter_addedWhenToggled() async {
        service.refereedOnly = true
        let query = await service.translate("author:\"Einstein\"")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("property:refereed"))
    }

    func testRefereedFilter_notDuplicated() async {
        service.refereedOnly = true
        let query = await service.translate("author:\"Einstein\" property:refereed")
        XCTAssertNotNil(query)
        let count = query!.components(separatedBy: "property:refereed").count - 1
        XCTAssertEqual(count, 1)
    }

    func testRefereedFilter_notAddedWhenOff() async {
        service.refereedOnly = false
        let query = await service.translate("author:\"Einstein\"")
        XCTAssertNotNil(query)
        XCTAssertFalse(query!.contains("property:refereed"))
    }

    // MARK: - State Management

    func testInitialState_isIdle() {
        XCTAssertEqual(service.state, .idle)
    }

    func testReset_clearsEverything() async {
        _ = await service.translate("author:\"Einstein\"")
        service.reset()

        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(service.lastNaturalLanguageInput, "")
        XCTAssertEqual(service.lastGeneratedQuery, "")
        XCTAssertEqual(service.lastInterpretation, "")
        XCTAssertNil(service.lastResultType)
        XCTAssertNil(service.estimatedCount)
        XCTAssertEqual(service.conversationTurnCount, 0)
    }

    func testTranslate_updatesLastInput() async {
        _ = await service.translate("author:\"Einstein\"")
        XCTAssertEqual(service.lastNaturalLanguageInput, "author:\"Einstein\"")
    }

    func testTranslate_incrementsTurnCount() async {
        XCTAssertEqual(service.conversationTurnCount, 0)
        _ = await service.translate("author:\"Einstein\"")
        XCTAssertEqual(service.conversationTurnCount, 1)
    }

    func testStartNewConversation_resetsTurnCount() async {
        _ = await service.translate("author:\"Einstein\"")
        XCTAssertEqual(service.conversationTurnCount, 1)

        service.startNewConversation()
        XCTAssertEqual(service.conversationTurnCount, 0)
    }

    func testMarkSearching_updatesState() {
        service.markSearching()
        XCTAssertEqual(service.state, .searching)
    }

    func testMarkComplete_updatesState() async {
        _ = await service.translate("author:\"Einstein\"")
        service.markComplete(resultCount: 42)

        if case .complete(_, let count) = service.state {
            XCTAssertEqual(count, 42)
        } else {
            XCTFail("Expected .complete state")
        }
    }

    func testMarkComplete_withExecutedQuery() async {
        _ = await service.translate("author:\"Einstein\"")
        service.markComplete(resultCount: 10, executedQuery: "author:\"Einstein\" year:2024")

        if case .complete(let query, _) = service.state {
            XCTAssertEqual(query, "author:\"Einstein\" year:2024")
        } else {
            XCTFail("Expected .complete state")
        }
    }

    // MARK: - Availability

    func testIsAvailable_alwaysTrue() {
        XCTAssertTrue(NLSearchService.isAvailable)
    }

    // MARK: - isWorking property

    func testIsWorking_idleIsFalse() {
        XCTAssertFalse(NLSearchState.idle.isWorking)
    }

    func testIsWorking_thinkingIsTrue() {
        XCTAssertTrue(NLSearchState.thinking.isWorking)
    }

    func testIsWorking_searchingIsTrue() {
        XCTAssertTrue(NLSearchState.searching.isWorking)
    }

    func testIsWorking_translatedIsFalse() {
        XCTAssertFalse(NLSearchState.translated(query: "test", interpretation: "test", estimatedCount: nil).isWorking)
    }

    func testIsWorking_completeIsFalse() {
        XCTAssertFalse(NLSearchState.complete(query: "test", resultCount: 5).isWorking)
    }

    func testIsWorking_errorIsFalse() {
        XCTAssertFalse(NLSearchState.error("oops").isWorking)
    }
}
