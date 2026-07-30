//
//  PublicationDetailLifecycle.swift
//  PublicationManagerCore
//
//  Stage 5b (SPLIT rule) — the three things every publication detail SHELL does
//  regardless of how it renders tabs.
//
//  macOS `DetailView` and iOS `DetailView` (imbib-iOS) are two designs — a
//  `switch` inside an `HSplitView` whose tab picker lives in the window
//  toolbar, versus a `TabView` with a tab bar and a navigation bar. What they
//  are NOT two of is this:
//
//  1. **Auto-mark-as-read** after a one-second dwell (Apple Mail behaviour).
//  2. **Recent-view recording** after a one-second dwell, so arrow-key
//     scrubbing through a list does not fill Recent with papers the user
//     merely passed over.
//  3. **Live refresh** — one `ImbibImpressStore.events` subscription, reloading
//     only when the focused publication is among the mutated ids (enrichment
//     filling in an abstract, a flag set from another surface).
//
//  All three were written out twice, with the same comments, including the
//  reasoning for the one-second dwell. The dwell durations had already drifted
//  in spirit if not in value: macOS's comment says "Wait 2 seconds" above a
//  one-second sleep.
//
//  The store WRITE is injected rather than hardcoded: macOS routes read-state
//  through `LibraryViewModel` (whose `store` is a protocol the app may swap in
//  tests), iOS calls `RustStoreAdapter.shared` directly. Unifying the write
//  itself would silently re-point macOS at a different store handle, which is
//  not what this pass is for.
//

import SwiftUI

extension View {

    /// The shell behaviour shared by both publication detail panes.
    ///
    /// - Parameters:
    ///   - publicationID: the focused paper, or `nil` for none. Every task is
    ///     keyed on it, so changing papers cancels the pending dwells.
    ///   - isRead: read state, re-evaluated AFTER the dwell — the paper may not
    ///     be loaded yet when the task starts.
    ///   - dwell: how long the paper must stay selected. One second on both
    ///     platforms.
    ///   - markAsRead: the read-state write, injected (see the file comment).
    ///   - reload: re-read the paper from the store.
    public func publicationDetailLifecycle(
        publicationID: UUID?,
        isRead: @escaping () -> Bool?,
        dwell: Duration = .seconds(1),
        markAsRead: @escaping @MainActor (UUID) async -> Void,
        reload: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(
            PublicationDetailLifecycleModifier(
                publicationID: publicationID, isRead: isRead, dwell: dwell,
                markAsRead: markAsRead, reload: reload))
    }
}

private struct PublicationDetailLifecycleModifier: ViewModifier {

    let publicationID: UUID?
    let isRead: () -> Bool?
    let dwell: Duration
    let markAsRead: @MainActor (UUID) async -> Void
    let reload: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: publicationID) {
                // Auto-mark as read after the dwell (Apple Mail style).
                guard let id = publicationID else { return }
                try? await Task.sleep(for: dwell)
                guard !Task.isCancelled else { return }
                // Re-check: the paper may have loaded (or been deleted) during
                // the sleep. `nil` means "not loaded", not "unread".
                guard let read = isRead(), read == false else { return }
                await markAsRead(id)
                reload()
            }
            .task(id: publicationID) {
                // Opening a paper is a user-initiated view — it belongs in
                // Recent. (Automated ingest paths must never record activity.)
                // The dwell keeps rapid scrubbing out of Recent; the task is
                // cancelled as soon as the selection changes.
                guard let id = publicationID else { return }
                try? await Task.sleep(for: dwell)
                guard !Task.isCancelled else { return }
                RustStoreAdapter.shared.recordRecentView(id: id)
            }
            .task(id: publicationID) {
                // Keep the OPEN detail in sync with background mutations.
                // Without this the pane loaded once and went stale until
                // re-navigation.
                guard let id = publicationID else { return }
                for await event in ImbibImpressStore.shared.events.subscribe() {
                    guard case .itemsMutated(_, let ids) = event, ids.contains(id)
                    else { continue }
                    reload()
                }
            }
    }
}
