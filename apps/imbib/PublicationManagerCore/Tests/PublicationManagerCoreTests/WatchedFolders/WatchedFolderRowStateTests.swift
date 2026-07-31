//
//  WatchedFolderRowStateTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D2/D6 — the feed-shaped sidebar row, and the badge rule that keeps
//  it honest.
//
//  The badge assertions ARE the risk-register mitigation. "The folder row must
//  never render an unindexed volume as '0 files'" is enforced in exactly one
//  place (`WatchedFolderRowState.badgeCount`) so that no call site gets to
//  decide it, and this suite is what pins it there.
//

import XCTest

@testable import PublicationManagerCore

final class WatchedFolderRowStateTests: XCTestCase {

    private func row(
        state: WatchedFolderState,
        discovered: Int = 0,
        new: Int = 0,
        partial: Bool = false,
        enabled: Bool = true
    ) -> WatchedFolderRowState {
        WatchedFolderRowState(
            id: WatchedFolderID(),
            displayName: "Papers",
            path: "/tmp/Papers",
            state: state,
            discoveredCount: discovered,
            newSinceLastVisit: new,
            lastScanDate: nil,
            isRefreshing: false,
            isEnabled: enabled,
            countIsPartial: partial)
    }

    // MARK: - The badge rule

    func testADegradedFolderShowsNoBadgeEvenWhenItHasACount() {
        // The bug this exists to prevent, in its general form: a number from a
        // folder that cannot see its own contents is a floor, and a badge is a
        // claim that it is a total.
        XCTAssertNil(row(state: .scanOnDemand, discovered: 12).badgeCount)
        XCTAssertNil(row(state: .inaccessible(bookmarkStale: true), discovered: 12).badgeCount)
    }

    func testATruncatedWalkShowsNoBadge() {
        XCTAssertNil(row(state: .fallback, discovered: 20_000, partial: true).badgeCount)
    }

    func testLiveAndFallbackFoldersDoShowTheirCounts() {
        XCTAssertEqual(row(state: .live, discovered: 12).badgeCount, 12)
        XCTAssertEqual(row(state: .fallback, discovered: 3).badgeCount, 3)
    }

    func testTheNewSinceLastVisitCountWinsWhenThereIsOne() {
        // Feed semantics: the badge is "what changed", falling back to "how
        // many there are" — imbib's inbox feeds behave the same way.
        XCTAssertEqual(row(state: .live, discovered: 40, new: 2).badgeCount, 2)
    }

    func testATrustworthyZeroShowsNoBadgeLikeEveryOtherFeedRow() {
        XCTAssertNil(
            row(state: .live, discovered: 0).badgeCount,
            "an empty inbox feed shows no \"0\" either; the consistency is what makes "
                + "a DEGRADED row's missing badge readable as \"see the status\"")
    }

    // MARK: - The status line

    func testTheStatusLineIsNeverEmptyIncludingWhenHealthy() {
        for state in [
            WatchedFolderState.live, .fallback, .scanOnDemand,
            .inaccessible(bookmarkStale: true),
        ] {
            XCTAssertFalse(
                row(state: state).statusLine.isEmpty,
                "a field that is blank when healthy trains the eye to ignore it")
        }
    }

    func testTheStatusLineRendersTheStateLabelVerbatim() {
        XCTAssertEqual(row(state: .fallback).statusLine, WatchedFolderState.fallback.label)
        XCTAssertEqual(
            row(state: .inaccessible(bookmarkStale: true)).statusLine,
            "Permission expired")
    }

    func testATruncatedCountSaysSoInTheStatusLine() {
        let line = row(state: .fallback, discovered: 500, partial: true).statusLine
        XCTAssertTrue(line.contains("first 500"))
    }

    func testADisabledFolderReadsAsPausedNotAsBroken() {
        let paused = row(state: .live, discovered: 5, enabled: false)
        XCTAssertEqual(paused.statusLine, "Paused")
        XCTAssertFalse(paused.offersRefresh)
    }

    // MARK: - Affordances

    func testRefreshIsOfferedExactlyWhereItCanDoSomething() {
        XCTAssertTrue(row(state: .live).offersRefresh)
        XCTAssertTrue(row(state: .fallback).offersRefresh)
        XCTAssertTrue(row(state: .scanOnDemand).offersRefresh)
        XCTAssertFalse(row(state: .inaccessible(bookmarkStale: false)).offersRefresh)
        XCTAssertTrue(row(state: .inaccessible(bookmarkStale: false)).offersReauthorization)
    }

    // MARK: - The route vocabulary

    func testRouteKeysRoundTrip() {
        let id = WatchedFolderID()
        let key = WatchedFolderRoute.folder(id).key
        XCTAssertEqual(WatchedFolderRoute(key: key), .folder(id))
        XCTAssertEqual(
            WatchedFolderRoute(key: WatchedFolderRoute.allFolders.key), .allFolders)
    }

    func testRouteKeysAreNamespacedSoAHostCanRecogniseThemAmongItsOwn() {
        XCTAssertTrue(
            WatchedFolderRoute.allFolders.key.hasPrefix(WatchedFolderRoute.keyPrefix))
        XCTAssertNil(WatchedFolderRoute(key: "feed.1234"))
        XCTAssertNil(WatchedFolderRoute(key: "watched-folder.not-a-uuid"))
    }

    func testTheScopeIsAHostScopeSoNoChassisEnumHasToGrowACase() {
        let id = WatchedFolderID()
        let scope = WatchedFolderRoute.folder(id).scope(kind: .publication)
        guard case .host(let kind, let key) = scope else {
            return XCTFail("watched folders must ride the existing .host case")
        }
        XCTAssertEqual(kind, .publication)
        XCTAssertEqual(key, WatchedFolderRoute.folder(id).key)
        XCTAssertEqual(scope.hostKey, key)
        XCTAssertEqual(scope.scopeKey, "host.publication.\(key)")
    }

    func testTheScopeIsStableSoSelectionSurvivesARebuild() {
        let id = WatchedFolderID()
        let first = WatchedFolderRoute.folder(id).scope(kind: .publication).stableViewID
        let second = WatchedFolderRoute.folder(id).scope(kind: .publication).stableViewID
        XCTAssertEqual(first, second)
    }

    // MARK: - The sidebar node

    func testAHealthyRowRendersAsAPlainFeedShapedNode() {
        let row = row(state: .live, discovered: 4)
        let node = row.sidebarNode(kind: .publication)
        XCTAssertEqual(node.title, "Papers")
        XCTAssertEqual(node.count, 4)
        XCTAssertFalse(node.isFolder, "a watched folder is a feed, not a collection")
        XCTAssertTrue(node.children.isEmpty)
    }

    func testADegradedRowCarriesItsStateIntoTheNodeTitle() {
        // `RecordSidebarNode` has no subtitle, and D6 requires the state to be
        // VISIBLE. A host with a richer row opts out with
        // `includesStateInTitle: false` and renders `statusLine` properly.
        let node = row(state: .fallback, discovered: 9).sidebarNode(kind: .publication)
        XCTAssertTrue(node.title.contains("Papers"))
        XCTAssertTrue(node.title.contains(WatchedFolderState.fallback.label))

        let plain = row(state: .fallback, discovered: 9)
            .sidebarNode(kind: .publication, includesStateInTitle: false)
        XCTAssertEqual(plain.title, "Papers")
    }

    func testAnInaccessibleRowRendersWithNoBadgeAndItsOwnGlyph() {
        let node = row(state: .inaccessible(bookmarkStale: true), discovered: 40)
            .sidebarNode(kind: .publication)
        XCTAssertNil(node.count)
        XCTAssertEqual(node.systemImage, "folder.badge.minus")
    }

    func testTheParentNodeSuppressesItsTotalIfAnyChildIsUntrustworthy() {
        let healthy = row(state: .live, discovered: 3)
        let blind = row(state: .scanOnDemand, discovered: 100)

        XCTAssertEqual([healthy].sidebarParentNode(kind: .publication).count, 3)
        XCTAssertNil(
            [healthy, blind].sidebarParentNode(kind: .publication).count,
            "a total that silently omits an unindexed folder is the same lie one "
                + "level up")
        XCTAssertEqual([healthy, blind].sidebarParentNode(kind: .publication).children.count, 2)
        XCTAssertEqual([healthy, blind].degraded.count, 1)
    }
}
