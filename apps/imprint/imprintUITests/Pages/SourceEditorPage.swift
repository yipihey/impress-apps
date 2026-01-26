//
//  SourceEditorPage.swift
//  imprintUITests
//
//  Page Object for the Typst source editor.
//

import XCTest
import ImpressTestKit

/// Page Object for the Typst source code editor
struct SourceEditorPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// Source editor container
    var container: XCUIElement {
        app[ImprintAccessibilityID.SourceEditor.container]
    }

    /// The text view within the editor
    var textView: XCUIElement {
        // Try by accessibility identifier first
        let byId = app[ImprintAccessibilityID.SourceEditor.textView]
        if byId.exists { return byId }
        // Fallback to searching within container
        let inContainer = container.textViews.firstMatch
        if inContainer.exists { return inContainer }
        // Fallback to any text view in the app
        return app.textViews.firstMatch
    }

    // MARK: - Actions

    /// Type text into the editor
    func typeText(_ text: String) {
        textView.tapWhenReady()
        textView.typeText(text)
    }

    /// Clear and type new text
    func clearAndTypeText(_ text: String) {
        textView.tapWhenReady()
        textView.clearAndTypeText(text)
    }

    /// Select all text
    func selectAll() {
        textView.tapWhenReady()
        app.typeKey("a", modifierFlags: .command)
    }

    /// Copy selected text
    func copy() {
        app.typeKey("c", modifierFlags: .command)
    }

    /// Paste text
    func paste() {
        app.typeKey("v", modifierFlags: .command)
    }

    /// Cut selected text
    func cut() {
        app.typeKey("x", modifierFlags: .command)
    }

    /// Undo last action
    func undo() {
        app.typeKey("z", modifierFlags: .command)
    }

    /// Redo last undone action
    func redo() {
        app.typeKey("z", modifierFlags: [.command, .shift])
    }

    /// Insert citation at current cursor position
    func insertCitation(key: String) {
        typeText("@\(key)")
    }

    /// Insert heading
    func insertHeading(level: Int, title: String) {
        let prefix = String(repeating: "=", count: level)
        typeText("\(prefix) \(title)\n")
    }

    /// Insert math block
    func insertMathBlock(_ math: String) {
        typeText("$ \(math) $")
    }

    /// Navigate to specific line
    func goToLine(_ line: Int) {
        app.typeKey("g", modifierFlags: .command)
        // Type the line number in the Go to Line dialog
        let lineField = app.textFields.firstMatch
        lineField.typeTextWhenReady("\(line)")
        app.typeKey(.return, modifierFlags: [])
    }

    // MARK: - Assertions

    /// Wait for editor to be ready
    @discardableResult
    func waitForEditor(timeout: TimeInterval = 5) -> Bool {
        container.waitForExistence(timeout: timeout)
    }

    /// Assert editor exists
    func assertEditorExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            container.exists,
            "Source editor should exist",
            file: file,
            line: line
        )
    }

    /// Assert text view is editable (verifies it exists and is hittable, which implies it can receive input)
    func assertEditable(file: StaticString = #file, line: UInt = #line) {
        // For NSTextView wrapped in NSViewRepresentable, isEnabled may not reliably indicate editability
        // Instead, verify the text view exists and is accessible (hittable)
        let textViewExists = textView.waitForExistence(timeout: 3)
        XCTAssertTrue(
            textViewExists && textView.isHittable,
            "Source editor text view should be editable (exists and hittable)",
            file: file,
            line: line
        )
    }

    /// Assert content contains text
    func assertContainsText(_ text: String, file: StaticString = #file, line: UInt = #line) {
        let content = textView.value as? String ?? ""
        XCTAssertTrue(
            content.contains(text),
            "Source editor should contain '\(text)'",
            file: file,
            line: line
        )
    }
}
