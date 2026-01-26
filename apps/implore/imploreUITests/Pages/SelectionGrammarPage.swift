//
//  SelectionGrammarPage.swift
//  imploreUITests
//
//  Page Object for the selection grammar sheet.
//

import XCTest
import ImpressTestKit

/// Page Object for the selection grammar sheet
struct SelectionGrammarPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// Selection grammar container (the sheet)
    var container: XCUIElement {
        app[ImploreAccessibilityID.SelectionGrammar.container]
    }

    /// Expression text field
    var expressionField: XCUIElement {
        app[ImploreAccessibilityID.SelectionGrammar.expressionField]
    }

    /// Apply button
    var applyButton: XCUIElement {
        app[ImploreAccessibilityID.SelectionGrammar.applyButton]
    }

    /// Cancel button
    var cancelButton: XCUIElement {
        app[ImploreAccessibilityID.SelectionGrammar.cancelButton]
    }

    /// Error message (when expression is invalid)
    var errorMessage: XCUIElement {
        app[ImploreAccessibilityID.SelectionGrammar.errorMessage]
    }

    // MARK: - State Checks

    /// Check if the selection grammar sheet is open
    var isOpen: Bool {
        container.exists || expressionField.exists
    }

    /// Check if there's an error
    var hasError: Bool {
        errorMessage.exists
    }

    /// Get the current expression
    var currentExpression: String {
        expressionField.value as? String ?? ""
    }

    // MARK: - Actions

    /// Open selection grammar using keyboard shortcut
    func open() {
        app.typeKey("g", modifierFlags: [.command, .shift])
    }

    /// Enter an expression
    func enterExpression(_ expression: String) {
        expressionField.tapWhenReady()
        expressionField.clearAndTypeText(expression)
    }

    /// Apply the current expression
    func apply() {
        applyButton.tapWhenReady()
    }

    /// Cancel and close the sheet
    func cancel() {
        cancelButton.tapWhenReady()
    }

    /// Close using escape key
    func closeWithEscape() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Enter expression and apply
    func enterAndApply(_ expression: String) {
        enterExpression(expression)
        apply()
    }

    // MARK: - Assertions

    /// Wait for selection grammar sheet to appear
    @discardableResult
    func waitForSheet(timeout: TimeInterval = 5) -> Bool {
        expressionField.waitForExistence(timeout: timeout)
    }

    /// Wait for sheet to close
    @discardableResult
    func waitForClose(timeout: TimeInterval = 5) -> Bool {
        container.waitForDisappearance(timeout: timeout)
    }

    /// Assert sheet is open
    func assertOpen(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            isOpen,
            "Selection grammar sheet should be open",
            file: file,
            line: line
        )
    }

    /// Assert sheet is closed
    func assertClosed(file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            isOpen,
            "Selection grammar sheet should be closed",
            file: file,
            line: line
        )
    }

    /// Assert error is shown
    func assertError(_ message: String? = nil, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            hasError,
            "Error message should be shown",
            file: file,
            line: line
        )

        if let message = message {
            XCTAssertTrue(
                errorMessage.label.contains(message),
                "Error should contain '\(message)'",
                file: file,
                line: line
            )
        }
    }

    /// Assert no error is shown
    func assertNoError(file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            hasError,
            "No error message should be shown",
            file: file,
            line: line
        )
    }

    /// Assert expression field exists
    func assertExpressionFieldExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            expressionField.exists,
            "Expression field should exist",
            file: file,
            line: line
        )
    }
}
