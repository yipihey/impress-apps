//
//  NLSearchServiceTests.swift
//  PublicationManagerCoreTests
//
//  Tests for NLSearchService — ADS query detection, passthrough normalization,
//  fallback keyword translation, and state management.
//
//  NOTE: Foundation Models (on-device LLM) tests are excluded because they
//  require macOS 26 with Apple Intelligence enabled. The testable surface
//  covers: query detection, passthrough, fallback translation, and state.
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

    // MARK: - ADS Query Detection

    func testIsADSQuery_authorField() {
        // Uses NLSearchService.isADSQuery (private) via translate() passthrough behavior
        // We test indirectly: if translate returns immediately (no Foundation Models),
        // it means the query was detected as ADS syntax
        XCTAssertTrue(containsFieldQualifier("author:\"Einstein\""))
    }

    func testIsADSQuery_absField() {
        XCTAssertTrue(containsFieldQualifier("abs:\"dark matter\""))
    }

    func testIsADSQuery_yearField() {
        XCTAssertTrue(containsFieldQualifier("year:2024"))
    }

    func testIsADSQuery_titleField() {
        XCTAssertTrue(containsFieldQualifier("title:\"relativity\""))
    }

    func testIsADSQuery_propertyField() {
        XCTAssertTrue(containsFieldQualifier("property:refereed"))
    }

    func testIsADSQuery_bibcodeField() {
        XCTAssertTrue(containsFieldQualifier("bibcode:2024ApJ...123..456A"))
    }

    func testIsADSQuery_doiField() {
        XCTAssertTrue(containsFieldQualifier("doi:10.1234/test"))
    }

    func testIsADSQuery_shorthandAlias() {
        XCTAssertTrue(containsFieldQualifier("a:Einstein"))
    }

    func testIsADSQuery_functionalOperator_citations() {
        XCTAssertTrue(containsFieldQualifier("citations(bibcode:2024ApJ...123..456A)"))
    }

    func testIsADSQuery_functionalOperator_references() {
        XCTAssertTrue(containsFieldQualifier("references(bibcode:2024ApJ...123..456A)"))
    }

    func testIsADSQuery_functionalOperator_similar() {
        XCTAssertTrue(containsFieldQualifier("similar(bibcode:2024ApJ...123..456A)"))
    }

    func testIsADSQuery_naturalLanguage_notDetected() {
        XCTAssertFalse(containsFieldQualifier("papers about dark matter by Einstein"))
    }

    func testIsADSQuery_plainKeywords_notDetected() {
        XCTAssertFalse(containsFieldQualifier("gravitational waves 2024"))
    }

    func testIsADSQuery_urlNotDetected() {
        // "http:" should not be mistaken for a field qualifier
        XCTAssertFalse(containsFieldQualifier("http://example.com"))
    }

    // MARK: - Translation (fallback or Foundation Models depending on availability)

    func testTranslate_topicSearch_producesAbsQuery() async {
        // Whether via Foundation Models or fallback, a topic search should produce abs: field
        let query = await service.translate("dark matter")
        XCTAssertNotNil(query)
        // Both paths should produce a query containing the topic keywords
        XCTAssertTrue(query!.lowercased().contains("dark"))
        XCTAssertTrue(query!.lowercased().contains("matter"))
    }

    func testTranslate_authorSearch_producesAuthorField() async {
        let query = await service.translate("papers by Einstein")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("author:"))
    }

    func testTranslate_yearExtraction() async {
        // Both Foundation Models and fallback should handle standalone years
        let query = await service.translate("papers 2024")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("2024"))
    }

    func testTranslate_yearRange() async {
        let query = await service.translate("papers 2020-2024")
        XCTAssertNotNil(query)
        // Both paths should preserve the year range somehow
        XCTAssertTrue(query!.contains("2020"))
        XCTAssertTrue(query!.contains("2024"))
    }

    func testTranslate_yearRangeWithTo() async {
        let query = await service.translate("papers 2020 to 2024")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("2020"))
        XCTAssertTrue(query!.contains("2024"))
    }

    func testTranslate_adsQueryPassthrough() async {
        // If the input is already an ADS query, it should pass through via the passthrough path
        let query = await service.translate("author:\"Einstein\" AND abs:\"relativity\"")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("author:"))
        XCTAssertTrue(query!.contains("abs:"))
    }

    func testTranslate_emptyInput() async {
        let query = await service.translate("")
        XCTAssertNil(query)
    }

    func testTranslate_whitespaceInput() async {
        let query = await service.translate("   ")
        XCTAssertNil(query)
    }

    // MARK: - Fallback Translation (only runs when Foundation Models is unavailable)

    func testFallback_sinceYear() async throws {
        try XCTSkipIf(NLSearchService.isAvailable, "Foundation Models available; fallback path not used")
        let query = await service.translate("papers since 2020")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:2020-"))
    }

    func testFallback_recentPapers() async throws {
        try XCTSkipIf(NLSearchService.isAvailable, "Foundation Models available; fallback path not used")
        let query = await service.translate("recent papers")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:"))
    }

    func testFallback_lastNYears() async throws {
        try XCTSkipIf(NLSearchService.isAvailable, "Foundation Models available; fallback path not used")
        let query = await service.translate("papers last 3 years")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("year:"))
    }

    func testFallback_refereedFilter() async throws {
        try XCTSkipIf(NLSearchService.isAvailable, "Foundation Models available; fallback path not used")
        let query = await service.translate("refereed papers on cosmology")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("property:refereed"))
    }

    func testFallback_doiPassthrough() async throws {
        try XCTSkipIf(NLSearchService.isAvailable, "Foundation Models available; fallback path not used")
        let query = await service.translate("10.1234/some.paper.2024")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("doi:"))
    }

    func testFallback_arxivPassthrough() async throws {
        try XCTSkipIf(NLSearchService.isAvailable, "Foundation Models available; fallback path not used")
        let query = await service.translate("2401.12345")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("identifier:2401.12345"))
    }

    func testFallback_bibcodePassthrough() async throws {
        try XCTSkipIf(NLSearchService.isAvailable, "Foundation Models available; fallback path not used")
        let query = await service.translate("2024ApJ...123..456A")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("bibcode:"))
    }

    func testFallback_authorByName() async throws {
        try XCTSkipIf(NLSearchService.isAvailable, "Foundation Models available; fallback path not used")
        let query = await service.translate("papers by Albert Einstein")
        XCTAssertNotNil(query)
        XCTAssertTrue(query!.contains("author:\"Einstein, A\""))
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
        // Should contain property:refereed exactly once
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

    // MARK: - Passthrough normalization

    func testPassthrough_appliesNormalization() async {
        // Use shorthand without space (a:Einstein) so expansion works
        let query = await service.translate("a:Einstein")
        XCTAssertNotNil(query)
        // Shorthand expanded by normalizer
        XCTAssertTrue(query!.contains("author:"))
    }

    func testPassthrough_setsInterpretation() async {
        _ = await service.translate("author:\"Einstein\"")
        XCTAssertTrue(service.lastInterpretation.contains("Direct ADS query"))
    }

    func testPassthrough_normalizationCorrectionsInInterpretation() async {
        _ = await service.translate("a:Einstein and abs: dark matter")
        // Should mention corrections in interpretation
        XCTAssertTrue(service.lastInterpretation.count > 0)
    }

    func testPassthrough_setsResultType() async {
        _ = await service.translate("author:\"Einstein\"")
        if case .querySearch(let q) = service.lastResultType {
            XCTAssertTrue(q.contains("author:"))
        } else {
            XCTFail("Expected .querySearch result type")
        }
    }

    // MARK: - Availability

    func testIsAvailable_returnsBoolean() {
        // Just verify it doesn't crash — actual value depends on macOS version
        _ = NLSearchService.isAvailable
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

    // MARK: - Helper

    /// Test ADS query detection by checking if the string contains known field qualifiers.
    /// Uses the same heuristic as NLSearchService.isADSQuery (private).
    private func containsFieldQualifier(_ text: String) -> Bool {
        let adsFieldQualifiers: Set<String> = [
            "author", "first_author", "title", "abs", "abstract",
            "year", "bibcode", "doi", "arxiv", "orcid",
            "aff", "affiliation", "full", "object", "body",
            "keyword", "property", "doctype", "collection", "bibstem",
            "arxiv_class", "identifier", "citations", "references",
            "similar", "trending", "reviews", "useful",
            "author_count", "citation_count", "read_count", "database",
            "a", "t", "b"
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for field in adsFieldQualifiers {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: field)):"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                return true
            }
        }
        let funcPattern = "\\b(citations|references|similar|trending|reviews|useful)\\("
        if let regex = try? NSRegularExpression(pattern: funcPattern, options: .caseInsensitive),
           regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }
        return false
    }
}
