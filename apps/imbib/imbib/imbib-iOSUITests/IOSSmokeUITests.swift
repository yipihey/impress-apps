//
//  IOSSmokeUITests.swift
//  imbib-iOSUITests
//
//  A small, real XCUITest guard for the revived imbib-iOS views. These run
//  against a seeded in-memory store (launch args `--ui-testing
//  --uitesting-seed`, see imbibApp.seedUITestDataIfNeeded) so they are fully
//  deterministic and offline. Each test exercises a distinct revived surface:
//
//   1. launch + sidebar render (IOSContentView + IOSSidebarView)
//   2. settings navigation (IOSSettingsView sheet)
//   3. list -> detail navigation (IOSUnifiedPublicationListWrapper -> DetailView)
//

import XCTest

final class IOSSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The app launches into the split view and the sidebar (with its
    /// Settings toolbar button) renders. Guards IOSContentView + IOSSidebarView.
    func test_appLaunches_showsSidebar() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)

        XCTAssertTrue(
            sidebar.waitUntilLoaded(),
            "Sidebar (settings button) should appear after launch"
        )
    }

    /// Tapping the sidebar gear opens the Settings sheet (IOSSettingsView),
    /// which can then be dismissed. Guards the revived settings surface + sheet
    /// navigation.
    func test_openSettings_showsSettingsSheet() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let settings = IOSSettingsPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        sidebar.openSettings()

        XCTAssertTrue(
            settings.waitForSheet(),
            "Settings sheet should present with the API Keys row"
        )

        settings.dismiss()
    }

    /// Selecting the seeded library shows its publications; tapping the first
    /// publication pushes the DetailView with its Info tab. Guards the
    /// list + detail cluster revival (IOSUnifiedPublicationListWrapper ->
    /// DetailView / IOSInfoTab).
    func test_selectPublication_showsDetail() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let list = IOSPublicationListPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        sidebar.openSeededLibrary()

        XCTAssertTrue(
            list.waitForFirstPublication(),
            "Seeded publication row should appear in the list"
        )
        list.openFirstPublication()

        XCTAssertTrue(
            list.waitForDetail(),
            "Detail view (Info tab) should appear after selecting a publication"
        )
    }
}
