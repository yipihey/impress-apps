//
//  SyncStatusModel.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase E): ONE description of sync state, read by the
//  macOS Settings tab, the iOS Sync pane, and `GET /api/sync/status`.
//
//  Three surfaces that disagree about whether sync is working would be worse
//  than none, so none of them computes anything: they all render
//  `SyncStatusSnapshot`, which is gathered in exactly one place. The snapshot
//  is a plain `Sendable` value with a pure `jsonDictionary()`, which is what
//  makes the HTTP payload unit-testable without a running engine, a CloudKit
//  account, or a main-actor hop.
//
//  The observable wrapper exists only so SwiftUI can watch it; it holds no
//  logic of its own beyond refresh scheduling.
//

import Foundation
import CloudKit
import ImpressKit
import ImpressLogging
import OSLog

// MARK: - Snapshot

/// A point-in-time description of the sync subsystem.
public struct SyncStatusSnapshot: Sendable, Equatable {

    /// User's master switch (`SyncSettings.isEnabled`).
    public var enabled: Bool = false
    /// Whether every precondition currently holds.
    public var available: Bool = false
    /// Machine-readable reason (`SyncAvailability.reasonCode`).
    public var reasonCode: String = "disabled_by_user"
    /// Human-readable reason, shown verbatim in Settings.
    public var explanation: String = ""
    /// iCloud account status, when it was probed. Nil when the chain stopped
    /// before the account check (flag off, not entitled, test process).
    public var accountStatus: String?
    /// Which app holds the single-writer lease, if any.
    public var leaseHolder: String?
    /// Whether THIS process is running the engine.
    public var engineRunning: Bool = false

    public var lastPushAt: Date?
    public var lastPullAt: Date?

    /// Unpushed local changes.
    public var outbox: UInt32 = 0
    /// References parked waiting for their endpoints to arrive.
    public var pendingRefs: UInt32 = 0
    /// Local deletion markers awaiting propagation/expiry.
    public var tombstones: UInt32 = 0

    public var bootstrapDone: Bool = false
    public var mergeReport: FirstSyncMergeReport?
    public var lastError: String?
    public var lastErrorAt: Date?

    public init() {}

    /// True when there is local work waiting to go up.
    public var hasPendingWork: Bool { outbox > 0 || pendingRefs > 0 }

    /// A short status line for the top of a Settings pane.
    public var headline: String {
        if !enabled { return "Off" }
        if available { return engineRunning ? "Syncing" : "Ready" }
        return "Unavailable"
    }

    /// The JSON body for `GET /api/sync/status`.
    ///
    /// Pure by design — the router just wraps this, and the payload shape is
    /// testable without any of the machinery it describes.
    public func jsonDictionary() -> [String: Any] {
        var json: [String: Any] = [
            "enabled": enabled,
            "available": available,
            "reason_code": reasonCode,
            "explanation": explanation,
            "engine_running": engineRunning,
            "outbox": Int(outbox),
            "pending_refs": Int(pendingRefs),
            "tombstones": Int(tombstones),
            "bootstrap_done": bootstrapDone,
            "container": SyncSettings.containerIdentifier,
            "zone": SyncSettings.zoneName
        ]
        json["account_status"] = accountStatus ?? NSNull()
        json["lease_holder"] = leaseHolder ?? NSNull()
        json["last_push_ms"] = lastPushAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull()
        json["last_pull_ms"] = lastPullAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull()
        json["last_error"] = lastError ?? NSNull()
        json["last_error_ms"] = lastErrorAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull()

        if let mergeReport {
            json["merge_report"] = [
                "duplicate_groups": mergeReport.duplicateGroups,
                "groups_merged": mergeReport.groupsMerged,
                "publications_removed": mergeReport.publicationsRemoved,
                "tags_unioned": mergeReport.tagsUnioned,
                "memberships_repointed": mergeReport.membershipsRepointed,
                "groups_skipped_single_origin": mergeReport.groupsSkippedSingleOrigin
            ]
        } else {
            json["merge_report"] = NSNull()
        }
        return json
    }
}

// MARK: - Gathering

extension SyncStatusSnapshot {

    /// Collect the current state from every source of truth.
    ///
    /// Deliberately `nonisolated` and free-standing so the HTTP router (an
    /// actor) can call it directly instead of bouncing through the main actor
    /// just to read numbers.
    ///
    /// Note this uses `evaluatePreLease` — a *status read must not acquire the
    /// lease*, or merely opening Settings would steal sync from a sibling app.
    public static func gather() async -> SyncStatusSnapshot {
        var snapshot = SyncStatusSnapshot()

        snapshot.enabled = SyncSettings.isEnabled
        snapshot.lastPushAt = SyncSettings.lastPushAt
        snapshot.lastPullAt = SyncSettings.lastPullAt
        snapshot.lastError = SyncSettings.lastError
        snapshot.lastErrorAt = SyncSettings.lastErrorAt
        snapshot.mergeReport = SyncSettings.lastMergeReport

        let availability = await CloudSyncAvailability.evaluatePreLease()
        snapshot.available = availability.isAvailable
        snapshot.reasonCode = availability.reasonCode
        snapshot.explanation = availability.explanation
        if case .accountUnavailable(let status) = availability {
            snapshot.accountStatus = Self.describe(status)
        } else if availability.isAvailable {
            snapshot.accountStatus = "available"
        }

        // Who owns the writer lease — reported even when it is us, so the
        // "another app is syncing" case in Settings can name the holder.
        snapshot.leaseHolder = await SyncLease.shared.currentLease()?.app
        snapshot.engineRunning = await CloudSyncEngine.shared.running

        // Store-backed counters. These work regardless of CloudKit state —
        // the outbox fills up whether or not sync is switched on, which is
        // exactly what makes "turn it on later" safe.
        if let counts = try? await ImbibImpressStore.shared.syncStatusCounts() {
            snapshot.outbox = counts.outbox
            snapshot.pendingRefs = counts.pendingRefs
            snapshot.tombstones = counts.tombstones
        }
        snapshot.bootstrapDone = await SyncBootstrap.isDone()

        return snapshot
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "no_account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could_not_determine"
        case .temporarilyUnavailable: return "temporarily_unavailable"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Observable wrapper

/// SwiftUI-facing holder for the snapshot. Views bind to this; they never
/// compute status themselves.
@MainActor
@Observable
public final class SyncStatusModel {

    public static let shared = SyncStatusModel()

    /// The latest gathered state.
    public private(set) var snapshot = SyncStatusSnapshot()

    /// True while a refresh or action is in flight (drives spinners and
    /// disables buttons).
    public private(set) var isBusy = false

    /// Set when an action (Sync Now / Reset) fails, for inline display.
    public private(set) var actionMessage: String?

    private var pollTask: Task<Void, Never>?

    public init() {}

    /// Re-read everything.
    public func refresh() async {
        snapshot = await SyncStatusSnapshot.gather()
    }

    /// Refresh now and then every `interval` seconds while a pane is visible.
    ///
    /// Poll rather than push: the numbers move slowly, a visible Settings pane
    /// is short-lived, and a polling read costs three cheap COUNT(*)s. Wiring
    /// a push channel through the engine would add a lifetime to manage for no
    /// user-visible gain.
    public func startAutoRefresh(interval: TimeInterval = 5) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopAutoRefresh() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Actions

    /// Flip the master switch and start/stop the engine to match.
    public func setEnabled(_ enabled: Bool) async {
        SyncSettings.isEnabled = enabled
        isBusy = true
        defer { isBusy = false }

        if enabled {
            CloudSyncEngineLauncher.restartNow()
            // Give the start a moment so the pane doesn't flash "Off".
            try? await Task.sleep(for: .milliseconds(300))
        } else {
            await CloudSyncEngineLauncher.stop()
            SyncSettings.clearError()
        }
        await refresh()
    }

    /// "Sync Now" — push and pull immediately.
    public func syncNow() async {
        isBusy = true
        defer { isBusy = false }
        actionMessage = nil

        let outcome = await SyncActions.nudge()
        actionMessage = outcome.accepted ? "Sync requested." : outcome.reason
        await refresh()
    }

    /// "Reset Sync State" — forget CloudKit cursors, keep every byte of user
    /// data. The next run re-bootstraps from the server.
    public func resetSyncState() async {
        isBusy = true
        defer { isBusy = false }

        await SyncActions.resetSyncState()
        actionMessage = "Sync state cleared. A full sync will run on the next start."
        await refresh()
    }

    public func clearActionMessage() { actionMessage = nil }
}

// MARK: - Actions shared by UI and HTTP

/// The verbs behind the buttons, factored out so `POST /api/sync/nudge` and
/// the Settings buttons cannot drift apart.
public enum SyncActions {

    public struct NudgeOutcome: Sendable, Equatable {
        public let accepted: Bool
        public let reason: String
        public init(accepted: Bool, reason: String) {
            self.accepted = accepted
            self.reason = reason
        }
    }

    /// Trigger a sync pass. Refuses (with a reason) when sync is unavailable —
    /// callers get told why rather than silently getting nothing.
    public static func nudge() async -> NudgeOutcome {
        let availability = await CloudSyncAvailability.evaluatePreLease()
        guard availability.isAvailable else {
            return NudgeOutcome(accepted: false, reason: availability.explanation)
        }

        if await CloudSyncEngine.shared.running {
            await CloudSyncEngine.shared.nudge()
            return NudgeOutcome(accepted: true, reason: "Sync requested.")
        }

        // Not running here yet (fresh toggle, or the lease was free): starting
        // performs a full push/pull, so this doubles as the nudge.
        let started = await CloudSyncEngine.shared.start()
        guard started.isAvailable else {
            return NudgeOutcome(accepted: false, reason: started.explanation)
        }
        await CloudSyncEngine.shared.nudge()
        return NudgeOutcome(accepted: true, reason: "Sync engine started and synced.")
    }

    /// Clear CloudKit-side bookkeeping so the next start re-bootstraps.
    ///
    /// **Never touches user data.** What it clears:
    /// - `sync.engine_state` — the change token and pending-change list,
    ///   which is what forces the next fetch to replay the whole zone.
    /// - `sync.bootstrap_done` — so `SyncBootstrap` re-runs (full fetch +
    ///   first-sync merge).
    /// - The diagnostics (timestamps, last error, merge report).
    ///
    /// Per-record system-field blobs (`sync_record_state`) are deliberately
    /// left in place. They are per-record change tags, and the re-bootstrap
    /// this triggers overwrites every one of them with the server's current
    /// version as the records come back — so they self-heal completely rather
    /// than needing a separate mass-delete. (Any that don't come back are for
    /// records the server no longer has; the `unknownItem` path already drops
    /// those on the next save.)
    public static func resetSyncState() async {
        await CloudSyncEngineLauncher.stop()

        try? await ImbibImpressStore.shared.syncMetadataSet(
            key: "sync.engine_state", value: nil)
        await SyncBootstrap.reset()
        SyncSettings.resetDiagnostics()

        Logger.sync.infoCapture(
            "Sync state reset — cursors cleared, user data untouched", category: "sync")

        // Come back up if the user still has sync on.
        if SyncSettings.isEnabled {
            CloudSyncEngineLauncher.restartNow()
        }
    }
}
