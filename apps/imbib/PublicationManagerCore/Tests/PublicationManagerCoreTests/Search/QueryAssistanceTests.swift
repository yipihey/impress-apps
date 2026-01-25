//
//  QueryAssistanceTests.swift
//  PublicationManagerCoreTests
//
//  Tests for query validation rules in ADS and arXiv assistants.
//

import XCTest
@testable import PublicationManagerCore

// MARK: - ADS Query Assistant Tests

final class ADSQueryAssistantTests: XCTestCase {

    var assistant: ADSQueryAssistant!

    override func setUp() async throws {
        try await super.setUp()
        assistant = ADSQueryAssistant()
    }

    override func tearDown() async throws {
        assistant = nil
        try await super.tearDown()
    }

    // MARK: - Author Quoting Rule (ads.author.quote)

    func testValidate_authorWithCommaUnquoted_detectsError() async {
        // Given
        let query = "author:Einstein, Albert"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasErrors, "Should detect error for unquoted author with comma")
        XCTAssertTrue(result.issues.contains { $0.ruleID == "ads.author.quote" })
    }

    func testValidate_authorWithCommaQuoted_noError() async {
        // Given
        let query = #"author:"Einstein, Albert""#

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "ads.author.quote" })
    }

    func testValidate_authorWithoutComma_noError() async {
        // Given
        let query = "author:Einstein"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "ads.author.quote" })
    }

    func testValidate_authorWithCommaSuggestion_isCorrect() async {
        // Given
        let query = "author:Einstein, A"

        // When
        let result = await assistant.validate(query)

        // Then
        let issue = result.issues.first { $0.ruleID == "ads.author.quote" }
        XCTAssertNotNil(issue)
        XCTAssertFalse(issue!.suggestions.isEmpty)
        XCTAssertTrue(issue!.suggestions.first!.correctedQuery.contains(#"author:"Einstein, A""#))
    }

    // MARK: - Space After Colon Rule (ads.space.aftercolon)

    func testValidate_spaceAfterColon_detectsWarning() async {
        // Given
        let query = "author: Einstein"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasWarnings, "Should detect warning for space after colon")
        XCTAssertTrue(result.issues.contains { $0.ruleID == "ads.space.aftercolon" })
    }

    func testValidate_noSpaceAfterColon_noWarning() async {
        // Given
        let query = "author:Einstein"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "ads.space.aftercolon" })
    }

    // MARK: - Unknown Field Rule (ads.field.unknown)

    func testValidate_unknownField_detectsWarning() async {
        // Given
        let query = "auth:Einstein"  // Should be "author:"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.issues.contains { $0.ruleID == "ads.field.unknown" })
    }

    func testValidate_knownField_noWarning() async {
        // Given
        let query = "author:Einstein title:relativity year:1905"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "ads.field.unknown" })
    }

    // MARK: - Year Format Rule (ads.year.format)

    func testValidate_invalidYearFormat_detectsError() async {
        // Given
        let query = "year:twenty-twenty"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "ads.year.format" })
    }

    func testValidate_validYearSingle_noError() async {
        // Given
        let query = "year:2020"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "ads.year.format" })
    }

    func testValidate_validYearRange_noError() async {
        // Given
        let query = "year:2020-2024"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "ads.year.format" })
    }

    // MARK: - Parentheses Rule (ads.paren.unbalanced)

    func testValidate_unbalancedParensOpen_detectsError() async {
        // Given
        let query = "(author:Einstein AND title:relativity"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "ads.paren.unbalanced" })
    }

    func testValidate_unbalancedParensClose_detectsError() async {
        // Given
        let query = "author:Einstein AND title:relativity)"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "ads.paren.unbalanced" })
    }

    func testValidate_balancedParens_noError() async {
        // Given
        let query = "(author:Einstein AND title:relativity)"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "ads.paren.unbalanced" })
    }

    // MARK: - Operator Case Rule (ads.operator.case)

    func testValidate_lowercaseOperator_detectsHint() async {
        // Given
        let query = "author:Einstein and title:relativity"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasHints)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "ads.operator.case" })
    }

    func testValidate_uppercaseOperator_noHint() async {
        // Given
        let query = "author:Einstein AND title:relativity"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "ads.operator.case" })
    }

    // MARK: - Empty Query

    func testValidate_emptyQuery_noIssues() async {
        // Given
        let query = ""

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.issues.isEmpty)
    }

    // MARK: - Valid Complex Query

    func testValidate_validComplexQuery_noIssues() async {
        // Given
        let query = #"author:"Einstein, Albert" AND (title:relativity OR abs:gravity) year:1905-1920"#

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.isValid, "Valid complex query should have no errors")
    }
}

// MARK: - arXiv Query Assistant Tests

final class ArXivQueryAssistantTests: XCTestCase {

    var assistant: ArXivQueryAssistant!

    override func setUp() async throws {
        try await super.setUp()
        assistant = ArXivQueryAssistant()
    }

    override func tearDown() async throws {
        assistant = nil
        try await super.tearDown()
    }

    // MARK: - ANDNOT Operator Rule (arxiv.operator.andnot)

    func testValidate_andNotTwoWords_detectsError() async {
        // Given
        let query = "au:Smith AND NOT ti:test"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasErrors, "Should detect error for AND NOT (two words)")
        XCTAssertTrue(result.issues.contains { $0.ruleID == "arxiv.operator.andnot" })
    }

    func testValidate_andnotOneWord_noError() async {
        // Given
        let query = "au:Smith ANDNOT ti:test"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "arxiv.operator.andnot" })
    }

    func testValidate_andNotSuggestion_isCorrect() async {
        // Given
        let query = "au:Smith AND NOT ti:test"

        // When
        let result = await assistant.validate(query)

        // Then
        let issue = result.issues.first { $0.ruleID == "arxiv.operator.andnot" }
        XCTAssertNotNil(issue)
        XCTAssertFalse(issue!.suggestions.isEmpty)
        XCTAssertTrue(issue!.suggestions.first!.correctedQuery.contains("ANDNOT"))
        XCTAssertFalse(issue!.suggestions.first!.correctedQuery.contains("AND NOT"))
    }

    // MARK: - Space After Colon Rule (arxiv.space.aftercolon)

    func testValidate_spaceAfterColon_detectsWarning() async {
        // Given
        let query = "au: Smith"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasWarnings)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "arxiv.space.aftercolon" })
    }

    func testValidate_noSpaceAfterColon_noWarning() async {
        // Given
        let query = "au:Smith"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "arxiv.space.aftercolon" })
    }

    // MARK: - Unknown Field Rule (arxiv.field.unknown)

    func testValidate_unknownField_detectsWarning() async {
        // Given
        let query = "author:Smith"  // arXiv uses "au:" not "author:"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.issues.contains { $0.ruleID == "arxiv.field.unknown" })
    }

    func testValidate_knownFields_noWarning() async {
        // Given
        let query = "au:Smith AND ti:neural AND abs:learning"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "arxiv.field.unknown" })
    }

    // MARK: - Unknown Category Rule (arxiv.category.unknown)

    func testValidate_unknownCategory_detectsWarning() async {
        // Given
        let query = "cat:xyz.unknown"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.issues.contains { $0.ruleID == "arxiv.category.unknown" })
    }

    func testValidate_validCategory_noWarning() async {
        // Given
        let query = "cat:cs.LG"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "arxiv.category.unknown" })
    }

    func testValidate_validAstrophysicsCategory_noWarning() async {
        // Given
        let query = "cat:astro-ph.GA"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "arxiv.category.unknown" })
    }

    // MARK: - Date Format Rule (arxiv.date.format)

    func testValidate_invalidDateFormat_detectsError() async {
        // Given
        let query = "submittedDate:[2024 TO 2025]"  // Missing full datetime format

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "arxiv.date.format" })
    }

    func testValidate_validDateFormat_noError() async {
        // Given
        let query = "submittedDate:[202401010000 TO 202412312359]"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertFalse(result.issues.contains { $0.ruleID == "arxiv.date.format" })
    }

    // MARK: - Empty Query

    func testValidate_emptyQuery_noIssues() async {
        // Given
        let query = ""

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.issues.isEmpty)
    }

    // MARK: - Valid Complex Query

    func testValidate_validComplexQuery_noIssues() async {
        // Given
        let query = "au:Smith AND ti:neural ANDNOT cat:cs.AI"

        // When
        let result = await assistant.validate(query)

        // Then
        XCTAssertTrue(result.isValid)
    }
}

// MARK: - Query Assistance Service Tests

final class QueryAssistanceServiceTests: XCTestCase {

    var service: QueryAssistanceService!

    override func setUp() async throws {
        try await super.setUp()
        service = QueryAssistanceService()
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    func testRegister_andRetrieveAssistant() async {
        // Given
        let adsAssistant = ADSQueryAssistant()

        // When
        await service.register(adsAssistant)
        let retrieved = await service.assistant(for: .ads)

        // Then
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.source, .ads)
    }

    func testValidate_withRegisteredAssistant() async {
        // Given
        let adsAssistant = ADSQueryAssistant()
        await service.register(adsAssistant)

        // When
        let result = await service.validate("author:Einstein, A", for: .ads)

        // Then
        XCTAssertTrue(result.hasErrors, "Should validate using registered ADS assistant")
    }

    func testValidate_withoutRegisteredAssistant_returnsEmpty() async {
        // Given - no assistant registered

        // When
        let result = await service.validate("test", for: .arxiv)

        // Then
        XCTAssertTrue(result.issues.isEmpty, "Should return empty result when no assistant registered")
    }
}

// MARK: - Query Validation Result Tests

final class QueryValidationResultTests: XCTestCase {

    func testHasErrors_withError_returnsTrue() {
        let result = QueryValidationResult(
            issues: [
                QueryValidationIssue(
                    ruleID: "test.error",
                    severity: .error,
                    message: "Test error"
                )
            ],
            query: "test"
        )

        XCTAssertTrue(result.hasErrors)
        XCTAssertFalse(result.isValid)
    }

    func testHasErrors_withOnlyWarnings_returnsFalse() {
        let result = QueryValidationResult(
            issues: [
                QueryValidationIssue(
                    ruleID: "test.warning",
                    severity: .warning,
                    message: "Test warning"
                )
            ],
            query: "test"
        )

        XCTAssertFalse(result.hasErrors)
        XCTAssertTrue(result.hasWarnings)
        XCTAssertTrue(result.isValid)
    }

    func testFilters_separateIssuesBySeverity() {
        let result = QueryValidationResult(
            issues: [
                QueryValidationIssue(ruleID: "test.error", severity: .error, message: "Error"),
                QueryValidationIssue(ruleID: "test.warning", severity: .warning, message: "Warning"),
                QueryValidationIssue(ruleID: "test.hint", severity: .hint, message: "Hint")
            ],
            query: "test"
        )

        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.hints.count, 1)
    }
}

// MARK: - Preview Result Tests

final class QueryPreviewResultTests: XCTestCase {

    func testCategory_noResults() {
        let result = QueryPreviewResult(totalResults: 0)
        XCTAssertEqual(result.category, .noResults)
    }

    func testCategory_goodResults() {
        let result = QueryPreviewResult(totalResults: 500)
        XCTAssertEqual(result.category, .good)
    }

    func testCategory_tooManyResults() {
        let result = QueryPreviewResult(totalResults: 50_000)
        XCTAssertEqual(result.category, .tooMany)
    }

    func testCategory_atBoundary() {
        let result = QueryPreviewResult(totalResults: 10_000)
        XCTAssertEqual(result.category, .good, "10,000 should still be in 'good' category")
    }
}
