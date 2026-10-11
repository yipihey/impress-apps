//
//  RustStoreWarmup.swift
//  PublicationManagerCore
//
//  The shared-store open can block on a TCC prompt or a WAL lock. Both
//  platforms force that open off the main actor before a generated surface
//  reads it. The helper used to live in the macOS chassis root, which left
//  the iOS settings pane with no way to warm the same store.
//

import Foundation

extension RustStoreAdapter {

    /// Force the shared-store open onto a background thread and await completion.
    ///
    /// `RustStoreAdapter.shared` is a `nonisolated(unsafe) static let`; forcing
    /// its lazy init on a detached task runs the blocking `open()` there, not on
    /// main. Removing this is how imprint's launch hung on a TCC prompt.
    public static func warmOffMain() async {
        await Task.detached(priority: .userInitiated) {
            _ = RustStoreAdapter.shared
        }.value
    }
}
