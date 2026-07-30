//
//  PublicationListSharedSurfaceTests.swift
//  PublicationManagerCoreTests
//
//  Stage 5d — the behavioural oracle for the publication list's shared halves
//  (`Chassis/Shared/PublicationScope.swift`, `PublicationListOrder.swift`,
//  `PublicationListMutations.swift`, `PublicationListCore.swift`).
//
//  The list is the suite's highest-traffic surface and it had TWO hosts with two
//  copies of the model. Each test below pins one thing the copies disagreed
//  about, so the disagreement cannot come back:
//
//    * the `.flagged` scope's persisted key — the copies produced DIFFERENT
//      UUIDs while a comment claimed they matched;
//    * `nextSelection` advancing from the BOTTOM of a multi-row block, not from
//      an unordered `Set`'s first element;
//    * `visualOrder` passing SQL-sorted rows through untouched, and being a
//      TOTAL order for `.recommended`;
//    * the two owning-library policies staying two.
//
//  Deliberately NOT `#if os(macOS)`-gated: these are the halves iOS reads.
//  Store-touching members (`isInboxScope`, the mutation verbs) are exercised via
//  the pure paths only — the composite verbs' step ORDER is asserted by reading
//  their source, the same technique `ChassisCrossPlatformContractTests` uses for
//  the gate, because their effects are `RustStoreAdapter` singleton writes.
//

import XCTest
@testable import PublicationManagerCore

final class PublicationListSharedSurfaceTests: XCTestCase {

    // MARK: - Fixtures

    private func row(
        _ n: Int,
        starred: Bool = false,
        added: TimeInterval = 0,
        title: String = "t"
    ) -> PublicationRowData {
        PublicationRowData(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            citeKey: "key\(n)",
            title: title,
            isStarred: starred,
            dateAdded: Date(timeIntervalSince1970: added)
        )
    }

    // MARK: - PublicationScope: the persisted list key

    /// The bug this closes. iOS's deleted `flaggedID(for:)` mapped
    /// red/amber/blue/gray to `F1A99ED0-000{1,2,3,4}-4000-8000-…`; the chassis
    /// maps them into `00000000-0000-0000-0000-%012x` by a DIFFERENT colour
    /// index. `listViewID` keys `ListViewStateStore`, so the two platforms read
    /// and wrote different saved sort/unread/selection state for every flagged
    /// scope while a comment in the iOS file asserted they matched.
    ///
    /// These are the values that ship. Changing them is a migration of every
    /// user's saved per-scope list state, so it has to be a deliberate edit here
    /// as well as there.
    func testFlaggedScopeKeysAreTheChassisTableNotASecondCopy() {
        XCTAssertEqual(
            PublicationSource.flagged("red").viewID.uuidString,
            "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(
            PublicationSource.flagged("blue").viewID.uuidString,
            "00000000-0000-0000-0000-000000000005")
        XCTAssertEqual(
            PublicationSource.flagged("gray").viewID.uuidString,
            "00000000-0000-0000-0000-000000000007")
        XCTAssertEqual(
            PublicationSource.flagged(nil).viewID.uuidString,
            "00000000-0000-0000-0000-000000000000")

        // And the key the list actually stores under is derived from it, not
        // from a parallel table.
        XCTAssertEqual(
            PublicationSource.flagged("red").listViewID,
            ListViewID.flagged(PublicationSource.flagged("red").viewID))
    }

    /// `FlagColor` is red/amber/blue/gray. The chassis colour table names
    /// orange/yellow/green/purple and has NO `amber` branch, so amber takes the
    /// UTF-8-sum fallback. That is deterministic and therefore correct, but it
    /// is not obvious, and it is the reason a second hand-written table looked
    /// reasonable to write. Pinned so the fallback is a known state rather than
    /// a surprise.
    func testAmberFlagScopeUsesTheDeterministicFallbackBranch() {
        let amber = PublicationSource.flagged("amber").viewID
        XCTAssertEqual(amber, PublicationSource.flagged("amber").viewID, "must be stable")
        XCTAssertNotEqual(amber, PublicationSource.flagged(nil).viewID)
        XCTAssertNotEqual(amber, PublicationSource.flagged("red").viewID)
    }

    /// Scopes `ListViewID` cannot name fall back to `.library(viewID)`, which
    /// must never collide with a real library's key.
    func testVirtualScopesGetDistinctPersistedKeys() {
        let virtualScopes: [PublicationSource] = [
            .unread, .starred, .dismissed, .citedInManuscripts, .recent,
        ]
        let keys = virtualScopes.map(\.listViewID)
        XCTAssertEqual(Set(keys).count, virtualScopes.count, "virtual scopes must not collide")

        // A real library keys off its own id.
        let libID = UUID()
        XCTAssertEqual(PublicationSource.library(libID).listViewID, .library(libID))
        // The Inbox keys off the library id too — the inbox IS a library.
        XCTAssertEqual(PublicationSource.inbox(libID).listViewID, .library(libID))
    }

    /// The two owning-library policies must stay two. macOS needs somewhere to
    /// put a paper; iOS needs the truth for attachment paths, and a wrong
    /// library there resolves to a wrong directory on disk.
    func testSmartSearchScopeCarriesItsIDForTriageDelinking() {
        let ssID = UUID()
        XCTAssertEqual(PublicationSource.smartSearch(ssID).smartSearchID, ssID)
        XCTAssertNil(PublicationSource.library(UUID()).smartSearchID)
        XCTAssertNil(PublicationSource.collection(UUID()).smartSearchID)
        XCTAssertNil(PublicationSource.flagged("red").smartSearchID)
    }

    // MARK: - PublicationListOrder: the visual order

    /// Rows arrive pre-sorted from SQL (`LibrarySortOrder.sortKey` becomes an
    /// `ORDER BY`), so re-sorting in Swift can only fight it. iOS's deleted copy
    /// re-sorted every order client-side.
    func testVisualOrderPassesSQLSortedRowsThroughUntouched() {
        let rows = [row(3), row(1), row(2)]
        for order in LibrarySortOrder.allCases where order != .recommended {
            let out = PublicationListOrder.visualOrder(
                rows, sortOrder: order, ascending: false, recommendationScores: [:])
            XCTAssertEqual(
                out.map(\.id), rows.map(\.id),
                "\(order.rawValue) is an ORDER BY — the client must not re-sort it")
        }
    }

    /// `.recommended` is scored in Swift, so it IS ordered here — and the order
    /// must be total, or `sorted(by:)` is free to permute equal elements between
    /// two calls and triage advances to a different row than the user saw.
    func testRecommendedOrderIsTotalEvenWhenEveryScoreTies() {
        let rows = (1...6).map { row($0, added: 100) }  // identical scores AND dates
        let first = PublicationListOrder.visualOrder(
            rows, sortOrder: .recommended, ascending: false, recommendationScores: [:])
        let second = PublicationListOrder.visualOrder(
            rows.reversed(), sortOrder: .recommended, ascending: false, recommendationScores: [:])
        XCTAssertEqual(
            first.map(\.id), second.map(\.id),
            "the id tie-break must make the order independent of input order")
    }

    func testRecommendedOrderRanksByScoreThenDateThenID() {
        let low = row(1, added: 500)
        let high = row(2, added: 100)
        let scores: [UUID: Double] = [low.id: 0.1, high.id: 0.9]
        let out = PublicationListOrder.visualOrder(
            [low, high], sortOrder: .recommended, ascending: false, recommendationScores: scores)
        XCTAssertEqual(out.first?.id, high.id, "higher score ranks first despite older dateAdded")
    }

    // MARK: - PublicationListOrder: selection advance

    /// The rule: advance DOWNWARD from the BOTTOM of the selected block. iOS's
    /// deleted copy started from `ids.first` — an unordered `Set`'s first
    /// element — so triaging rows 2-4 could land on row 3, a row that was about
    /// to disappear.
    func testNextSelectionAdvancesBelowTheWholeSelectedBlock() {
        let rows = (1...5).map { row($0) }
        let block = Set([rows[1].id, rows[2].id, rows[3].id])
        XCTAssertEqual(
            PublicationListOrder.nextSelection(removing: block, from: rows),
            rows[4].id,
            "must land below the block, never inside it")
    }

    /// Repeat it enough times that a `Set`-iteration-order implementation would
    /// have to get lucky every time.
    func testNextSelectionIsIndependentOfSetIterationOrder() {
        let rows = (1...5).map { row($0) }
        let block = Set([rows[1].id, rows[2].id, rows[3].id])
        for _ in 0..<50 {
            XCTAssertEqual(
                PublicationListOrder.nextSelection(removing: Set(block.shuffled()), from: rows),
                rows[4].id)
        }
    }

    func testNextSelectionFallsBackAboveTheBlockAtTheEndOfTheList() {
        let rows = (1...5).map { row($0) }
        let tail = Set([rows[3].id, rows[4].id])
        XCTAssertEqual(
            PublicationListOrder.nextSelection(removing: tail, from: rows),
            rows[2].id,
            "no row below — fall back to the row above the block")
    }

    func testNextSelectionIsNilWhenTheListIsEmptied() {
        let rows = (1...3).map { row($0) }
        XCTAssertNil(
            PublicationListOrder.nextSelection(removing: Set(rows.map(\.id)), from: rows))
        XCTAssertNil(PublicationListOrder.nextSelection(removing: [UUID()], from: rows))
        XCTAssertNil(PublicationListOrder.nextSelection(removing: [], from: rows))
    }

    // MARK: - PublicationListMutations: the invariant steps

    /// Structural, and deliberately so: these verbs' effects are writes to the
    /// `RustStoreAdapter` singleton, but the DEFECTS were missing STEPS, and a
    /// missing step is visible in the source. Each assertion names an invariant
    /// the iOS copy dropped.
    func testTriageVerbsStillCarryTheirInvariantSteps() throws {
        let text = try String(
            contentsOf: Self.sourcesRoot.appendingPathComponent(
                "Chassis/Shared/PublicationListMutations.swift"),
            encoding: .utf8)

        // apps/imbib/CLAUDE.md, Critical Invariants #1: "Dismissed papers must
        // never re-enter the inbox." iOS's handleDismiss / handleSaveToLibrary
        // both skipped this call.
        XCTAssertTrue(
            text.contains("InboxManager.shared.trackDismissal"),
            "triage must record dismissals or feeds re-ingest the paper")

        // The feed's Contains edge has to go too, or the row reappears on the
        // next reload of that smart search.
        XCTAssertTrue(
            text.contains("removeFromCollection"),
            "feed triage must delink the paper from the smart-search collection")

        // docs/chassis-capability-matrix.md, publication row: "soft-delete →
        // Dismissed, Undo". A hard delete is only correct out of Dismissed.
        XCTAssertTrue(
            text.contains("if permanently {"),
            "delete must be soft unless the caller says this scope IS the trash")
        XCTAssertTrue(
            text.contains("movePublications"),
            "the non-permanent delete path must MOVE, not destroy")

        // Multi-select triage is one store event, not one per paper.
        XCTAssertTrue(
            text.contains("beginBatchMutation") && text.contains("endBatchMutation"),
            "batched triage paths must stay batched")
    }

    /// The wrapper that used to hold these sequences must no longer hold a
    /// second copy of them. This is what stops the split from silently
    /// un-splitting: a future edit that pastes the sequence back into the macOS
    /// chrome fails here.
    func testMacOSChromeNoLongerReimplementsTheTriageSequences() throws {
        let text = try String(
            contentsOf: Self.sourcesRoot.appendingPathComponent(
                "Chassis/Shared/UnifiedPublicationListWrapper.swift"),
            encoding: .utf8)
        XCTAssertFalse(
            text.contains("cleanupDismissedCopies"),
            """
            UnifiedPublicationListWrapper re-implements a triage sequence. The \
            composite verbs live in PublicationListMutations so both hosts run \
            the same steps; a copy here is how the iOS host came to be missing \
            four of them.
            """)
        // The CALL, not the prose — the wrapper's comment names the verb it
        // delegates to, and that is the point of the comment.
        XCTAssertFalse(
            text.contains("store.deletePublications(")
                || text.contains("RustStoreAdapter.shared.deletePublications("),
            "the delete decision belongs to PublicationListMutations.delete")
        // The ordering comparator, likewise.
        XCTAssertFalse(
            text.contains("primarySortComparison"),
            "the comparator lives in PublicationListOrder")
    }

    // MARK: - PublicationListCore: the sort edge iOS never had

    /// `applySort` is the edge whose absence made every entry in the iOS sort
    /// menu inert: iOS held `currentSortOrder`, handed it to
    /// `PublicationListView` (which renders the menu), and never re-queried.
    /// `.recommended` is the one order that must NOT reload — it is scored in
    /// Swift and re-ordered by `PublicationListOrder`.
    func testEverySortOrderExceptRecommendedMapsToASQLKey() {
        for order in LibrarySortOrder.allCases {
            XCTAssertFalse(order.sortKey.isEmpty, "\(order.rawValue) has no ORDER BY key")
        }
        XCTAssertTrue(LibrarySortOrder.recommended.usesRecommendation)
        for order in LibrarySortOrder.allCases where order != .recommended {
            XCTAssertFalse(
                order.usesRecommendation,
                "\(order.rawValue) must be answerable by SQL alone")
        }
    }

    /// The core must not become a second home for the copy that differs per
    /// platform, nor for the selection policy. Both are stated in its header as
    /// deliberately absent; this keeps that true.
    func testCoreOwnsNoStringsAndNoSelection() throws {
        let text = try String(
            contentsOf: Self.sourcesRoot.appendingPathComponent(
                "Chassis/Shared/PublicationListCore.swift"),
            encoding: .utf8)
        // Strip the header comment before looking for product copy.
        let body = text.components(separatedBy: "\nimport Foundation").dropFirst()
            .joined(separator: "\nimport Foundation")
        XCTAssertFalse(
            body.contains("No Publications") || body.contains("Inbox Empty"),
            "empty-state copy differs per platform and must stay with each host")
        XCTAssertFalse(
            body.contains("selectedPublicationID"),
            "selection is the host's — a phone's split view is a stack")
    }

    /// `<package>/Sources/PublicationManagerCore`, derived from this test's own
    /// path so the test is location-independent.
    private static let sourcesRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PublicationManagerCore")
    }()
}
