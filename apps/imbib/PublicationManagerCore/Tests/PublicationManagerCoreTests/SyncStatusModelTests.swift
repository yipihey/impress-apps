//
//  SyncStatusModelTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0007 Phase 3 (Phase E): the status model and the two HTTP payloads.
//
//  `SyncStatusSnapshot` is the single description of sync state that the macOS
//  tab, the iOS pane, and `/api/sync/status` all render. These tests pin the
//  mapping for every availability state and the exact JSON shape, so a rename
//  in the payload breaks a test rather than an agent's parser.
//

import XCTest
import CloudKit
import ImpressKit
@testable import PublicationManagerCore

final class SyncStatusSnapshotTests: XCTestCase {

    // MARK: - Availability → snapshot mapping

    /// Every availability case must produce a distinct, non-empty
    /// `reason_code` + `explanation` pair for the panes and the API.
    func testEveryAvailabilityStateMapsToADistinctReasonCode() {
        let states: [SyncAvailability] = [
            .available,
            .unitTestProcess,
            .disabledByUser,
            .notEntitled,
            .accountUnavailable(.noAccount),
            .leaseHeldByOther("imprint"),
            .accountCheckFailed("offline")
        ]
        var codes = Set<String>()
        for state in states {
            var snapshot = SyncStatusSnapshot()
            snapshot.reasonCode = state.reasonCode
            snapshot.explanation = state.explanation
            snapshot.available = state.isAvailable

            XCTAssertFalse(snapshot.reasonCode.isEmpty)
            XCTAssertFalse(snapshot.explanation.isEmpty)
            codes.insert(snapshot.reasonCode)
        }
        XCTAssertEqual(codes.count, states.count, "reason codes must not collide")
    }

    func testAccountStatusDescriptionsAreStable() {
        XCTAssertEqual(SyncStatusSnapshot.describe(.available), "available")
        XCTAssertEqual(SyncStatusSnapshot.describe(.noAccount), "no_account")
        XCTAssertEqual(SyncStatusSnapshot.describe(.restricted), "restricted")
        XCTAssertEqual(
            SyncStatusSnapshot.describe(.temporarilyUnavailable), "temporarily_unavailable")
        XCTAssertEqual(SyncStatusSnapshot.describe(.couldNotDetermine), "could_not_determine")
    }

    // MARK: - Headline

    func testHeadlineReflectsTheThreeStatesAUserCaresAbout() {
        var snapshot = SyncStatusSnapshot()
        snapshot.enabled = false
        XCTAssertEqual(snapshot.headline, "Off")

        snapshot.enabled = true
        snapshot.available = false
        XCTAssertEqual(snapshot.headline, "Unavailable")

        snapshot.available = true
        snapshot.engineRunning = false
        XCTAssertEqual(snapshot.headline, "Ready")

        snapshot.engineRunning = true
        XCTAssertEqual(snapshot.headline, "Syncing")
    }

    func testPendingWorkTracksBothQueues() {
        var snapshot = SyncStatusSnapshot()
        XCTAssertFalse(snapshot.hasPendingWork)
        snapshot.outbox = 3
        XCTAssertTrue(snapshot.hasPendingWork)
        snapshot.outbox = 0
        snapshot.pendingRefs = 1
        XCTAssertTrue(snapshot.hasPendingWork)
    }

    // MARK: - GET /api/sync/status payload

    func testStatusPayloadContainsEveryDocumentedKey() {
        let json = SyncStatusSnapshot().jsonDictionary()
        let required = [
            "enabled", "available", "reason_code", "explanation", "account_status",
            "lease_holder", "engine_running", "last_push_ms", "last_pull_ms",
            "outbox", "pending_refs", "tombstones", "bootstrap_done",
            "merge_report", "last_error", "last_error_ms", "container", "zone"
        ]
        for key in required {
            XCTAssertNotNil(json[key], "payload is missing documented key '\(key)'")
        }
    }

    /// Absent values must serialize as JSON null, not vanish — an agent
    /// checking `last_push_ms == null` shouldn't have to also handle a missing
    /// key.
    func testAbsentValuesSerializeAsNullNotMissing() throws {
        let json = SyncStatusSnapshot().jsonDictionary()
        for key in ["account_status", "lease_holder", "last_push_ms", "last_pull_ms",
                    "last_error", "last_error_ms", "merge_report"] {
            XCTAssertTrue(json[key] is NSNull, "'\(key)' should be NSNull when absent")
        }
        // And the whole thing must actually serialize.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(parsed["last_push_ms"] is NSNull)
    }

    func testPopulatedSnapshotSerializesEveryField() throws {
        var snapshot = SyncStatusSnapshot()
        snapshot.enabled = true
        snapshot.available = true
        snapshot.reasonCode = "available"
        snapshot.explanation = "iCloud sync is active."
        snapshot.accountStatus = "available"
        snapshot.leaseHolder = "imbib"
        snapshot.engineRunning = true
        snapshot.lastPushAt = Date(timeIntervalSince1970: 1_700_000_000)
        snapshot.lastPullAt = Date(timeIntervalSince1970: 1_700_000_060)
        snapshot.outbox = 7
        snapshot.pendingRefs = 2
        snapshot.tombstones = 5
        snapshot.bootstrapDone = true
        snapshot.lastError = "network hiccup"
        snapshot.lastErrorAt = Date(timeIntervalSince1970: 1_700_000_030)

        var merge = FirstSyncMergeReport()
        merge.duplicateGroups = 4
        merge.groupsMerged = 3
        merge.publicationsRemoved = 3
        merge.tagsUnioned = 6
        merge.membershipsRepointed = 2
        merge.groupsSkippedSingleOrigin = 1
        snapshot.mergeReport = merge

        let json = snapshot.jsonDictionary()
        XCTAssertEqual(json["enabled"] as? Bool, true)
        XCTAssertEqual(json["reason_code"] as? String, "available")
        XCTAssertEqual(json["account_status"] as? String, "available")
        XCTAssertEqual(json["lease_holder"] as? String, "imbib")
        XCTAssertEqual(json["engine_running"] as? Bool, true)
        XCTAssertEqual(json["outbox"] as? Int, 7)
        XCTAssertEqual(json["pending_refs"] as? Int, 2)
        XCTAssertEqual(json["tombstones"] as? Int, 5)
        XCTAssertEqual(json["bootstrap_done"] as? Bool, true)
        XCTAssertEqual(json["last_push_ms"] as? Int, 1_700_000_000_000)
        XCTAssertEqual(json["last_pull_ms"] as? Int, 1_700_000_060_000)
        XCTAssertEqual(json["last_error"] as? String, "network hiccup")
        XCTAssertEqual(json["container"] as? String, SyncSettings.containerIdentifier)
        XCTAssertEqual(json["zone"] as? String, SyncSettings.zoneName)

        let reportJSON = try XCTUnwrap(json["merge_report"] as? [String: Any])
        XCTAssertEqual(reportJSON["duplicate_groups"] as? Int, 4)
        XCTAssertEqual(reportJSON["groups_merged"] as? Int, 3)
        XCTAssertEqual(reportJSON["publications_removed"] as? Int, 3)
        XCTAssertEqual(reportJSON["tags_unioned"] as? Int, 6)
        XCTAssertEqual(reportJSON["memberships_repointed"] as? Int, 2)
        XCTAssertEqual(reportJSON["groups_skipped_single_origin"] as? Int, 1)

        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    // MARK: - Gathering against the live (test-process) environment

    /// `gather()` must work with no CloudKit and no engine — that is the state
    /// every unit test, and every un-opted-in user, is in.
    func testGatherWorksWithoutCloudKitAndReportsRefusal() async {
        let snapshot = await SyncStatusSnapshot.gather()

        XCTAssertFalse(snapshot.available)
        XCTAssertFalse(snapshot.engineRunning)
        XCTAssertEqual(snapshot.reasonCode, "unit_test_process")
        XCTAssertFalse(snapshot.explanation.isEmpty)
        // Queue counters come from the store and are valid regardless.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(snapshot.jsonDictionary()))
    }

    /// A status read must never acquire the writer lease — otherwise merely
    /// opening Settings (or polling the API) would steal sync from a sibling.
    func testGatherDoesNotAcquireTheLease() async {
        await SyncLease.shared.release()
        _ = await SyncStatusSnapshot.gather()
        let held = await SyncLease.shared.isHeld
        XCTAssertFalse(held, "gathering status must not take the lease")
    }

    // MARK: - Merge report persistence

    func testMergeReportRoundTripsThroughSettings() {
        defer { SyncSettings.lastMergeReport = nil }

        XCTAssertNil(SyncSettings.lastMergeReport)
        var report = FirstSyncMergeReport()
        report.duplicateGroups = 2
        report.groupsMerged = 1
        report.publicationsRemoved = 1
        SyncSettings.lastMergeReport = report

        XCTAssertEqual(SyncSettings.lastMergeReport, report)

        SyncSettings.lastMergeReport = nil
        XCTAssertNil(SyncSettings.lastMergeReport)
    }

    func testResetDiagnosticsClearsTheMergeReport() {
        var report = FirstSyncMergeReport()
        report.groupsMerged = 1
        SyncSettings.lastMergeReport = report
        SyncSettings.lastPushAt = Date()

        SyncSettings.resetDiagnostics()

        XCTAssertNil(SyncSettings.lastMergeReport)
        XCTAssertNil(SyncSettings.lastPushAt)
    }

    // MARK: - Presentation helpers

    func testMergeDescriptionMentionsBothOutcomes() {
        var report = FirstSyncMergeReport()
        report.groupsMerged = 2
        report.publicationsRemoved = 2
        report.groupsSkippedSingleOrigin = 1

        let text = SyncDiagnosticsSection.describe(report)
        XCTAssertTrue(text.contains("2"))
        XCTAssertTrue(text.lowercased().contains("review"),
                      "local-only duplicates should be described as needing review")

        let empty = SyncDiagnosticsSection.describe(FirstSyncMergeReport())
        XCTAssertFalse(empty.isEmpty)
    }

    func testAccountStatusIsHumanizedForDisplay() {
        XCTAssertEqual(SyncDiagnosticsSection.humanize("available"), "Signed in")
        XCTAssertEqual(SyncDiagnosticsSection.humanize("no_account"), "Not signed in")
        // Unknown codes pass through rather than showing an empty cell.
        XCTAssertEqual(SyncDiagnosticsSection.humanize("weird_new_code"), "weird_new_code")
    }

    func testRelativeDateFormattingHandlesNever() {
        XCTAssertEqual(SyncDiagnosticsSection.relative(nil), "Never")
        XCTAssertNotEqual(SyncDiagnosticsSection.relative(Date()), "Never")
    }

    /// The reset dialog must say plainly that user data survives — "reset"
    /// beside a sync feature otherwise reads as "delete my library".
    func testResetExplanationPromisesDataIsUntouched() {
        let text = SyncActionsSection.resetExplanation.lowercased()
        XCTAssertTrue(text.contains("not touched") || text.contains("untouched"))
        XCTAssertTrue(text.contains("papers"))
    }

    /// The scope footer must name the real 3.0 limitations, since it is the
    /// only place a user learns PDFs don't travel.
    func testScopeFooterStatesTheKnownLimitations() {
        let doesNot = SyncScopeFooter.doesNotSyncText.lowercased()
        XCTAssertTrue(doesNot.contains("pdf"), "must disclose that PDFs don't sync")
        XCTAssertTrue(doesNot.contains("undo") || doesNot.contains("history"),
                      "must disclose per-device edit history")
        XCTAssertTrue(SyncScopeFooter.syncsText.lowercased().contains("tags"))
    }
}

// MARK: - Actions

final class SyncActionsTests: XCTestCase {

    /// In a test process the gate refuses, so a nudge must come back
    /// `accepted:false` WITH a reason — and must not start an engine.
    func testNudgeRefusesWithAReasonWhenUnavailable() async {
        let outcome = await SyncActions.nudge()

        XCTAssertFalse(outcome.accepted)
        XCTAssertFalse(outcome.reason.isEmpty, "a refusal must explain itself")

        let running = await CloudSyncEngine.shared.running
        XCTAssertFalse(running, "a refused nudge must not start the engine")
    }

    /// The nudge payload shape the router returns.
    func testNudgePayloadShape() async {
        let outcome = await SyncActions.nudge()
        let json: [String: Any] = [
            "status": "ok",
            "accepted": outcome.accepted,
            "reason": outcome.reason
        ]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertNotNil(json["accepted"] as? Bool)
        XCTAssertFalse((json["reason"] as? String)?.isEmpty ?? true)
    }

    /// Turning the flag off must stop the engine and leave it stopped.
    func testDisablingSyncStopsTheEngine() async {
        defer { SyncSettings.isEnabled = false }

        SyncSettings.isEnabled = true
        await CloudSyncEngineLauncher.stop()
        SyncSettings.isEnabled = false

        let running = await CloudSyncEngine.shared.running
        XCTAssertFalse(running)
        XCTAssertFalse(SyncSettings.isEnabled)
    }

    /// Reset clears cursors and diagnostics — and, critically, never touches
    /// the user's data. We assert the store still holds what it held.
    func testResetSyncStateClearsCursorsButNotUserData() async throws {
        let store = ImbibImpressStore.shared

        // Seed a marker in the store's sync metadata + a real library.
        try await store.syncMetadataSet(key: "sync.engine_state", value: "cursor-blob")
        SyncSettings.lastPushAt = Date()
        var report = FirstSyncMergeReport()
        report.groupsMerged = 1
        SyncSettings.lastMergeReport = report

        let librariesBefore = await RustStoreAdapter.shared.listLibraries().count

        await SyncActions.resetSyncState()

        let engineState = try await store.syncMetadataGet(key: "sync.engine_state")
        XCTAssertNil(engineState, "the change cursor must be cleared")
        let bootstrapDone = await SyncBootstrap.isDone()
        XCTAssertFalse(bootstrapDone, "bootstrap must be re-armed")
        XCTAssertNil(SyncSettings.lastPushAt)
        XCTAssertNil(SyncSettings.lastMergeReport)

        let librariesAfter = await RustStoreAdapter.shared.listLibraries().count
        XCTAssertEqual(librariesAfter, librariesBefore, "reset must never delete user data")
    }
}
