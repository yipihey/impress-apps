//
//  ManuscriptLibraryGate.swift
//  imprint
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

/// Gate for the project-browser window: shows a lightweight loading state until
/// the shared store is open, then the real library. `ManuscriptLibraryView` is
/// only constructed once ready, so its `= ManuscriptStoreAdapter.shared` stored
/// property never blocks the main thread.
struct ManuscriptLibraryGate: View {
    private let loader = ManuscriptWorkspaceLoader.shared

    var body: some View {
        Group {
            if loader.isReady {
                ManuscriptLibraryView()
            } else {
                loadingView
                    .onAppear { loader.begin() }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Opening workspace…")
                .font(.headline)
            Text("If macOS asks to allow access to data from other apps, click Allow.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
