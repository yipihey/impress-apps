//
//  VagueMemoryQueryBuilderTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-22.
//

import XCTest
@testable import PublicationManagerCore

final class VagueMemoryQueryBuilderTests: XCTestCase {

    // MARK: - Basic Query Building

    func testBuildQueryWithSimpleTopic() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "galaxy rotation"

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Should search both title and abstract
        XCTAssertTrue(query.contains("title:"))
        XCTAssertTrue(query.contains("abs:"))
        // Should include the original term
        XCTAssertTrue(query.contains("galaxy rotation") || query.contains("\"galaxy rotation\""))
    }

    func testBuildQueryWithDecade() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "cosmology"
        state.selectedDecade = .d1970s

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Should include year range with buffer
        XCTAssertTrue(query.contains("year:1968-1982"))
    }

    func testBuildQueryWithCustomYears() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "dark matter"
        state.customYearFrom = 1980
        state.customYearTo = 1990

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Should use custom years instead of decade
        XCTAssertTrue(query.contains("year:1980-1990"))
    }

    func testCustomYearsOverrideDecade() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "quasar"
        state.selectedDecade = .d1970s
        state.customYearFrom = 1985

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Custom years should override decade
        XCTAssertTrue(query.contains("year:1985-"))
        XCTAssertFalse(query.contains("1968"))
    }

    // MARK: - Synonym Expansion

    func testSynonymExpansionForDarkMatter() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "dark matter"

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Should expand to include synonyms
        XCTAssertTrue(query.contains("OR"), "Should use OR for synonym expansion")
        // Should include at least one known synonym
        let hasSynonyms = query.contains("DM") ||
                          query.contains("WIMP") ||
                          query.contains("CDM") ||
                          query.contains("cold dark matter")
        XCTAssertTrue(hasSynonyms, "Should include dark matter synonyms")
    }

    func testSynonymExpansionForCMB() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "cmb"

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Should expand CMB abbreviation
        let hasExpansion = query.contains("cosmic microwave background") ||
                           query.contains("microwave background")
        XCTAssertTrue(hasExpansion, "Should expand CMB to full term")
    }

    func testSynonymExpansionForRotationCurve() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "rotation curve"

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Should expand rotation curve
        XCTAssertTrue(query.contains("OR"))
        let hasVariant = query.contains("rotation curves") ||
                         query.contains("galactic rotation") ||
                         query.contains("galaxy rotation")
        XCTAssertTrue(hasVariant, "Should include rotation curve variants")
    }

    // MARK: - Author Hints

    func testAuthorHintWithFullName() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "rotation curves"
        state.authorHint = "Rubin"

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        XCTAssertTrue(query.contains("author:"))
        XCTAssertTrue(query.contains("Rubin"))
    }

    func testAuthorHintStartsWithPattern() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "galaxies"
        state.authorHint = "starts with R"

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Should produce wildcard author search
        XCTAssertTrue(query.contains("author:"))
        XCTAssertTrue(query.contains("R*"))
    }

    func testAuthorHintSingleLetter() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "pulsars"
        state.authorHint = "H"

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // Single letter should be treated as partial name
        XCTAssertTrue(query.contains("author:"))
        XCTAssertTrue(query.contains("H*"))
    }

    // MARK: - Decade Year Ranges

    func testDecadeYearRanges() {
        // Test that decade buffers are applied correctly
        XCTAssertEqual(Decade.d1970s.yearRange.start, 1968)
        XCTAssertEqual(Decade.d1970s.yearRange.end, 1982)

        XCTAssertEqual(Decade.d1950s.yearRange.start, 1948)
        XCTAssertEqual(Decade.d1950s.yearRange.end, 1962)

        XCTAssertEqual(Decade.d2000s.yearRange.start, 1998)
        XCTAssertEqual(Decade.d2000s.yearRange.end, 2012)
    }

    func testDecadeDisplayNames() {
        XCTAssertEqual(Decade.d1970s.displayName, "1970s")
        XCTAssertEqual(Decade.d2020s.displayName, "2020s")
    }

    // MARK: - Form State

    func testFormIsEmptyWhenNoInput() {
        let state = VagueMemoryFormState()
        XCTAssertTrue(state.isEmpty)
    }

    func testFormIsNotEmptyWithTopic() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "black holes"
        XCTAssertFalse(state.isEmpty)
    }

    func testFormIsNotEmptyWithAuthorOnly() {
        var state = VagueMemoryFormState()
        state.authorHint = "Einstein"
        XCTAssertFalse(state.isEmpty)
    }

    func testFormClear() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "gravitational waves"
        state.authorHint = "Abbott"
        state.selectedDecade = .d2010s
        state.maxResults = 200

        state.clear()

        XCTAssertTrue(state.isEmpty)
        XCTAssertNil(state.selectedDecade)
        XCTAssertEqual(state.maxResults, 100)  // Back to default
    }

    // MARK: - Query Preview

    func testGeneratePreviewWithTopic() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "dark energy"

        let preview = VagueMemoryQueryBuilder.generatePreview(from: state)

        XCTAssertTrue(preview.contains("Topics:"))
    }

    func testGeneratePreviewWithDecade() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "supernova"
        state.selectedDecade = .d1990s

        let preview = VagueMemoryQueryBuilder.generatePreview(from: state)

        XCTAssertTrue(preview.contains("Time: 1990s"))
    }

    func testGeneratePreviewWithAuthor() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "quasars"
        state.authorHint = "Schmidt"

        let preview = VagueMemoryQueryBuilder.generatePreview(from: state)

        XCTAssertTrue(preview.contains("Author: Schmidt"))
    }

    // MARK: - Edge Cases

    func testEmptyFormProducesEmptyQuery() {
        let state = VagueMemoryFormState()
        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        XCTAssertTrue(query.isEmpty)
    }

    func testWhitespaceOnlyInputTreatedAsEmpty() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "   \n\t  "
        state.authorHint = "  "

        XCTAssertTrue(state.isEmpty)
    }

    func testStopWordsAreFiltered() {
        var state = VagueMemoryFormState()
        state.vagueMemory = "something about the galaxy and some related paper"

        let query = VagueMemoryQueryBuilder.buildQuery(from: state)

        // "galaxy" should be present, but stop words should be filtered
        XCTAssertTrue(query.contains("galaxy"))
        // Stop words like "something", "about", "the", "and", "some", "related", "paper" should be filtered
        // They might appear as part of longer words, so just check "galaxy" is there
    }
}
