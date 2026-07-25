//
//  SyncAvailabilityAndLeaseTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0007 Phase 3 (Phase D): the safety gate and the single-writer lease.
//
//  The availability tests are the regression net for the crash class fixed in
//  5edde41 — an unentitled `CKContainer(identifier:)` traps the process. These
//  assert that on a build with no sync container (which is every build until
//  the activation step in docs/sync-phase-d-activation.md), the gate refuses
//  BEFORE any CloudKit type could be constructed.
//

import XCTest
import ImpressKit
@testable import PublicationManagerCore

final class SyncAvailabilityTests: XCTestCase {

    // MARK: - The gate

    /// In an xctest worker the very first check wins, before the flag, the
    /// entitlement probe, or anything CloudKit-shaped.
    func testAvailabilityShortCircuitsInsideTestProcess() async {
        XCTAssertTrue(ImpressRuntime.isUnitTestProcess, "precondition: we ARE a test process")
        let availability = await CloudSyncAvailability.evaluatePreLease()
        XCTAssertEqual(availability, .unitTestProcess)
        XCTAssertEqual(availability.reasonCode, "unit_test_process")
        XCTAssertFalse(availability.isAvailable)
    }

    /// The TEST PROCESS is never entitled for the sync container, so tests
    /// can never reach live CloudKit no matter what the app bundle carries.
    ///
    /// This deliberately survives Phase D activation (entitlements added to
    /// the app targets 2026-07-25): `swift test` runs an unsigned xctest
    /// binary, so `SecTaskCopyValueForEntitlement` finds nothing here even
    /// though the shipping app now has the container. Keeping the assertion
    /// pins that isolation — if it ever flips, a test run could mutate the
    /// user's real iCloud data.
    func testTestProcessIsNeverEntitledForTheSyncContainer() {
        XCTAssertFalse(
            CloudSyncAvailability.isEntitledForContainer,
            "an unsigned test binary must never present the sync entitlement")
    }

    /// The container is never constructed while unentitled — the guarded
    /// factory returns nil instead of trapping.
    func testContainerFactoryRefusesWhenNotEntitled() {
        XCTAssertNil(
            CloudSyncAvailability.makeContainerIfEntitled(),
            "must never construct CKContainer without the entitlement (see 5edde41)")
    }

    /// Every failure mode carries a distinct, non-empty explanation for
    /// Settings, and a stable machine-readable code for the automation API.
    func testEveryReasonHasDistinctCodeAndExplanation() {
        let cases: [SyncAvailability] = [
            .available,
            .unitTestProcess,
            .disabledByUser,
            .notEntitled,
            .accountUnavailable(.noAccount),
            .accountUnavailable(.restricted),
            .leaseHeldByOther("imprint"),
            .accountCheckFailed("offline")
        ]
        for availability in cases {
            XCTAssertFalse(availability.explanation.isEmpty)
            XCTAssertFalse(availability.reasonCode.isEmpty)
        }
        XCTAssertNotEqual(
            SyncAvailability.disabledByUser.reasonCode,
            SyncAvailability.notEntitled.reasonCode)
        XCTAssertTrue(
            SyncAvailability.notEntitled.explanation.contains(SyncSettings.containerIdentifier),
            "the not-entitled message should name the missing container")
        XCTAssertTrue(SyncAvailability.available.isAvailable)
    }

    // MARK: - The flag

    /// The master switch must default OFF. A missing key reads false, which is
    /// exactly the guarantee a fresh install needs.
    func testSyncIsDisabledByDefault() {
        SharedDefaults.suite.removeObject(forKey: "sync.cloudkit.enabled")
        XCTAssertFalse(SyncSettings.isEnabled, "CloudKit sync must default to OFF")
    }

    func testFlagAndDiagnosticsRoundTrip() {
        defer {
            SyncSettings.isEnabled = false
            SyncSettings.resetDiagnostics()
        }
        SyncSettings.isEnabled = true
        XCTAssertTrue(SyncSettings.isEnabled)

        SyncSettings.recordError("boom")
        XCTAssertEqual(SyncSettings.lastError, "boom")
        XCTAssertNotNil(SyncSettings.lastErrorAt)

        SyncSettings.clearError()
        XCTAssertNil(SyncSettings.lastError)

        let now = Date()
        SyncSettings.lastPushAt = now
        SyncSettings.lastPullAt = now
        XCTAssertNotNil(SyncSettings.lastPushAt)
        SyncSettings.resetDiagnostics()
        XCTAssertNil(SyncSettings.lastPushAt)
        XCTAssertNil(SyncSettings.lastPullAt)
    }

    /// Even with the flag ON, a test process still refuses — the ordering of
    /// the chain puts the test short-circuit first for a reason.
    func testFlagOnStillRefusesInTestProcess() async {
        defer { SyncSettings.isEnabled = false }
        SyncSettings.isEnabled = true
        let availability = await CloudSyncAvailability.evaluatePreLease()
        XCTAssertEqual(availability, .unitTestProcess)
    }

    // MARK: - The engine never starts while the gate refuses

    /// The end-to-end guarantee: calling `start()` directly — the only path
    /// that constructs `CKSyncEngine` — refuses and leaves the engine down.
    /// If this ever returns `.available` in a test process, a `CKContainer`
    /// was constructed in an unentitled process and the 5edde41 crash is back.
    func testEngineRefusesToStartAndConstructsNothing() async {
        let availability = await CloudSyncEngine.shared.start()

        XCTAssertNotEqual(availability, .available, "the engine must refuse to start here")
        let running = await CloudSyncEngine.shared.running
        XCTAssertFalse(running, "no CKSyncEngine may exist after a refused start")
    }

    /// The launcher is inert in test processes: it must not even schedule its
    /// delayed task, let alone touch the store or CloudKit.
    func testLauncherIsInertInTestProcess() async {
        CloudSyncEngineLauncher.startAfterGrace(delay: 0)
        try? await Task.sleep(for: .milliseconds(50))

        let running = await CloudSyncEngine.shared.running
        XCTAssertFalse(running, "the launcher must never start an engine under test")
    }

    /// The grace delay protects the documented startup render-loop invariant
    /// (no store events in the first ~90s). Pin it so a future edit can't
    /// quietly shorten it.
    func testLauncherGraceDelayRespectsStartupInvariant() {
        XCTAssertGreaterThanOrEqual(
            CloudSyncEngineLauncher.startupDelay, 120,
            "sync must not emit store events inside the 90s startup grace window")
    }
}

final class SyncLeaseTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLease(ttl: TimeInterval = 60) -> SyncLease {
        SyncLease(app: .imbib, ttl: ttl, renewInterval: 20, directory: directory)
    }

    func testAcquireThenRenewKeepsTheLease() async {
        let lease = makeLease()
        let acquired = await lease.tryAcquire()
        XCTAssertTrue(acquired)
        var held = await lease.isHeld
        XCTAssertTrue(held)

        let info = await lease.currentLease()
        XCTAssertEqual(info?.app, "imbib")
        XCTAssertEqual(info?.pid, ProcessInfo.processInfo.processIdentifier)

        let renewedOK = await lease.renew()
        XCTAssertTrue(renewedOK)
        held = await lease.isHeld
        XCTAssertTrue(held)

        // Renewal keeps the original acquisition time (a continuous hold).
        let renewed = await lease.currentLease()
        XCTAssertEqual(renewed?.acquired, info?.acquired)
        XCTAssertNotNil(renewed?.renewed)
    }

    func testReleaseFreesTheLeaseForOthers() async {
        let lease = makeLease()
        var ok = await lease.tryAcquire()
        XCTAssertTrue(ok)
        await lease.release()

        let after = await lease.currentLease()
        XCTAssertNil(after)
        let held = await lease.isHeld
        XCTAssertFalse(held)
        ok = await lease.tryAcquire()
        XCTAssertTrue(ok, "a released lease is takeable again")
    }

    /// A live holder in another process blocks us — this is the property that
    /// stops two engines from running against one store.
    func testLiveForeignLeaseBlocksAcquisition() async throws {
        let foreign = SyncLeaseInfo(
            app: "imprint", pid: 999_999, acquired: Date(), renewed: Date())
        try JSONEncoder().encode(foreign)
            .write(to: directory.appendingPathComponent("sync-lease.json"))

        let lease = makeLease()
        let ok = await lease.tryAcquire()
        XCTAssertFalse(ok, "must not steal a live lease")
        let held = await lease.isHeld
        XCTAssertFalse(held)
        let holder = await lease.currentLease()?.app
        XCTAssertEqual(holder, "imprint")
    }

    /// A crashed holder cannot release, so a lease older than the TTL is
    /// stealable — otherwise one crash would disable sync forever.
    func testStaleForeignLeaseIsStolen() async throws {
        let stale = SyncLeaseInfo(
            app: "imprint",
            pid: 999_999,
            acquired: Date().addingTimeInterval(-600),
            renewed: Date().addingTimeInterval(-120)) // older than the 60s TTL
        try JSONEncoder().encode(stale)
            .write(to: directory.appendingPathComponent("sync-lease.json"))

        let lease = makeLease(ttl: 60)
        let ok = await lease.tryAcquire()
        XCTAssertTrue(ok, "a stale lease must be stealable")
        let held = await lease.isHeld
        XCTAssertTrue(held)
        let holder = await lease.currentLease()?.app
        XCTAssertEqual(holder, "imbib")
    }

    /// Losing the lease to a thief must be visible to the holder, so its
    /// engine can stop instead of double-writing.
    func testRenewFailsAfterTheLeaseIsStolen() async throws {
        let lease = makeLease()
        let ok = await lease.tryAcquire()
        XCTAssertTrue(ok)

        let thief = SyncLeaseInfo(app: "impel", pid: 424_242, acquired: Date(), renewed: Date())
        try JSONEncoder().encode(thief)
            .write(to: directory.appendingPathComponent("sync-lease.json"))

        let renewedOK = await lease.renew()
        XCTAssertFalse(renewedOK, "renew must fail once someone else owns it")
        let held = await lease.isHeld
        XCTAssertFalse(held)
    }

    func testReleaseDoesNotRemoveAnotherHoldersLease() async throws {
        let foreign = SyncLeaseInfo(
            app: "imprint", pid: 999_999, acquired: Date(), renewed: Date())
        let url = directory.appendingPathComponent("sync-lease.json")
        try JSONEncoder().encode(foreign).write(to: url)

        await makeLease().release()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "release must never clear a lease we don't hold")
    }

    func testExpiredOwnLeaseIsReacquiredCleanly() async {
        let lease = makeLease(ttl: 0) // everything is instantly stale
        var ok = await lease.tryAcquire()
        XCTAssertTrue(ok)
        let held = await lease.isHeld
        XCTAssertFalse(held, "a zero-TTL lease is stale immediately")
        ok = await lease.tryAcquire()
        XCTAssertTrue(ok, "and can always be re-taken by us")
    }
}
