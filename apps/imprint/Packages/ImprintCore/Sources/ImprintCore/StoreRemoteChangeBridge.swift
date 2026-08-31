//
//  StoreRemoteChangeBridge.swift
//  ImprintCore
//
//  The RECEIVE half of cross-process store-change signalling for imprint.
//
//  The unified store is one SQLite file shared by every impress app, but the
//  change signals imprint's views refresh on are all in-process:
//  `ManuscriptStoreAdapter.dataVersion` bumps only on this process's own
//  mutations, and the `StoreEventPublisher` buses (`ImprintImpressStore`,
//  PMC's `ImbibImpressStore`) fan out only to this process's subscribers. So
//  when ANOTHER process writes the store — imbib's `CloudSyncEngine` applying
//  a CloudKit pull, the journal pipeline minting a manuscript — imprint's
//  manuscript list showed nothing until force-quit + relaunch.
//
//  The EMIT half already exists suite-wide (Darwin notifications via
//  `ImpressNotification`): `CloudSyncEngine` posts `syncApplied` once per
//  applied batch (lease holder only, `CloudSyncEngine.applyFetchedChanges`),
//  and the journal pipeline posts `manuscriptStatusChanged` /
//  `manuscriptSnapshotCreated`. imprint had zero `ImpressNotification.observe`
//  call sites — this bridge is that missing subscription. It observes the
//  events below, coalesces bursts, and invokes ONE injected callback per
//  window on the main actor. The app targets wire the callback:
//
//    * both platforms → `ManuscriptStoreAdapter.noteRemoteChange(_:)`
//      (bumps `dataVersion`, fans out on `ImprintImpressStore`);
//    * macOS additionally → `ImbibImpressStore.shared.postMutation(...)`,
//      because the chassis surfaces (`ManuscriptListWrapper`, the sidebar
//      snapshot maintainer) subscribe to PMC's bus, not imprint's.
//
//  Deliberately NOT observed: `libraryChanged` from imbib. Paper imports and
//  enrichment mutate hundreds of publication rows in bursts; imprint's
//  manuscript surfaces don't live-query publications, so refreshing the shell
//  per paper write would be churn without a pixel changing.
//
//  Darwin notifications don't reach a suspended process (iOS), so this bridge
//  covers imprint-while-running; the scene-activation refresh in
//  `IOSManuscriptLibraryView` covers changes that landed while suspended.
//
//  Safety properties (sidebar-fragility rules — additive, gated, revertible):
//   * Additive: nothing existing is rerouted; local mutations refresh exactly
//     as before. The bridge only ADDS a refresh trigger.
//   * Gated: setting the `UserDefaults` key `imprint.remoteChangeBridgeDisabled`
//     to YES turns `start()` into a logged no-op — revertible without a rebuild.
//   * No self-amplification: the bridge never posts a Darwin notification and
//     never writes the store, so a received signal cannot echo, and imprint's
//     own mutations (which post no Darwin today) cannot re-enter it. Bursts
//     coalesce into ONE callback per debounce window (default 500 ms), so an
//     external storm costs at most two refreshes per second. This is also why
//     the startup-render-loop invariant (root CLAUDE.md) doesn't require a
//     launch delay here: the bridge is signal-driven, not a periodic mutating
//     service — with no external writer there are zero events.
//

import Foundation
import ImpressKit
import ImpressLogging
import OSLog

private let bridgeLog = Logger(subsystem: "com.imprint.app", category: "remote-change")

@MainActor
public final class StoreRemoteChangeBridge {

    public static let shared = StoreRemoteChangeBridge()

    /// Defaults kill switch, checked at `start()`. YES disables the bridge for
    /// the rest of the launch (`defaults write com.impress.imprint
    /// imprint.remoteChangeBridgeDisabled -bool YES`, then relaunch).
    public static let disabledDefaultsKey = "imprint.remoteChangeBridgeDisabled"

    /// The cross-app events that mean "another process changed rows imprint
    /// renders", with the apps allowed to emit each. Kept as data so tests can
    /// pin the table. `syncApplied` comes from whichever sibling holds the
    /// sync lease (imbib today; impart also runs the launcher). The
    /// `manuscript*` rows are `JournalEventBridge`'s own source lists minus
    /// imprint itself — a local mutation already bumped `dataVersion`, and
    /// observing our own posts would refresh twice for one edit.
    public static let observedEvents: [(event: String, sources: [SiblingApp])] = [
        (ImpressNotification.syncApplied, [.imbib, .impart]),
        (ImpressNotification.manuscriptStatusChanged, [.imbib, .impel]),
        (ImpressNotification.manuscriptSnapshotCreated, [.imbib, .impel]),
    ]

    /// Where the kill switch is read from. Injectable so tests can flip it in
    /// an isolated suite — parallel test workers share the persisted standard
    /// domain, so a test writing `.standard` poisons its siblings.
    private let defaults: UserDefaults
    private var observations: [DarwinObservation] = []
    private var onRemoteChange: (@MainActor (String) -> Void)?
    private var debounce: Duration = .milliseconds(500)
    /// Receipt labels accumulated for the open coalesce window.
    private var pendingLabels: [String] = []
    private var pendingTask: Task<Void, Never>?

    /// Total callback invocations this launch — a cheap probe for tests and
    /// for "is the bridge alive" diagnostics from the console.
    public private(set) var firedCount = 0

    public var isRunning: Bool { !observations.isEmpty }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Begin observing. Idempotent; a logged no-op when the kill switch is set.
    /// - Parameters:
    ///   - debounce: trailing coalesce window for bursts.
    ///   - onRemoteChange: invoked once per window, on the main actor, with a
    ///     human-readable summary of the coalesced receipts.
    public func start(
        debounce: Duration = .milliseconds(500),
        onRemoteChange: @escaping @MainActor (String) -> Void
    ) {
        guard observations.isEmpty else { return }
        guard !defaults.bool(forKey: Self.disabledDefaultsKey) else {
            bridgeLog.infoCapture(
                "StoreRemoteChangeBridge disabled via \(Self.disabledDefaultsKey)",
                category: "remote-change")
            return
        }
        self.debounce = debounce
        self.onRemoteChange = onRemoteChange
        for mapping in Self.observedEvents {
            for source in mapping.sources {
                let label = "\(mapping.event)(\(source.rawValue))"
                let observation = ImpressNotification.observe(mapping.event, from: source) {
                    // Darwin delivery queue → main actor.
                    Task { @MainActor [weak self] in self?.noteReceipt(label) }
                }
                observations.append(observation)
            }
        }
        bridgeLog.infoCapture(
            "StoreRemoteChangeBridge started — observing \(self.observations.count) cross-process events",
            category: "remote-change")
    }

    /// Stop observing and drop any window that hasn't fired yet.
    public func stop() {
        for obs in observations { obs.invalidate() }
        observations.removeAll()
        pendingTask?.cancel()
        pendingTask = nil
        pendingLabels.removeAll()
        onRemoteChange = nil
        bridgeLog.infoCapture("StoreRemoteChangeBridge stopped", category: "remote-change")
    }

    private func noteReceipt(_ label: String) {
        // Guard against a receipt whose Task was already in flight when
        // stop() ran — the observation is gone but the hop may still land.
        guard isRunning else { return }
        // Trace point 1 (mutation, remote): the signal that rows changed under
        // us. The writing process logged the actual mutation on its side.
        bridgeLog.infoCapture("remote store change signal: \(label)", category: "remote-change")
        pendingLabels.append(label)
        guard pendingTask == nil else { return }  // window already open → coalesce
        let window = debounce
        pendingTask = Task { @MainActor [weak self] in
            // Single sleep, not a loop — cancellation (from stop()) works.
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        pendingTask = nil
        guard !pendingLabels.isEmpty, let onRemoteChange else { return }
        let summary = Self.summarize(pendingLabels)
        pendingLabels.removeAll()
        firedCount += 1
        onRemoteChange(summary)
    }

    /// "a, a, b" → "a ×2, b" — keeps the per-window log line short under bursts.
    static func summarize(_ labels: [String]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for label in labels {
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        return order.map { label in
            let n = counts[label] ?? 1
            return n > 1 ? "\(label) ×\(n)" : label
        }.joined(separator: ", ")
    }
}
