//
//  ContentPage.swift
//  imprintUITests
//
//  Page Object for the main document content view.
//

import XCTest
import ImpressTestKit

/// Page Object for the main document content view
struct ContentPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Toolbar Elements

    /// Edit mode picker (Direct PDF, Split View, Text Only)
    var editModePicker: XCUIElement {
        app[ImprintAccessibilityID.Toolbar.editModePicker]
    }

    /// Compile button
    var compileButton: XCUIElement {
        app[ImprintAccessibilityID.Toolbar.compileButton]
    }

    /// Citation insertion button
    var citationButton: XCUIElement {
        app[ImprintAccessibilityID.Toolbar.citationButton]
    }

    /// Share button
    var shareButton: XCUIElement {
        app[ImprintAccessibilityID.Toolbar.shareButton]
    }

    // MARK: - Sidebar Elements

    /// Document outline sidebar
    var outlineSidebar: XCUIElement {
        app[ImprintAccessibilityID.Sidebar.outline]
    }

    // MARK: - Content Elements

    /// Main editor area
    var editorArea: XCUIElement {
        app[ImprintAccessibilityID.Content.editorArea]
    }

    // MARK: - Actions

    /// Compile the document
    func compile() {
        compileButton.tapWhenReady()
    }

    /// Compile using keyboard shortcut
    func compileWithKeyboard() {
        app.typeKey("b", modifierFlags: .command)
    }

    /// Open citation picker
    func openCitationPicker() {
        // Ensure the main window is focused first
        app.windows.firstMatch.click()
        citationButton.tapWhenReady()
    }

    /// Open citation picker and wait for it to appear
    @discardableResult
    func openCitationPickerAndWait(timeout: TimeInterval = 5) -> Bool {
        openCitationPicker()
        let container = app[ImprintAccessibilityID.CitationPicker.container]
        return container.waitForExistence(timeout: timeout)
    }

    /// Open citation picker with keyboard shortcut
    func openCitationPickerWithKeyboard() {
        app.typeKey("k", modifierFlags: [.command, .shift])
    }

    /// Select edit mode
    func selectEditMode(_ mode: EditMode) {
        // The picker is segmented, so we access the specific segment by identifier
        let segment = app[mode.identifier]
        segment.tapWhenReady()
    }

    /// Cycle to next edit mode using Tab
    func cycleEditMode() {
        app.typeKey(.tab, modifierFlags: [])
    }

    // MARK: - Assertions

    /// Wait for content view to be ready
    @discardableResult
    func waitForContent(timeout: TimeInterval = 5) -> Bool {
        editorArea.waitForExistence(timeout: timeout)
    }

    /// Assert compile button exists
    func assertCompileButtonExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            compileButton.exists,
            "Compile button should exist",
            file: file,
            line: line
        )
    }

    /// Assert citation button exists
    func assertCitationButtonExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            citationButton.exists,
            "Citation button should exist",
            file: file,
            line: line
        )
    }

    /// Assert edit mode picker exists
    func assertEditModePickerExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            editModePicker.exists,
            "Edit mode picker should exist",
            file: file,
            line: line
        )
    }
}

// MARK: - Edit Mode

/// Edit modes available in imprint
enum EditMode {
    case directPdf
    case splitView
    case textOnly

    var identifier: String {
        switch self {
        case .directPdf: return ImprintAccessibilityID.Toolbar.Mode.directPdf
        case .splitView: return ImprintAccessibilityID.Toolbar.Mode.splitView
        case .textOnly: return ImprintAccessibilityID.Toolbar.Mode.textOnly
        }
    }

    var label: String {
        switch self {
        case .directPdf: return "Direct PDF"
        case .splitView: return "Split View"
        case .textOnly: return "Text Only"
        }
    }
}
