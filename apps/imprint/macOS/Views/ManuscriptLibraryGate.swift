//
//  ManuscriptLibraryGate.swift
//  imprint
//
//  Stage 4a (declarative-chassis campaign): the `ManuscriptLibraryGate` view
//  that named this file was deleted. It was the `#else` arm of the
//  `project-browser` scene in Shared/ImprintApp.swift — but that whole file is
//  `#if os(macOS)` end-to-end, and the iOS target compiles `Shared` +
//  `imprint-iOS` only (never `macOS/`), so the arm was compiled by no target.
//  iOS ships `IOSManuscriptLibraryView` from its own `@main`
//  (imprint-iOS/ImprintIOSApp.swift); macOS lands on `ImprintChassisRoot`.
//
//  `ManuscriptWorkspaceLoader` below is LIVE and stays — ImprintApp's launch
//  sequence gates four store-touching tasks on it. The filename is now a
//  misnomer; renaming it is left to a follow-up so this stays a pure deletion.
//
//  Opens the shared manuscript store OFF the main thread so app launch never
//  blocks on it. `ManuscriptStoreAdapter.shared` opens the App Group store,
//  which on macOS can raise a "wants to access data from other apps" TCC prompt
//  (the shared container holds data written by sibling apps) — the `open()`
//  syscall blocks on that prompt. Touching `.shared` for the first time from a
//  background task means that block happens off-main: the window appears (in a
//  loading state), the automation server starts, and any TCC prompt shows over
//  a visible, running app instead of freezing launch.
//

import SwiftUI

/// Warms `ManuscriptStoreAdapter.shared` on a background thread and publishes
/// readiness. The first `.shared` access triggers the (potentially blocking)
/// store open; doing it here keeps it off the main thread.
@MainActor
@Observable
final class ManuscriptWorkspaceLoader {
    static let shared = ManuscriptWorkspaceLoader()

    private(set) var isReady = false
    private var started = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// Idempotently kick off the store open on a detached task.
    func begin() {
        guard !started, !isReady else { return }
        started = true
        Task.detached(priority: .userInitiated) {
            // Forcing the lazy `static let` here runs its blocking init on this
            // background thread rather than on whoever touches it first on main.
            _ = ManuscriptStoreAdapter.shared
            await MainActor.run { self.markReady() }
        }
    }

    /// Suspend (without blocking the main thread) until the shared store is
    /// open. Launch-time work that touches the store should `await` this so it
    /// runs only once the store is ready — the window can appear meanwhile.
    func whenReady() async {
        if isReady { return }
        begin()
        await withCheckedContinuation { continuations.append($0) }
    }

    private func markReady() {
        isReady = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
