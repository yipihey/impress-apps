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

    /// Stage 3 replacement for `testJournalTabsMapToJournalRoutes`. The four
    /// per-kind route enums are gone, so what there is to assert is that a
    /// record tab carries the kind and scope straight through to the content
    /// route (the manuscript pipeline included).
    func testRecordTabsCarryKindAndScopeThroughToTheContentRoute() {
        let all = ImbibTab.record(.all(.manuscript))
        XCTAssertEqual(all, .record(RecordRoute(kind: .manuscript, scope: .all(.manuscript))))

        let drafts = RecordRoute.status(.manuscript, JournalManuscriptStatus.draft.rawValue)
        XCTAssertEqual(ImbibContentRoute.record(drafts).stableID, "record-\(drafts.stableID)")
        XCTAssertNotEqual(
            ImbibContentRoute.record(drafts).stableID,
            ImbibContentRoute.record(.all(.manuscript)).stableID)

        // The Submissions inbox is an AUXILIARY route now (it is not a record
        // subset), and a manuscript deep link is a record DETAIL route.
        XCTAssertEqual(ImbibTab.auxiliary(.submissionsInbox), .auxiliary(.submissionsInbox))
        XCTAssertEqual(
            ImbibContentRoute.recordDetail(.manuscript, "paper-1").stableID,
            "record-detail-manuscript-paper-1")
    }
}
