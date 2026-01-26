//
//  SettingsPage.swift
//  imprintUITests
//
//  Page Object for the Settings window.
//

import XCTest
import ImpressTestKit

/// Page Object for the Settings window
struct SettingsPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Window Elements

    /// The settings window
    var window: XCUIElement {
        app.windows["Settings"]
    }

    /// Settings container
    var container: XCUIElement {
        app[ImprintAccessibilityID.Settings.container]
    }

    /// Check if settings window is open
    var isOpen: Bool {
        window.exists || container.exists
    }

    // MARK: - Tab Buttons

    /// General tab
    var generalTab: XCUIElement {
        window.toolbars.buttons["General"]
    }

    /// Editor tab
    var editorTab: XCUIElement {
        window.toolbars.buttons["Editor"]
    }

    /// Export tab
    var exportTab: XCUIElement {
        window.toolbars.buttons["Export"]
    }

    /// Account tab
    var accountTab: XCUIElement {
        window.toolbars.buttons["Account"]
    }

    // MARK: - Open/Close

    /// Open settings window using Cmd+,
    func open() {
        app.typeKey(",", modifierFlags: .command)
    }

    /// Close settings window
    func close() {
        if isOpen {
            window.buttons[XCUIIdentifierCloseWindow].click()
        }
    }

    /// Close using escape
    func closeWithEscape() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Wait for settings window to appear
    @discardableResult
    func waitForWindow(timeout: TimeInterval = 2) -> Bool {
        window.waitForExistence(timeout: timeout)
    }

    // MARK: - Tab Navigation

    /// Select the General tab
    func selectGeneralTab() {
        generalTab.click()
    }

    /// Select the Editor tab
    func selectEditorTab() {
        editorTab.click()
    }

    /// Select the Export tab
    func selectExportTab() {
        exportTab.click()
    }

    /// Select the Account tab
    func selectAccountTab() {
        accountTab.click()
    }

    // MARK: - General Settings

    /// Default edit mode picker
    var editModePicker: XCUIElement {
        window.popUpButtons["Default Edit Mode"]
    }

    /// Auto-save interval stepper
    var autoSaveStepper: XCUIElement {
        window.steppers.firstMatch
    }

    /// Backup toggle
    var backupToggle: XCUIElement {
        window.switches["Create automatic backups"]
    }

    /// Select default edit mode
    func selectDefaultEditMode(_ mode: String) {
        selectGeneralTab()
        editModePicker.click()
        app.menuItems[mode].click()
    }

    /// Toggle automatic backups
    func toggleBackups() {
        selectGeneralTab()
        backupToggle.click()
    }

    // MARK: - Editor Settings

    /// Font family picker
    var fontFamilyPicker: XCUIElement {
        window.popUpButtons["Font Family"]
    }

    /// Line numbers toggle
    var lineNumbersToggle: XCUIElement {
        window.switches["Show line numbers"]
    }

    /// Highlight current line toggle
    var highlightLineToggle: XCUIElement {
        window.switches["Highlight current line"]
    }

    /// Wrap lines toggle
    var wrapLinesToggle: XCUIElement {
        window.switches["Wrap long lines"]
    }

    /// Select font family
    func selectFontFamily(_ family: String) {
        selectEditorTab()
        fontFamilyPicker.click()
        app.menuItems[family].click()
    }

    /// Toggle line numbers
    func toggleLineNumbers() {
        selectEditorTab()
        lineNumbersToggle.click()
    }

    // MARK: - Assertions

    /// Assert settings window is open
    func assertOpen(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            isOpen,
            "Settings window should be open",
            file: file,
            line: line
        )
    }

    /// Assert settings window is closed
    func assertClosed(file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            isOpen,
            "Settings window should be closed",
            file: file,
            line: line
        )
    }

    /// Assert a tab is selected
    func assertTabSelected(_ tabName: String, file: StaticString = #file, line: UInt = #line) {
        let tab = window.toolbars.buttons[tabName]
        XCTAssertTrue(
            tab.isSelected,
            "Tab '\(tabName)' should be selected",
            file: file,
            line: line
        )
    }

    /// Assert General tab exists
    func assertGeneralTabExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            generalTab.exists,
            "General tab should exist",
            file: file,
            line: line
        )
    }

    /// Assert Editor tab exists
    func assertEditorTabExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            editorTab.exists,
            "Editor tab should exist",
            file: file,
            line: line
        )
    }
}
