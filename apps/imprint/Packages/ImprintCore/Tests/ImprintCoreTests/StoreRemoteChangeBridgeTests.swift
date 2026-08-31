//
//  StoreRemoteChangeBridgeTests.swift
//  ImprintCoreTests
//
//  The refresh trigger for out-of-process store changes (definition of done
//  for the imprint staleness fix). These are END-TO-END through the real
//  Darwin notify center: `ImpressNotification.post` and the bridge's
//  observation run in the same process, and Darwin notifications are
//  delivered in-process too — so the tests exercise the exact registration,
//  delivery, hop-to-main and coalescing path the apps run, not a mock of it.
//
//  Posts carry no resourceIDs on purpose: `ImpressNotification.post` only
//  touches the shared container when IDs are attached, so these tests write
//  nothing outside the process.
//
//  Coverage:
//  - a `syncApplied` Darwin post from imbib invokes the callback (the
//    reported bug: CloudSyncEngine pull-applies were invisible to imprint)
//  - a burst of posts coalesces into ONE callback whose summary names them
//  - the observation table never includes imprint itself (self-echo guard)
//    and never includes `libraryChanged` (paper-import churn guard)
//  - the defaults kill switch makes start() a no-op (gated + revertible)
//  - stop() really stops delivery
//  - summarize() folds duplicate labels
//

import XCTest
@testable import ImprintCore
import ImpressKit

final class StoreRemoteChangeBridgeTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(
            forKey: StoreRemoteChangeBridge.disabledDefaultsKey)
        super.tearDown()
    }

    /// The reported staleness scenario: imbib's CloudSyncEngine applies a
    /// CloudKit pull and posts `syncApplied` — the bridge must fire.
    @MainActor
    func testSyncAppliedPostFromImbibFiresCallback() async {
        let bridge = StoreRemoteChangeBridge()
        defer { bridge.stop() }
        let fired = expectation(description: "callback fired")
        var receivedSummary: String?
        bridge.start(debounce: .milliseconds(100)) { summary in
            // First callback only: a machine-global Darwin bus means foreign
            // posts can open further windows, and a second fulfill would trip
            // the expectation's over-fulfillment assertion.
            guard receivedSummary == nil else { return }
            receivedSummary = summary
            fired.fulfill()
        }
        XCTAssertTrue(bridge.isRunning)

        ImpressNotification.post(ImpressNotification.syncApplied, from: .imbib)

        await fulfillment(of: [fired], timeout: 5)
        // CONTAINS, not equals, and ≥1, not ==1: the Darwin notify center is
        // machine-global, so sibling test processes (`swift test --parallel`
        // runs cases in parallel workers) — or a real imbib — may post the
        // same events concurrently. Our own post is guaranteed in there.
        XCTAssertGreaterThanOrEqual(bridge.firedCount, 1)
        XCTAssertTrue(
            receivedSummary?.contains("sync-applied(imbib)") == true,
            String(describing: receivedSummary))
    }

    /// A burst — several events, several sources, one debounce window — must
    /// cost ONE refresh, and the summary must name everything coalesced.
    @MainActor
    func testBurstCoalescesIntoSingleCallback() async throws {
        let bridge = StoreRemoteChangeBridge()
        defer { bridge.stop() }
        let fired = expectation(description: "coalesced callback")
        var receivedSummary = ""
        bridge.start(debounce: .milliseconds(400)) { summary in
            guard receivedSummary.isEmpty else { return }  // first window only
            receivedSummary = summary
            fired.fulfill()
        }

        ImpressNotification.post(ImpressNotification.syncApplied, from: .imbib)
        ImpressNotification.post(ImpressNotification.syncApplied, from: .imbib)
        ImpressNotification.post(ImpressNotification.manuscriptStatusChanged, from: .impel)

        await fulfillment(of: [fired], timeout: 5)
        // Coalescing is proven by the FIRST callback's summary alone: the two
        // syncApplied posts fold into one "×N" label and the impel event rides
        // the same window. An exact firedCount == 1 would be racy — the Darwin
        // bus is machine-global, and a sibling test process posting after our
        // window fires would legitimately open a second one.
        XCTAssertTrue(receivedSummary.contains("sync-applied(imbib) ×"), receivedSummary)
        XCTAssertTrue(
            receivedSummary.contains("manuscript-status-changed(impel)"), receivedSummary)
    }

    /// The observation table is the contract: sync + journal manuscript
    /// events, never imprint's own posts (a local mutation already bumped
    /// `dataVersion`; observing ourselves would double-refresh every edit)
    /// and never `libraryChanged` (imbib import/enrichment bursts would churn
    /// the shell without a manuscript pixel changing).
    @MainActor
    func testObservationTableExcludesSelfAndLibraryChanged() {
        let table = StoreRemoteChangeBridge.observedEvents
        XCTAssertTrue(table.contains { $0.event == ImpressNotification.syncApplied
            && $0.sources.contains(.imbib) })
        XCTAssertTrue(table.contains { $0.event == ImpressNotification.manuscriptStatusChanged })
        XCTAssertTrue(table.contains { $0.event == ImpressNotification.manuscriptSnapshotCreated })
        for mapping in table {
            XCTAssertFalse(mapping.sources.contains(.imprint),
                "bridge must never observe imprint's own posts (\(mapping.event))")
            XCTAssertNotEqual(mapping.event, ImpressNotification.libraryChanged)
        }
    }

    /// The kill switch (sidebar-fragility rule: gated, revertible without a
    /// rebuild): with the defaults key set, start() must be a no-op.
    ///
    /// An ISOLATED defaults suite, never `.standard`: parallel test workers
    /// share the persisted standard domain, so writing the key there disables
    /// the bridge in concurrently running sibling tests (observed: the burst
    /// test's bridge silently refused to start).
    @MainActor
    func testKillSwitchDisablesStart() async throws {
        let suiteName = "StoreRemoteChangeBridgeTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(true, forKey: StoreRemoteChangeBridge.disabledDefaultsKey)
        let bridge = StoreRemoteChangeBridge(defaults: suite)
        defer { bridge.stop() }
        bridge.start(debounce: .milliseconds(50)) { _ in
            XCTFail("disabled bridge must not fire")
        }
        XCTAssertFalse(bridge.isRunning)

        ImpressNotification.post(ImpressNotification.syncApplied, from: .imbib)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(bridge.firedCount, 0)
    }

    /// stop() must invalidate the Darwin observations, not just drop the
    /// callback — a stopped bridge receiving posts is a leak of exactly the
    /// kind DarwinObservation.invalidate() exists to prevent.
    @MainActor
    func testStopEndsDelivery() async throws {
        let bridge = StoreRemoteChangeBridge()
        bridge.start(debounce: .milliseconds(50)) { _ in
            XCTFail("stopped bridge must not fire")
        }
        bridge.stop()
        XCTAssertFalse(bridge.isRunning)

        ImpressNotification.post(ImpressNotification.syncApplied, from: .imbib)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(bridge.firedCount, 0)
    }

    @MainActor
    func testSummarizeFoldsDuplicates() {
        XCTAssertEqual(
            StoreRemoteChangeBridge.summarize(["a", "a", "b", "a"]),
            "a ×3, b")
        XCTAssertEqual(StoreRemoteChangeBridge.summarize(["only"]), "only")
        XCTAssertEqual(StoreRemoteChangeBridge.summarize([]), "")
    }
}
