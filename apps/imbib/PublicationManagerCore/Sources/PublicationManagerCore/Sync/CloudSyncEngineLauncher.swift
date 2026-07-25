//
//  CloudSyncEngineLauncher.swift
//  PublicationManagerCore
//
//  ADR-0007 Phase 3 (Phase D), decision 9: the ONE place the sync engine is
//  allowed to start from an app launch.
//
//  ## Why the delay is non-negotiable
//
//  imbib has a documented, hard-won startup invariant (CLAUDE.md, "Startup
//  Render Loop Bug"): a background service that mutates the store — and thus
//  emits store events — during the first ~90 seconds of launch drives SwiftUI
//  into a perpetual body re-evaluation loop. The symptom is a beach ball, and
//  it has been reintroduced before.
//
//  A sync engine is the most event-producing background service imaginable: a
//  fetched batch mutates dozens of rows at once. So the launcher waits 120s —
//  the `BackgroundScheduler.defaultStartupDelay` convention, with margin over
//  the 90s floor — before it so much as evaluates availability. Nothing here
//  touches the store, CloudKit, or the event bus before that deadline.
//
//  Under `swift test` the whole thing short-circuits: no timer, no store
//  access, no CloudKit (`ImpressRuntime.isUnitTestProcess`).
//

import Foundation
import ImpressKit
import ImpressLogging
import OSLog

/// Starts the CloudKit sync engine after the launch grace period.
public enum CloudSyncEngineLauncher {

    /// Delay before the first availability evaluation. Must stay ≥ 120s: the
    /// render-loop invariant forbids store events in the first ~90s and this
    /// keeps a full margin over it.
    public static let startupDelay: TimeInterval = 120

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var launchTask: Task<Void, Never>?

    /// Schedule the engine to start once the grace period has elapsed.
    ///
    /// Safe to call from both app entry points and safe to call twice — the
    /// second call is a no-op while the first is pending or running.
    public static func startAfterGrace(delay: TimeInterval = startupDelay) {
        // Never in tests: an xctest worker has no App Group entitlement and
        // must not reach the shared container, let alone CloudKit.
        guard !ImpressRuntime.isUnitTestProcess else { return }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard launchTask == nil else { return }

        launchTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            // Cheap pre-check first: when the user hasn't opted in (the
            // default) this costs one UserDefaults read and stops — no
            // CloudKit type is ever constructed.
            guard SyncSettings.isEnabled else {
                Logger.sync.infoCapture(
                    "CloudKit sync is off — engine not started", category: "sync")
                return
            }

            let availability = await CloudSyncEngine.shared.start()
            guard availability == .available else {
                Logger.sync.infoCapture(
                    "CloudKit sync unavailable: \(availability.explanation)", category: "sync")
                return
            }

            await SyncBootstrap.runIfNeeded()
        }
    }

    /// Stop the engine and forget the scheduled start (Settings' toggle-off).
    public static func stop() async {
        stateLock.lock()
        let task = launchTask
        launchTask = nil
        stateLock.unlock()

        task?.cancel()
        await CloudSyncEngine.shared.stop()
    }

    /// Restart after a settings change — toggle-off then toggle-on without an
    /// app relaunch. Skips the grace period: by the time the user is flipping
    /// switches in Settings, launch is long over.
    public static func restartNow() {
        guard !ImpressRuntime.isUnitTestProcess else { return }
        Task {
            await stop()
            guard SyncSettings.isEnabled else { return }
            let availability = await CloudSyncEngine.shared.start()
            if availability == .available {
                await SyncBootstrap.runIfNeeded()
            }
        }
    }
}
