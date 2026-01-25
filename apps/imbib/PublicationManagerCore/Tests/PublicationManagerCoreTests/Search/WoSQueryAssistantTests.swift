//
//  WoSQueryAssistantTests.swift
//  PublicationManagerCoreTests
//
//  Tests for Web of Science query validation rules.
//

import XCTest
@testable import PublicationManagerCore

final class WoSQueryAssistantTests: XCTestCase {

    var assistant: WoSQueryAssistant!

    override func setUp() async throws {
        try await super.setUp()
        assistant = WoSQueryAssistant()
    }

    override func tearDown() async throws {
        assistant = nil
        try await super.tearDown()
    }

    // MARK: - Source Tests

    func testSource_isWoS() async {
        let source = await assistant.source
        XCTAssertEqual(source, .wos)
    }

    func testKnownFields_containsWoSFields() async {
        let knownFields = await assistant.knownFields

        XCTAssertTrue(knownFields.contains("ts"))
        XCTAssertTrue(knownFields.contains("ti"))
        XCTAssertTrue(knownFields.contains("au"))
        XCTAssertTrue(knownFields.contains("do"))
        XCTAssertTrue(knownFields.contains("py"))
    }

    // MARK: - Valid Query Tests

    func testValidate_validTopicQuery_noIssues() async {
        let result = await assistant.validate("TS=quantum computing")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidate_validAuthorQuery_noIssues() async {
        let result = await assistant.validate("AU=Einstein, Albert")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidate_validBooleanQuery_noIssues() async {
        let result = await assistant.validate("TS=quantum AND TI=algorithm")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidate_validYearQuery_noIssues() async {
        let result = await assistant.validate("PY=2020")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidate_validYearRangeQuery_noIssues() async {
        let result = await assistant.validate("PY=2020-2024")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidate_validProximityQuery_noIssues() async {
        let result = await assistant.validate("TS=quantum NEAR/5 computing")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testValidate_emptyQuery_noIssues() async {
        let result = await assistant.validate("")
        XCTAssertTrue(result.issues.isEmpty)
    }

    // MARK: - Operator Case Tests

    func testValidate_lowercaseAND_hasError() async {
        let result = await assistant.validate("TS=quantum and TI=algorithm")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.operator.case" })

        let issue = result.issues.first { $0.ruleID == "wos.operator.case" }!
        XCTAssertEqual(issue.severity, .error)
        XCTAssertTrue(issue.message.contains("AND"))
    }

    func testValidate_lowercaseOR_hasError() async {
        let result = await assistant.validate("TS=quantum or TI=algorithm")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.operator.case" })
    }

    func testValidate_lowercaseNOT_hasError() async {
        let result = await assistant.validate("TS=quantum not TI=classical")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.operator.case" })
    }

    func testValidate_mixedCaseOperator_hasError() async {
        let result = await assistant.validate("TS=quantum And TI=algorithm")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.operator.case" })
    }

    // MARK: - Field Syntax Tests

    func testValidate_fieldWithoutEquals_hasError() async {
        // This tests AU Einstein (missing =) which should trigger wos.field.syntax
        let result = await assistant.validate("AU Einstein")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.field.syntax" })

        let issue = result.issues.first { $0.ruleID == "wos.field.syntax" }!
        XCTAssertEqual(issue.severity, .error)
    }

    // MARK: - Unknown Field Tests

    func testValidate_unknownField_hasWarning() async {
        let result = await assistant.validate("XX=test")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.field.unknown" })

        let issue = result.issues.first { $0.ruleID == "wos.field.unknown" }!
        XCTAssertEqual(issue.severity, .warning)
    }

    // MARK: - Year Format Tests

    func testValidate_invalidYearFormat_hasError() async {
        let result = await assistant.validate("PY=twenty twenty")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.year.format" })

        let issue = result.issues.first { $0.ruleID == "wos.year.format" }!
        XCTAssertEqual(issue.severity, .error)
    }

    func testValidate_invalidYearRangeFormat_hasError() async {
        let result = await assistant.validate("PY=2020/2024")  // Wrong separator
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.year.format" })
    }

    // MARK: - Parentheses Tests

    func testValidate_unbalancedParentheses_openingExtra_hasError() async {
        let result = await assistant.validate("((TS=quantum AND TI=algorithm)")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.paren.unbalanced" })

        let issue = result.issues.first { $0.ruleID == "wos.paren.unbalanced" }!
        XCTAssertEqual(issue.severity, .error)
    }

    func testValidate_unbalancedParentheses_closingExtra_hasError() async {
        let result = await assistant.validate("(TS=quantum AND TI=algorithm))")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.paren.unbalanced" })
    }

    func testValidate_balancedParentheses_noError() async {
        let result = await assistant.validate("(TS=quantum AND TI=algorithm)")
        XCTAssertFalse(result.issues.contains { $0.ruleID == "wos.paren.unbalanced" })
    }

    // MARK: - Quote Tests

    func testValidate_unbalancedQuotes_hasError() async {
        let result = await assistant.validate("TI=\"exact phrase")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.quote.unbalanced" })

        let issue = result.issues.first { $0.ruleID == "wos.quote.unbalanced" }!
        XCTAssertEqual(issue.severity, .error)
    }

    func testValidate_balancedQuotes_noError() async {
        let result = await assistant.validate("TI=\"exact phrase\"")
        XCTAssertFalse(result.issues.contains { $0.ruleID == "wos.quote.unbalanced" })
    }

    // MARK: - Proximity Tests

    func testValidate_lowercaseNEAR_hasWarning() async {
        let result = await assistant.validate("TS=quantum near/5 computing")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.proximity.format" })
    }

    func testValidate_NEARWithoutDistance_hasHint() async {
        let result = await assistant.validate("TS=quantum NEAR computing")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.proximity.format" })

        let issue = result.issues.first { $0.ruleID == "wos.proximity.format" }!
        XCTAssertEqual(issue.severity, .hint)
    }

    // MARK: - Complex Query Tests

    func testValidate_complexValidQuery_noErrors() async {
        let query = "(TS=\"machine learning\" OR TI=neural) AND AU=LeCun AND PY=2010-2024"
        let result = await assistant.validate(query)

        let errors = result.issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "Complex valid query should have no errors: \(errors)")
    }

    func testValidate_complexInvalidQuery_multipleIssues() async {
        let query = "TS=quantum and TI=\"phrase PY=invalid"
        // Has: lowercase operator, unbalanced quote, invalid year

        let result = await assistant.validate(query)
        XCTAssertFalse(result.issues.isEmpty)

        // Should have at least operator case error and quote error
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.operator.case" })
        XCTAssertTrue(result.issues.contains { $0.ruleID == "wos.quote.unbalanced" })
    }

    // MARK: - Suggestion Tests

    func testValidate_operatorCase_hasSuggestion() async {
        let result = await assistant.validate("TS=quantum and TI=algorithm")
        let issue = result.issues.first { $0.ruleID == "wos.operator.case" }!

        XCTAssertFalse(issue.suggestions.isEmpty)
        XCTAssertTrue(issue.suggestions.first!.correctedQuery.contains("AND"))
    }
}
