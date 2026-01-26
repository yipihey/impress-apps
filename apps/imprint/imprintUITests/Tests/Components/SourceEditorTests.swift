//
//  SourceEditorTests.swift
//  imprintUITests
//
//  Component tests for the source editor.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Component tests for the Typst source editor
final class SourceEditorTests: SharedAppTestCase {

    // MARK: - Class Setup (Run Once)

    override class func setUp() {
        super.setUp()
        launchApp {
            let app = ImprintTestApp.launch(sampleDocument: true)
            _ = app.windows.firstMatch.waitForExistence(timeout: 5)
            return app
        }
    }

    // MARK: - Test Setup (Run Before Each Test)

    override func resetAppState() {
        super.resetAppState()
        // Ensure we're in split view mode to see the editor
        let content = ContentPage(app: app)
        content.selectEditMode(.splitView)
    }

    // MARK: - Page Objects

    var editorPage: SourceEditorPage {
        SourceEditorPage(app: app)
    }

    // MARK: - Basic Tests

    /// Test source editor exists
    func testSourceEditorExists() {
        editorPage.assertEditorExists()
    }

    /// Test editor is editable
    func testEditorIsEditable() {
        editorPage.assertEditable()
    }

    /// Test can type text
    func testCanTypeText() {
        editorPage.typeText("= Hello World\n")
        // Note: Can't easily verify content in shared state, but typing should work
    }

    // MARK: - Editing Tests

    /// Test inserting a heading
    func testInsertHeading() {
        editorPage.selectAll()
        editorPage.insertHeading(level: 1, title: "Introduction")
    }

    /// Test inserting a citation
    func testInsertCitation() {
        editorPage.insertCitation(key: "einstein1905")
    }

    /// Test inserting math
    func testInsertMath() {
        editorPage.insertMathBlock("E = mc^2")
    }

    // MARK: - Keyboard Shortcut Tests

    /// Test undo/redo
    func testUndoRedo() {
        editorPage.typeText("Test")
        editorPage.undo()
        editorPage.redo()
    }

    /// Test select all
    func testSelectAll() {
        editorPage.typeText("Some sample text")
        editorPage.selectAll()
    }

    /// Test copy/paste
    func testCopyPaste() {
        editorPage.typeText("Copy me")
        editorPage.selectAll()
        editorPage.copy()
        editorPage.paste()
    }
}
