//
//  StoreMutationObserver.swift
//  PublicationManagerCore
//
//  Cross-process receive half of the store event bus.
//
//  The Rust store (impress-core `sqlite_store`) posts a throttled Darwin
//  notification after every mutation — `STORE_MUTATED_DARWIN_NOTE`,
//  "com.impress.suite.store.mutated" — because in-process subscribers can
//  never see a write made by ANOTHER process. Before this observer existed,
//  reviews and tasks created by impel-taskd surfaced in imbib only after an
//  unrelated local mutation or a relaunch: the review-queue section (gated
//  on a pending count that nothing refreshed) simply never appeared.
//
//  Receiving pulls, payload-free: the note carries no data, we bump
//  `RustStoreAdapter.noteExternalMutation()` (the documented public lever —
//  dataVersion, sidebar snapshot maintainer, and every `.onChange` view
//  flow from it) with trailing-edge coalescing so a daemon spawn burst
//  costs one refresh, not one per write.
//

import Foundation
import ImpressLogging
import OSLog

public final class StoreMutationObserver {

    public static let shared = StoreMutationObserver()

    /// The Darwin notification name the Rust store posts (keep in sync with
    /// impress-core `STORE_MUTATED_DARWIN_NOTE`).
    static let noteName = "com.impress.suite.store.mutated" as CFString

    /// Trailing-edge coalescing window for bursts.
    private static let coalesceInterval: TimeInterval = 0.75

    /// CLAUDE.md startup-settling guard: background-triggered mutation
    /// fan-out must not run during the first ~90 s of launch, or SwiftUI
    /// re-evaluation compounds into a render loop.
    private static let startupGrace: TimeInterval = 90

    private var started = false
    private var refreshScheduled = false

    private init() {}

    /// Begin observing (idempotent). Call once at app startup; delivery of
    /// the first refresh is deferred past the startup-settling window.
    public func start() {
        guard !started else { return }
        started = true
        _ = Self.launchUptime // anchor the settling window at first start
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let this = Unmanaged<StoreMutationObserver>.fromOpaque(observer)
                    .takeUnretainedValue()
                this.scheduleRefresh()
            },
            Self.noteName,
            nil,
            .deliverImmediately
        )
        Logger.library.infoCapture(
            "StoreMutationObserver observing \(Self.noteName)", category: "store")
    }

    private func scheduleRefresh() {
        DispatchQueue.main.async { [self] in
            guard !refreshScheduled else { return }
            refreshScheduled = true
            let sinceLaunch = ProcessInfo.processInfo.systemUptime - Self.launchUptime
            let delay = max(Self.coalesceInterval, Self.startupGrace - sinceLaunch)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                refreshScheduled = false
                Logger.library.infoCapture(
                    "Cross-process store mutation → noteExternalMutation", category: "store")
                MainActor.assumeIsolated {
                    RustStoreAdapter.shared.noteExternalMutation(structural: true)
                }
            }
        }
    }

    private static let launchUptime = ProcessInfo.processInfo.systemUptime
}
