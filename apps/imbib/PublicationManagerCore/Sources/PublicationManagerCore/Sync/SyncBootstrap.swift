//
//  SyncBootstrap.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase D): the first-run path.
//
//  A device joining an existing cloud library must pull everything before it
//  starts pushing, or it would upload its own view of the world as if the
//  peer's records didn't exist. Bootstrap is that ordering:
//
//    1. full fetch (no change token — the engine's nil-token state IS the
//       ADR's "bootstrap": CloudKit replays the whole zone),
//    2. `FirstSyncMerge` to collapse independently-imported duplicates,
//    3. mark `sync.bootstrap_done` so later launches skip straight to normal
//       incremental sync.
//
//  FTS needs no special handling: the Rust apply path refreshes the index per
//  item, so a bootstrapped store is searchable the moment it lands (proven by
//  `bootstrap_apply_populates_fts` in the Rust convergence suite).
//

import Foundation
import ImbibRustCore
import ImpressLogging
import OSLog

public enum SyncBootstrap {

    static let bootstrapKey = "sync.bootstrap_done"

    /// Whether this store has completed its first full sync.
    public static func isDone() async -> Bool {
        let value = try? await ImbibImpressStore.shared.syncMetadataGet(key: bootstrapKey)
        return (value ?? nil) == "1"
    }

    static func markDone() async {
        try? await ImbibImpressStore.shared.syncMetadataSet(key: bootstrapKey, value: "1")
    }

    /// Run the first-sync sequence if it hasn't run yet.
    ///
    /// Called after the engine starts, so the fetch below goes through the
    /// already-configured `CKSyncEngine`. Idempotent and cheap on later
    /// launches (a single metadata read).
    ///
    /// - Returns: the merge report when a bootstrap actually ran, else nil.
    @discardableResult
    public static func runIfNeeded(engine: CloudSyncEngine = .shared) async -> FirstSyncMergeReport? {
        guard await !isDone() else { return nil }

        Logger.sync.infoCapture("First sync: fetching the full zone", category: "sync")

        // The engine has no change token on a fresh install, so this pulls the
        // entire zone; on a re-bootstrap it is an ordinary incremental fetch.
        await engine.nudge()

        let report = await runMerge()
        // Persist it: the merge runs once, unattended, and Settings will want
        // to explain what it did long after this task has finished.
        SyncSettings.lastMergeReport = report
        await markDone()

        Logger.sync.infoCapture(
            "First sync complete: merged \(report?.groupsMerged ?? 0) duplicate group(s)",
            category: "sync")
        return report
    }

    /// Run `FirstSyncMerge` against the live store handle.
    ///
    /// Off the main actor: it walks every library and may delete items, which
    /// must never block the UI.
    static func runMerge() async -> FirstSyncMergeReport? {
        let store = RustStoreAdapter.shared.imbibStore
        return await Task.detached(priority: .utility) { () -> FirstSyncMergeReport? in
            do {
                return try FirstSyncMerge.run(store: store)
            } catch {
                Logger.sync.error("FirstSyncMerge failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    /// Clear the bootstrap marker so the next start re-runs the full fetch.
    /// Used when the account changes or the user resets sync.
    public static func reset() async {
        try? await ImbibImpressStore.shared.syncMetadataSet(key: bootstrapKey, value: nil)
    }
}
