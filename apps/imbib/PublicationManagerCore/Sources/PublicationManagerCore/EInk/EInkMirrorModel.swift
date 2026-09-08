//
//  EInkMirrorModel.swift
//  PublicationManagerCore
//
//  SwiftUI-facing holder for the e-ink mirror status (ADR-025), in the shape
//  of `SyncStatusModel`: views, the Paper menu and the list wrappers read
//  `isConfigured` / `showsIndividualControls` from here and never compute
//  them. The snapshot is gathered in exactly one place (`eink-status` in
//  Rust) and re-read off the main thread.
//
//  It refreshes when the store says the mirror changed — the typed
//  `.itemsMutated(kind: .einkMirror)` event, and `.structural` because a
//  device record being added/removed or a batch import arrives that way —
//  coalesced to one read per burst. It never mutates the store and posts no
//  events, so it is safe in the first 90 s of launch (see the startup
//  render-loop invariant in the root CLAUDE.md).
//
//  P6 keeps it minimal: status + the two gates. P7 (`EInkSyncCoordinator`,
//  `EInkConnectionMonitor`) extends it with connection state, sync progress
//  and the folder checklist.
//

import Foundation
import ImpressLogging
import ImpressStoreKit
import OSLog

@MainActor
@Observable
public final class EInkMirrorModel {

    public static let shared = EInkMirrorModel()

    /// The latest gathered state; nil until the first read completes.
    public private(set) var status: EInkStatusSnapshot?

    /// When `status` was last read from the store.
    public private(set) var lastRefreshAt: Date?

    /// True while the coordinator runs an engine pass (set by `EInkServices`
    /// from the coordinator's run-state callback) — the toolbar glyph and
    /// the Settings card read it; nothing else does.
    public private(set) var isSyncing = false

    /// What the last run was for, while `isSyncing`.
    public private(set) var syncingReason: EInkSyncReason?

    /// Record the coordinator's run state. Main-actor by construction.
    public func setSyncing(_ running: Bool, reason: EInkSyncReason) {
        isSyncing = running
        syncingReason = running ? reason : nil
    }

    /// At least one enabled device exists — gates the Paper-menu items,
    /// the command-palette entries and the PDF-tab chip.
    public var isConfigured: Bool { status?.isConfigured ?? false }

    /// A device in individual mode is configured, so rows carry
    /// `einkState` markers and the per-paper verbs (context menu, swipe,
    /// `e`, ⌃⌘E) apply. In `all` mode everything with a PDF is mirrored
    /// automatically and the per-paper verbs are hidden.
    public var showsIndividualControls: Bool { status?.showsIndividualControls ?? false }

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    private init() {
        startObserving()
        scheduleRefresh()
    }

    /// Re-read the status now (off-main FFI, then a main-actor assignment
    /// only when something changed, so equal snapshots do not re-render).
    public func refresh() async {
        let fresh = await RustStoreAdapter.shared.einkStatusBackground()
        lastRefreshAt = Date()
        guard fresh != status else { return }
        status = fresh
        if let fresh {
            Logger.library.infoCapture(
                "eink.status devices=\(fresh.devices.count) marker=\(fresh.markerDeviceId ?? "none") "
                    + "queued=\(fresh.counts.queued) awaitingSource=\(fresh.counts.awaitingSource) "
                    + "awaitingFolder=\(fresh.counts.awaitingFolder) uploaded=\(fresh.counts.uploaded) "
                    + "stale=\(fresh.counts.stale) failed=\(fresh.counts.failed)",
                category: "eink")
        }
    }

    /// Coalesce a burst of store events into one read.
    public func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            // One bounded wait, not a loop — cancellation cannot be swallowed.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.pendingRefresh = nil
            await self.refresh()
        }
    }

    private func startObserving() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in ImbibImpressStore.shared.events.subscribe() {
                guard let self else { return }
                switch event {
                case .structural:
                    self.scheduleRefresh()
                case .itemsMutated(let kind, _):
                    if kind == .einkMirror { self.scheduleRefresh() }
                case .collectionMembershipChanged:
                    break
                }
            }
        }
    }
}
