//
//  ContentPage.swift
//  imploreUITests
//
//  Page Object for the main content view.
//

import XCTest
import ImpressTestKit

/// Page Object for the main content view
struct ContentPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Toolbar Elements

    /// Render mode picker
    var renderModePicker: XCUIElement {
        app[ImploreAccessibilityID.Toolbar.renderModePicker]
    }

    // MARK: - Sidebar Elements

    /// Sidebar container
    var sidebar: XCUIElement {
        app[ImploreAccessibilityID.Sidebar.container]
    }

    /// Dataset name label
    var datasetName: XCUIElement {
        sidebar.staticTexts.firstMatch
    }

    // MARK: - State Checks

    /// Check if a dataset is loaded
    var hasDatasetLoaded: Bool {
        !app[ImploreAccessibilityID.Welcome.container].exists
    }

    // MARK: - Actions

    /// Select render mode
    func selectRenderMode(_ mode: RenderModeOption) {
        // For segmented picker, we can directly click the segment by its label
        // The picker contains buttons that can be accessed by their text
        let segment = app.buttons[mode.rawValue].firstMatch
        if segment.waitForExistence(timeout: 5) {
            segment.click()
        }
    }

    /// Cycle render mode with Tab key
    func cycleRenderMode() {
        app.typeKey(.tab, modifierFlags: [])
    }

    /// Open file using keyboard shortcut
    func openFile() {
        app.typeKey("o", modifierFlags: .command)
    }

    /// Open settings
    func openSettings() {
        app.typeKey(",", modifierFlags: .command)
    }

    // MARK: - Assertions

    /// Wait for content to be ready
    @discardableResult
    func waitForContent(timeout: TimeInterval = 5) -> Bool {
        sidebar.waitForExistence(timeout: timeout) || renderModePicker.waitForExistence(timeout: timeout)
    }

    /// Assert render mode picker exists
    func assertRenderModePickerExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            renderModePicker.exists,
            "Render mode picker should exist",
            file: file,
            line: line
        )
    }

    /// Assert sidebar exists
    func assertSidebarExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            sidebar.exists,
            "Sidebar should exist",
            file: file,
            line: line
        )
    }

    /// Assert dataset is loaded
    func assertDatasetLoaded(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            hasDatasetLoaded,
            "A dataset should be loaded",
            file: file,
            line: line
        )
    }
}

// MARK: - Render Mode Options

/// Render mode options in implore
enum RenderModeOption: String {
    case science2D = "Science 2D"
    case box3D = "Box 3D"
    case artShader = "Art Shader"
    case histogram1D = "Histogram 1D"
}
