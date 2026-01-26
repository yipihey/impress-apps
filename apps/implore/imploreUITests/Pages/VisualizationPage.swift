//
//  VisualizationPage.swift
//  imploreUITests
//
//  Page Object for the visualization area.
//

import XCTest
import ImpressTestKit

/// Page Object for the visualization area
struct VisualizationPage {

    // MARK: - Properties

    let app: XCUIApplication

    // MARK: - Elements

    /// Visualization container
    var container: XCUIElement {
        app[ImploreAccessibilityID.Visualization.container]
    }

    /// Metal rendering view
    var metalView: XCUIElement {
        app[ImploreAccessibilityID.Visualization.metalView]
    }

    /// Marginals panel (ECDF/PCDF)
    var marginalsPanel: XCUIElement {
        app[ImploreAccessibilityID.Visualization.marginalsPanel]
    }

    /// Status bar - it's a Text element showing status info
    var statusBar: XCUIElement {
        // The status bar shows text like "20 points | Mode: Science 2D | Selection: none"
        // Find by the "points" text which is always present
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'points'")).firstMatch
    }

    // MARK: - State Checks

    /// Check if visualization is active (has a Metal view)
    var isActive: Bool {
        metalView.exists
    }

    /// Get the status bar text - returns the element's identifier which contains the text
    var statusText: String {
        // In SwiftUI, staticText elements are identified by their content
        _ = statusBar.waitForExistence(timeout: 5)
        return statusBar.identifier
    }

    // MARK: - Actions

    /// Pan the visualization
    func pan(dx: CGFloat, dy: CGFloat) {
        let center = metalView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = center.withOffset(CGVector(dx: dx, dy: dy))
        center.press(forDuration: 0.1, thenDragTo: destination)
    }

    /// Zoom in using keyboard
    func zoomIn() {
        app.typeKey("+", modifierFlags: [])
    }

    /// Zoom out using keyboard
    func zoomOut() {
        app.typeKey("-", modifierFlags: [])
    }

    /// Reset view using keyboard
    func resetView() {
        app.typeKey("r", modifierFlags: [])
    }

    /// Select all points
    func selectAll() {
        app.typeKey("a", modifierFlags: .command)
    }

    /// Deselect all points
    func selectNone() {
        app.typeKey("a", modifierFlags: [.command, .shift])
    }

    /// Invert selection
    func invertSelection() {
        app.typeKey("i", modifierFlags: [.command, .shift])
    }

    // MARK: - Assertions

    /// Wait for visualization to be ready
    @discardableResult
    func waitForVisualization(timeout: TimeInterval = 5) -> Bool {
        container.waitForExistence(timeout: timeout)
    }

    /// Wait for render to complete (via status bar update)
    @discardableResult
    func waitForRender(timeout: TimeInterval = 5) -> Bool {
        statusBar.waitForExistence(timeout: timeout)
    }

    /// Assert visualization is active
    func assertActive(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            isActive,
            "Visualization should be active",
            file: file,
            line: line
        )
    }

    /// Assert Metal view exists
    func assertMetalViewExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            metalView.exists,
            "Metal view should exist",
            file: file,
            line: line
        )
    }

    /// Assert status bar exists
    func assertStatusBarExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            statusBar.exists,
            "Status bar should exist",
            file: file,
            line: line
        )
    }

    /// Assert marginals panel exists
    func assertMarginalsPanelExists(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            marginalsPanel.exists,
            "Marginals panel should exist",
            file: file,
            line: line
        )
    }

    /// Assert points are visible (status bar shows point count)
    func assertPointsVisible(file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(
            statusText.contains("points"),
            "Status should show point count",
            file: file,
            line: line
        )
    }
}
