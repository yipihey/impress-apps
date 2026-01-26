//
//  RenderModeTests.swift
//  imploreUITests
//
//  Component tests for render mode switching.
//  Uses shared app instance for fast execution.
//

import XCTest
import ImpressTestKit

/// Component tests for render mode switching
final class RenderModeTests: SharedAppTestCase {

    // MARK: - Class Setup (Run Once)

    override class func setUp() {
        super.setUp()
        launchApp { ImploreTestApp.launchWithSampleDataset() }
    }

    // MARK: - Test Setup (Run Before Each Test)

    override func resetAppState() {
        super.resetAppState()
        // Tests can set their own initial state if needed
    }

    // MARK: - Page Objects

    var contentPage: ContentPage {
        ContentPage(app: app)
    }

    // MARK: - Render Mode Picker Tests

    /// Test render mode picker exists
    func testRenderModePickerExists() {
        contentPage.assertRenderModePickerExists()
    }

    // MARK: - Mode Switching Tests

    /// Test switching to Science 2D mode
    func testSwitchToScience2DMode() {
        contentPage.selectRenderMode(.science2D)
    }

    /// Test switching to Box 3D mode
    func testSwitchToBox3DMode() {
        contentPage.selectRenderMode(.box3D)
    }

    /// Test switching to Art Shader mode
    func testSwitchToArtShaderMode() {
        contentPage.selectRenderMode(.artShader)
    }

    /// Test switching to Histogram 1D mode
    func testSwitchToHistogram1DMode() {
        contentPage.selectRenderMode(.histogram1D)
    }

    // MARK: - Keyboard Shortcut Tests

    /// Test cycling through all 4 modes with Tab key
    func testCycleThroughAllModes() {
        // Start at Science 2D (default)
        contentPage.cycleRenderMode() // 2D → 3D
        contentPage.cycleRenderMode() // 3D → Art
        contentPage.cycleRenderMode() // Art → 1D
        contentPage.cycleRenderMode() // 1D → 2D (back to start)
    }

    /// Test switching to Science 2D with '1' key
    func testSwitchToScience2DWithKey() {
        app.typeKey("1", modifierFlags: [])
    }

    /// Test switching to Box 3D with '2' key
    func testSwitchToBox3DWithKey() {
        app.typeKey("2", modifierFlags: [])
    }

    /// Test switching to Art Shader with '3' key
    func testSwitchToArtShaderWithKey() {
        app.typeKey("3", modifierFlags: [])
    }

    /// Test switching to Histogram 1D with '4' key
    func testSwitchToHistogram1DWithKey() {
        app.typeKey("4", modifierFlags: [])
    }
}
