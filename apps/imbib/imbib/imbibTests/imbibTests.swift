//
//  imbibTests.swift
//  imbibTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
import PublicationManagerCore
@testable import imbib

final class imbibTests: XCTestCase {

    func testAppLaunches() throws {
        // Placeholder test - app launches successfully
        XCTAssertTrue(true)
    }

    func testSearchRouteIdentityIncludesModeAndEditedFeed() {
        let libraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let feedID = UUID(uuidString: "00000000-0000-0000-0000-000000000456")!

        let inboxRoute = ImbibContentRoute.searchForm(ImbibSearchFormRoute(
            formType: .adsModern,
            mode: .inboxFeed
        ))
        let libraryRoute = ImbibContentRoute.searchForm(ImbibSearchFormRoute(
            formType: .adsModern,
            mode: .libraryFeed(libraryID, "Reading")
        ))
        let editRoute = ImbibContentRoute.searchForm(ImbibSearchFormRoute(
            formType: .adsModern,
            mode: .libraryFeed(libraryID, "Reading"),
            editingFeedID: feedID
        ))

        XCTAssertNotEqual(inboxRoute.stableID, libraryRoute.stableID)
        XCTAssertNotEqual(libraryRoute.stableID, editRoute.stableID)
        XCTAssertTrue(editRoute.stableID.contains(feedID.uuidString))
    }

    func testPublicationRouteIdentityUsesPublicationSourceViewID() {
        let libraryID = UUID(uuidString: "00000000-0000-0000-0000-000000000789")!
        let source = PublicationSource.library(libraryID)
        let route = ImbibContentRoute.publicationList(source)

        XCTAssertEqual(route.stableID, "source-\(source.viewID)")
        XCTAssertEqual(route.publicationSource, source)
        XCTAssertFalse(route.isSearchForm)
        XCTAssertFalse(route.isArtifactRoute)
    }

    func testJournalTabsMapToJournalRoutes() {
        XCTAssertEqual(ImbibTab.journalSubmissions.journalRoute, .submissions)
        XCTAssertEqual(ImbibTab.journalAll.journalRoute, .all)
        XCTAssertEqual(ImbibTab.journalByStatus(.draft).journalRoute, .status(.draft))
        XCTAssertEqual(ImbibTab.manuscript("paper-1").journalRoute, .manuscript("paper-1"))
        XCTAssertNil(ImbibTab.inbox.journalRoute)
    }
}
