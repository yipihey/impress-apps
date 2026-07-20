//
//  IOSPublicationListPage.swift
//  imbib-iOSUITests
//
//  Page object for the publication list (IOSUnifiedPublicationListWrapper +
//  shared PublicationListView / MailStylePublicationRow) and the pushed
//  DetailView.
//

import XCTest

struct IOSPublicationListPage {

    let app: XCUIApplication

    /// The first seeded publication row, matched by a fragment of its title.
    /// (Rows render via the shared MailStylePublicationRow, which does not
    /// expose a per-row accessibility identifier, so we anchor on the title
    /// text, which is stable seed data.)
    var firstPublicationText: XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", IOSSeed.firstPublicationTitleFragment))
            .firstMatch
    }

    /// A detail-view marker: the Info tab button in the pushed DetailView.
    var detailInfoTab: XCUIElement {
        app.descendants(matching: .any)[IOSA11y.Detail.Tabs.info].firstMatch
    }

    @discardableResult
    func waitForFirstPublication(timeout: TimeInterval = 20) -> Bool {
        firstPublicationText.waitForExistence(timeout: timeout)
    }

    func openFirstPublication() {
        firstPublicationText.tap()
    }

    @discardableResult
    func waitForDetail(timeout: TimeInterval = 15) -> Bool {
        detailInfoTab.waitForExistence(timeout: timeout)
    }
}
