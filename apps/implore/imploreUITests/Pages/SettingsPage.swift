//
//  SettingsPage.swift
//  imploreUITests
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
        app[ImploreAccessibilityID.Settings.container]
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

    /// Rendering tab
    var renderingTab: XCUIElement {
        window.toolbars.buttons["Rendering"]
    }

    /// Colormaps tab
    var colormapsTab: XCUIElement {
        window.toolbars.buttons["Colormaps"]
    }

    /// Keyboard tab
    var keyboardTab: XCUIElement {
        window.toolbars.buttons["Keyboard"]
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

    /// Select the Rendering tab
    func selectRenderingTab() {
        renderingTab.click()
    }

    /// Select the Colormaps tab
    func selectColormapsTab() {
        colormapsTab.click()
    }

    /// Select the Keyboard tab
    func selectKeyboardTab() {
        keyboardTab.click()
    }

    // MARK: - Rendering Settings

    /// Point size slider
    var pointSizeSlider: XCUIElement {
        window.sliders.firstMatch
    }

    /// Antialiasing toggle
    var antialiasingToggle: XCUIElement {
        window.switches["Enable antialiasing"]
    }

    /// Max FPS picker
    var maxFPSPicker: XCUIElement {
        window.popUpButtons["Max FPS"]
    }

    /// Adjust point size
    func setPointSize(_ value: Double) {
        selectRenderingTab()
        pointSizeSlider.adjust(toNormalizedSliderPosition: CGFloat(value))
    }

    /// Toggle antialiasing
    func toggleAntialiasing() {
        selectRenderingTab()
        antialiasingToggle.click()
    }

    // MARK: - Colormap Settings

    /// Colormap picker
    var colormapPicker: XCUIElement {
        window.popUpButtons["Colormap"]
    }

    /// Select a colormap
    func selectColormap(_ name: String) {
        selectColormapsTab()
        colormapPicker.click()
        app.menuItems[name].click()
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

    /// Assert Rendering tab exists
    func assertRenderingTabExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            renderingTab.exists,
            "Rendering tab should exist",
            file: file,
            line: line
        )
    }
}
