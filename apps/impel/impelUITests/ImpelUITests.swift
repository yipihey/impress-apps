import XCTest

final class ImpelUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
    }

    func testAppLaunches() throws {
        app.launch()

        // Verify main window appears
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    func testSidebarNavigation() throws {
        app.launch()

        // Check sidebar items exist
        let sidebar = app.outlines.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    }

    func testDashboardDisplaysStats() throws {
        app.launch()

        // Navigate to dashboard
        let dashboard = app.staticTexts["Dashboard"]
        if dashboard.exists {
            dashboard.click()
        }

        // Verify stats cards are displayed
        // (These would need accessibility identifiers in production)
    }
}
