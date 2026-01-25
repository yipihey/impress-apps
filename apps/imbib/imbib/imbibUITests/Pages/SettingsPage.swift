//
//  SettingsPage.swift
//  imbibUITests
//
//  Page Object for the Settings window.
//

import XCTest

/// Page Object for the Settings window.
///
/// Provides access to settings tabs and configuration options.
struct SettingsPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Window Elements

    /// The settings window
    var window: XCUIElement {
        app.windows["Settings"]
    }

    /// Check if settings window is open
    var isOpen: Bool {
        window.exists
    }

    // MARK: - Tab Buttons

    /// General tab button
    var generalTab: XCUIElement {
        window.toolbars.buttons["General"]
    }

    /// Sources tab button
    var sourcesTab: XCUIElement {
        window.toolbars.buttons["Sources"]
    }

    /// Appearance tab button
    var appearanceTab: XCUIElement {
        window.toolbars.buttons["Appearance"]
    }

    /// Shortcuts tab button
    var shortcutsTab: XCUIElement {
        window.toolbars.buttons["Shortcuts"]
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

    /// Select the Sources tab
    func selectSourcesTab() {
        sourcesTab.click()
    }

    /// Select the Appearance tab
    func selectAppearanceTab() {
        appearanceTab.click()
    }

    /// Select the Shortcuts tab
    func selectShortcutsTab() {
        shortcutsTab.click()
    }

    // MARK: - General Settings

    /// The default library picker
    var defaultLibraryPicker: XCUIElement {
        window.popUpButtons["Default Library"]
    }

    /// Select a default library
    func selectDefaultLibrary(_ name: String) {
        selectGeneralTab()
        defaultLibraryPicker.click()
        app.menuItems[name].click()
    }

    // MARK: - Sources Settings

    /// The ADS API key text field
    var adsAPIKeyField: XCUIElement {
        window.secureTextFields["ADS API Key"]
    }

    /// Enter ADS API key
    func enterADSAPIKey(_ key: String) {
        selectSourcesTab()
        adsAPIKeyField.click()
        adsAPIKeyField.typeText(key)
    }

    /// Check if a source is enabled
    func isSourceEnabled(_ sourceName: String) -> Bool {
        selectSourcesTab()
        let toggle = window.switches[sourceName]
        return toggle.value as? String == "1"
    }

    /// Toggle a source on/off
    func toggleSource(_ sourceName: String) {
        selectSourcesTab()
        let toggle = window.switches[sourceName]
        if toggle.exists {
            toggle.click()
        }
    }

    // MARK: - Appearance Settings

    /// The theme picker (Light/Dark/System)
    var themePicker: XCUIElement {
        window.popUpButtons["Theme"]
    }

    /// Select a theme
    func selectTheme(_ theme: String) {
        selectAppearanceTab()
        themePicker.click()
        app.menuItems[theme].click()
    }

    /// The font size slider
    var fontSizeSlider: XCUIElement {
        window.sliders["Font Size"]
    }

    /// Adjust font size
    func setFontSize(_ value: Double) {
        selectAppearanceTab()
        fontSizeSlider.adjust(toNormalizedSliderPosition: CGFloat(value))
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
        // Selected tabs typically have a different state
        XCTAssertTrue(
            tab.isSelected,
            "Tab '\(tabName)' should be selected",
            file: file,
            line: line
        )
    }

    /// Assert a source is enabled
    func assertSourceEnabled(_ sourceName: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            isSourceEnabled(sourceName),
            "Source '\(sourceName)' should be enabled",
            file: file,
            line: line
        )
    }

    /// Assert a source is disabled
    func assertSourceDisabled(_ sourceName: String, file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(
            isSourceEnabled(sourceName),
            "Source '\(sourceName)' should be disabled",
            file: file,
            line: line
        )
    }
}
