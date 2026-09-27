//
//  WorkflowTickTimer.swift
//  PublicationManagerCore
//
//  Ticks the store's workflow trigger engine on a timer. This is the whole
//  of imbib's part of plan W3 / D-R10 (docs/plan-self-reflective-layer.md):
//  the retention-cleanup logic that used to live in `RetentionCleanupService`
//  (deleted) is now the Rust verb `imbib-library-service_retention-cleanup`,
//  run by the stored `imbib.retention-cleanup` workflow
//  (`impress/workflow@1.0.0`, seeded by `impress-store-ffi`'s
//  `workflow_tick()` the first time it runs against a workspace that does
//  not have it yet). Swift decides nothing about which workflow runs, when,
//  or what it does — it only calls `SharedStore.workflowTick()` and logs
//  which workflow ids ran. The 90 s startup delay
//  (CLAUDE.md "Background Services Must Defer Startup Work") is enforced in
//  TWO places on purpose: the engine's own `start_delay` decides whether any
//  *workflow* runs, and this timer additionally waits 90 s before its FIRST
//  tick so the tick call itself — which also seeds the retention workflow
//  row on its very first invocation — is never background write work during
//  the startup settling window.
//

import Foundation
import ImpressLogging
import ImpressRustCore
import ImbibVerbsFFI
import OSLog

/// Periodically calls `SharedStore.workflowTick()` so stored workflows with
/// a `schedule` trigger (starting with `imbib.retention-cleanup`) get a
/// chance to run. One instance per process; a second `start()` is a no-op.
@MainActor
public final class WorkflowTickTimer {
    public static let shared = WorkflowTickTimer()

    /// How often the app polls the engine. The engine's own per-workflow
    /// trigger (`imbib.retention-cleanup` is `every: "24h"`) decides what
    /// actually runs on any given tick — this is only the poll granularity,
    /// picked from the same range impel-taskd's main loop already ticks at.
    private static let tickIntervalSeconds: UInt64 = 15

    private var task: Task<Void, Never>?

    private init() {}

    /// Start ticking, once per process launch.
    public func start() {
        guard task == nil else {
            Logger.library.debugCapture(
                "workflow tick timer already started — not starting a second",
                category: "workflow")
            return
        }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func runLoop() async {
        // Same 90 s grace period as every other background writer in this
        // app (FeedScheduler, the e-ink startup gate, Spotlight indexing) —
        // see the file header for why this tick specifically needs it too.
        do {
            try await Task.sleep(for: .seconds(90))
        } catch {
            return
        }
        guard let path = RustStoreAdapter.shared.databaseLocation else { return }
        do {
            try await Task.detached(priority: .utility) {
                try ImbibVerbsFFI.initializeVerbStore(path: path)
            }.value
        } catch {
            Logger.library.errorCapture("Workflow verb store refused: \(error)", category: "workflow")
            return
        }
        await tickOnce()

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Self.tickIntervalSeconds))
            } catch {
                break
            }
            await tickOnce()
        }
    }

    private func tickOnce() async {
        guard let store = RustStoreAdapter.shared.sharedReviewStore() else { return }
        let ran = await Task.detached(priority: .utility) {
            store.workflowTick()
        }.value
        if !ran.isEmpty {
            Logger.library.infoCapture(
                "workflow tick ran: \(ran.joined(separator: ", "))",
                category: "workflow")
        }
    }
}
