//
//  SmartCollectionTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

// MARK: - Smart Collection Rule Tests

final class SmartCollectionRuleTests: XCTestCase {

    // MARK: - Predicate Generation Tests

    func testToPredicate_contains() {
        // Given
        let rule = SmartCollectionRule(field: .title, comparison: .contains, value: "quantum")

        // When
        let predicate = rule.toPredicate()

        // Then
        XCTAssertEqual(predicate, "title CONTAINS[cd] 'quantum'")
    }

    func testToPredicate_doesNotContain() {
        // Given
        let rule = SmartCollectionRule(field: .author, comparison: .doesNotContain, value: "Smith")

        // When
        let predicate = rule.toPredicate()

        // Then
        XCTAssertEqual(predicate, "NOT (authorString CONTAINS[cd] 'Smith')")
    }

    func testToPredicate_equals() {
        // Given
        let rule = SmartCollectionRule(field: .entryType, comparison: .equals, value: "article")

        // When
        let predicate = rule.toPredicate()

        // Then
        XCTAssertEqual(predicate, "entryType ==[cd] 'article'")
    }

    func testToPredicate_greaterThan() {
        // Given
        let rule = SmartCollectionRule(field: .year, comparison: .greaterThan, value: "2020")

        // When
        let predicate = rule.toPredicate()

        // Then
        XCTAssertEqual(predicate, "year > 2020")
    }

    func testToPredicate_lessThan() {
        // Given
        let rule = SmartCollectionRule(field: .year, comparison: .lessThan, value: "2000")

        // When
        let predicate = rule.toPredicate()

        // Then
        XCTAssertEqual(predicate, "year < 2000")
    }

    func testToPredicate_beginsWith() {
        // Given
        let rule = SmartCollectionRule(field: .citeKey, comparison: .beginsWith, value: "Einstein")

        // When
        let predicate = rule.toPredicate()

        // Then
        XCTAssertEqual(predicate, "citeKey BEGINSWITH[cd] 'Einstein'")
    }

    func testToPredicate_escapesQuotes() {
        // Given
        let rule = SmartCollectionRule(field: .title, comparison: .contains, value: "it's")

        // When
        let predicate = rule.toPredicate()

        // Then
        XCTAssertEqual(predicate, "title CONTAINS[cd] 'it\\'s'")
    }

    // MARK: - Validation Tests

    func testIsValid_withValue_isTrue() {
        // Given
        let rule = SmartCollectionRule(field: .title, comparison: .contains, value: "test")

        // Then
        XCTAssertTrue(rule.isValid)
    }

    func testIsValid_withEmptyValue_isFalse() {
        // Given
        let rule = SmartCollectionRule(field: .title, comparison: .contains, value: "")

        // Then
        XCTAssertFalse(rule.isValid)
    }

    // MARK: - Parse Tests

    func testParse_singleContainsRule() {
        // Given
        let predicate = "title CONTAINS[cd] 'quantum'"

        // When
        let result = SmartCollectionRule.parse(predicate: predicate)

        // Then
        XCTAssertEqual(result.matchType, .any) // Single rule defaults to .any
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules.first?.field, .title)
        XCTAssertEqual(result.rules.first?.comparison, .contains)
        XCTAssertEqual(result.rules.first?.value, "quantum")
    }

    func testParse_multipleRulesWithAND() {
        // Given
        let predicate = "title CONTAINS[cd] 'quantum' AND year > 2020"

        // When
        let result = SmartCollectionRule.parse(predicate: predicate)

        // Then
        XCTAssertEqual(result.matchType, .all)
        XCTAssertEqual(result.rules.count, 2)
    }

    func testParse_multipleRulesWithOR() {
        // Given
        let predicate = "title CONTAINS[cd] 'quantum' OR title CONTAINS[cd] 'physics'"

        // When
        let result = SmartCollectionRule.parse(predicate: predicate)

        // Then
        XCTAssertEqual(result.matchType, .any)
        XCTAssertEqual(result.rules.count, 2)
    }
}

// MARK: - Rule Field Tests

final class RuleFieldTests: XCTestCase {

    func testPredicateKey_mapsCorrectly() {
        XCTAssertEqual(RuleField.title.predicateKey, "title")
        XCTAssertEqual(RuleField.author.predicateKey, "authorString")
        XCTAssertEqual(RuleField.year.predicateKey, "year")
        XCTAssertEqual(RuleField.journal.predicateKey, "journal")
    }

    func testFromPredicateKey_findsField() {
        XCTAssertEqual(RuleField.from(predicateKey: "title"), .title)
        XCTAssertEqual(RuleField.from(predicateKey: "authorString"), .author)
        XCTAssertEqual(RuleField.from(predicateKey: "year"), .year)
    }

    func testFromPredicateKey_unknownReturnsNil() {
        XCTAssertNil(RuleField.from(predicateKey: "unknownField"))
    }

    func testAvailableComparisons_yearHasNumeric() {
        let comparisons = RuleField.year.availableComparisons

        XCTAssertTrue(comparisons.contains(.greaterThan))
        XCTAssertTrue(comparisons.contains(.lessThan))
        XCTAssertTrue(comparisons.contains(.equals))
        XCTAssertFalse(comparisons.contains(.contains))
    }

    func testAvailableComparisons_titleHasText() {
        let comparisons = RuleField.title.availableComparisons

        XCTAssertTrue(comparisons.contains(.contains))
        XCTAssertTrue(comparisons.contains(.doesNotContain))
        XCTAssertTrue(comparisons.contains(.beginsWith))
        XCTAssertFalse(comparisons.contains(.greaterThan))
    }
}

// MARK: - Rule Comparison Tests

final class RuleComparisonTests: XCTestCase {

    func testDisplayName_isReadable() {
        XCTAssertEqual(RuleComparison.contains.displayName, "contains")
        XCTAssertEqual(RuleComparison.doesNotContain.displayName, "does not contain")
        XCTAssertEqual(RuleComparison.greaterThan.displayName, "is greater than")
    }
}

// MARK: - Match Type Tests

final class MatchTypeTests: XCTestCase {

    func testMatchType_allCases() {
        XCTAssertEqual(MatchType.allCases.count, 2)
        XCTAssertTrue(MatchType.allCases.contains(.all))
        XCTAssertTrue(MatchType.allCases.contains(.any))
    }
}
