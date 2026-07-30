//
//  ImpressRealStoreUITests.swift
//  impress-iOSUITests
//
//  The one suite that launches with NO arguments: the app opens the real
//  app-group `impress.sqlite` — on a developer device, the same container
//  imbib-iOS and imprint-iOS write. This is the "does impress see the whole
//  store?" check: the sidebar must render the presented sections over live
//  data (whatever the device actually holds, including zero rows), never
//  crash on a real container, and the screenshot attachment records the
//  actual counts for a human to read.
//
//  It asserts STRUCTURE, not contents: a fresh device legitimately has no
//  mail/figures/tasks. Contents are the screenshot's job.
//

import XCTest

final class ImpressRealStoreUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_realStore_sidebarRendersThePresentedSectionsOverLiveData() throws {
        let app = XCUIApplication()
        // Deliberately NO launch arguments: real store, real container.
        app.launch()

        let sidebar = app.otherElements[ImpressA11y.mailSection]
            .firstMatch
        let mailHeader = app.staticTexts["Mail"].firstMatch
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: 10) || mailHeader.waitForExistence(timeout: 10),
            "the sidebar must render its Mail section over the real store")

        for header in ["Figures", "Agents"] {
            XCTAssertTrue(
                app.staticTexts[header].firstMatch.waitForExistence(timeout: 5),
                "\(header) section header must render over the real store")
        }

        // Declared-absent sections stay absent on the real store too — the
        // presentableKinds contract is data-independent.
        for absent in ImpressA11y.declaredAbsentSections {
            XCTAssertFalse(
                app.otherElements[absent].exists || app.buttons[absent].exists,
                "\(absent) is declared absent and must not appear over a real store")
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "real-store-sidebar"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
