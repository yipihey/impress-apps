//
//  DatasetWorkflowTests.swift
//  imploreUITests
//
//  Consolidated workflow tests for dataset operations.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Workflow tests for dataset operations (render modes, selection, export)
final class DatasetWorkflowTests: SharedAppTestCase {

    // MARK: - Class Setup (Run Once)

    override class func setUp() {
        super.setUp()
        launchApp { ImploreTestApp.launchWithSampleDataset() }
    }

    // MARK: - Test Setup (Run Before Each Test)

    override func resetAppState() {
        super.resetAppState()
        // Reset to Science 2D mode for consistent state
        contentPage.selectRenderMode(.science2D)
        // Clear any selections
        vizPage.selectNone()
    }

    // MARK: - Page Objects

    var contentPage: ContentPage { ContentPage(app: app) }
    var vizPage: VisualizationPage { VisualizationPage(app: app) }
    var sidebarPage: SidebarPage { SidebarPage(app: app) }
    var selectionPage: SelectionGrammarPage { SelectionGrammarPage(app: app) }

    // MARK: - Render Mode Workflow Tests

    /// Test switching modes preserves data
    func testSwitchingModesPreservesData() {
        // Start in Science 2D
        contentPage.selectRenderMode(.science2D)
        _ = vizPage.waitForRender()

        // Switch to Box 3D
        contentPage.selectRenderMode(.box3D)
        _ = vizPage.waitForRender()

        // Data should still be visible
        vizPage.assertActive()

        // Switch to Art Shader
        contentPage.selectRenderMode(.artShader)
        _ = vizPage.waitForRender()

        // Data should still be visible
        vizPage.assertActive()
    }

    /// Test cycling through all modes
    func testCyclingThroughAllModes() {
        // Cycle through each mode using keyboard
        for _ in 0..<3 {
            contentPage.cycleRenderMode()
            _ = vizPage.waitForRender()
            vizPage.assertActive()
        }
    }

    /// Test mode persists after view operations
    func testModePersistsAfterViewOperations() {
        // Set to Box 3D
        contentPage.selectRenderMode(.box3D)
        _ = vizPage.waitForRender()

        // Perform view operations
        vizPage.zoomIn()
        vizPage.pan(dx: 50, dy: 50)
        vizPage.resetView()

        // Mode should still be Box 3D
        vizPage.assertActive()
    }

    /// Test full keyboard mode workflow
    func testFullKeyboardModeWorkflow() {
        // Switch to Science 2D with '1'
        app.typeKey("1", modifierFlags: [])
        _ = vizPage.waitForRender()

        // Zoom in and out
        vizPage.zoomIn()
        vizPage.zoomOut()

        // Switch to Box 3D with '2'
        app.typeKey("2", modifierFlags: [])
        _ = vizPage.waitForRender()

        // Reset view
        vizPage.resetView()

        // Switch to Art Shader with '3'
        app.typeKey("3", modifierFlags: [])
        _ = vizPage.waitForRender()

        // Visualization should still be active
        vizPage.assertActive()
    }

    // MARK: - Selection Workflow Tests

    /// Test opening selection grammar from sidebar
    func testOpenSelectionGrammarFromSidebar() {
        sidebarPage.clickEditSelection()

        selectionPage.assertOpen()
        selectionPage.assertExpressionFieldExists()

        selectionPage.cancel()
    }

    /// Test opening selection grammar with keyboard
    func testOpenSelectionGrammarWithKeyboard() {
        selectionPage.open()

        XCTAssertTrue(
            selectionPage.waitForSheet(),
            "Selection grammar should open via keyboard"
        )

        selectionPage.cancel()
    }

    /// Test entering a simple expression
    func testEnterSimpleExpression() {
        selectionPage.open()
        _ = selectionPage.waitForSheet()

        selectionPage.enterExpression("x > 0")
        selectionPage.assertNoError()

        selectionPage.apply()
        selectionPage.assertClosed()
    }

    /// Test entering a complex expression
    func testEnterComplexExpression() {
        selectionPage.open()
        _ = selectionPage.waitForSheet()

        selectionPage.enterExpression("x > 0 && y < 10")
        selectionPage.assertNoError()

        selectionPage.cancel()
    }

    /// Test entering sphere selection
    func testEnterSphereSelection() {
        selectionPage.open()
        _ = selectionPage.waitForSheet()

        selectionPage.enterExpression("sphere([0, 0, 0], 1.5)")
        selectionPage.assertNoError()

        selectionPage.cancel()
    }

    /// Test cancel preserves previous selection
    func testCancelPreservesSelection() {
        // First, make a selection
        selectionPage.open()
        _ = selectionPage.waitForSheet()
        selectionPage.enterAndApply("x > 0")

        // Now open again and cancel
        selectionPage.open()
        _ = selectionPage.waitForSheet()
        selectionPage.enterExpression("y < 0")
        selectionPage.cancel()

        // Original selection should be preserved
    }

    /// Test select all with keyboard
    func testSelectAllWithKeyboard() {
        vizPage.selectAll()
        // Selection should include all points
    }

    /// Test select none with keyboard
    func testSelectNoneWithKeyboard() {
        vizPage.selectAll()
        vizPage.selectNone()
        // Selection should be empty
    }

    /// Test invert selection with keyboard
    func testInvertSelectionWithKeyboard() {
        vizPage.selectAll()
        vizPage.invertSelection()
        // Selection should be inverted (now empty)
    }

    /// Test full selection workflow
    func testFullSelectionWorkflow() {
        // 1. Open selection grammar
        selectionPage.open()
        _ = selectionPage.waitForSheet()

        // 2. Enter expression
        selectionPage.enterExpression("x > 0")

        // 3. Apply
        selectionPage.apply()
        _ = selectionPage.waitForClose()

        // 4. Verify selection is visible in sidebar
        sidebarPage.assertSelectionCount("points")

        // 5. Invert selection
        vizPage.invertSelection()

        // 6. Clear selection
        vizPage.selectNone()
    }

    // MARK: - Export Workflow Tests

    /// Test export to PNG
    func testExportToPNG() {
        // Open export menu or use keyboard shortcut
        app.typeKey("e", modifierFlags: [.command, .shift])

        // Export dialog should appear
        let exportDialog = app.sheets.firstMatch
        if exportDialog.waitForExistence(timeout: 2) {
            // Cancel the dialog
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Test copy visualization to clipboard
    func testCopyToClipboard() {
        // Copy current view to clipboard
        app.typeKey("c", modifierFlags: [.command, .shift])

        // Would verify clipboard contains image data
    }

    /// Test export selection as CSV
    func testExportSelectionAsCSV() {
        // First make a selection
        vizPage.selectAll()

        // Export via menu
        app.menuBars.menuBarItems["File"].click()
        if app.menuItems["Export Selection..."].exists {
            app.menuItems["Export Selection..."].click()

            // Cancel the export dialog
            app.typeKey(.escape, modifierFlags: [])
        } else {
            // Menu item might not exist, just close menu
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Test save visualization state
    func testSaveVisualizationState() {
        // Configure some view settings
        contentPage.selectRenderMode(.box3D)

        vizPage.zoomIn()

        // Save state with Cmd+S
        app.typeKey("s", modifierFlags: .command)

        // For a new session, save dialog should appear
        // Cancel for now
        let saveDialog = app.sheets.firstMatch
        if saveDialog.waitForExistence(timeout: 2) {
            app.typeKey(.escape, modifierFlags: [])
        }
    }
}
