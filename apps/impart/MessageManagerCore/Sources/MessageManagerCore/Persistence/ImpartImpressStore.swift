//
//  ImpartImpressStore.swift
//  MessageManagerCore
//
//  Async store gateway for impart. Parallels `ImbibImpressStore` and
//  `ImprintImpressStore`. This is the new door that impart's future
//  views and services will migrate towards — async-only, runs on the
//  gateway actor's background executor, publishes typed `StoreEvent`s.
//
//  ## Relationship to `ImpartStoreAdapter`
//
//  - `ImpartStoreAdapter` stays as the @MainActor, @Observable facade
//    that impart's existing SwiftUI views already use for `dataVersion`
//    and the write API (`storeEmailMessage`, etc.).
//  - `ImpartImpressStore` is the NEW door for async, off-main reads
//    and for publishing typed `StoreEvent`s to snapshot maintainers.
//  - The gateway opens its own `SharedStore` handle pointing at the
//    same SQLite file the adapter uses — WAL mode coordinates them.
//
//  ## Status
//
//  Scaffold: the event publisher and the `postMutation(...)` hook are
//  wired and tested. Read methods are TODO stubs — impart is still in
//  the scaffolding phase per the impart CLAUDE.md, so the schemas
//  (`email-message@1.0.0`, `chat-message@1.0.0`) are still in flux.
//  When impart's IMAP sync + threading lands, the read methods fill
//  in following the imprint template (`listMessagesForThread`,
//  `loadMessage`, `listThreadIDs`).
//

import Foundation
import ImpressLogging
import ImpressStoreKit
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif
import ImpressKit
import OSLog

private let gatewayLog = Logger(subsystem: "com.impart.app", category: "impress-store")

/// Async gateway to impart's store.
public actor ImpartImpressStore {

    // MARK: - Singleton

    public static let shared = ImpartImpressStore()

    // MARK: - Event publisher

    /// Fan-out point for mutation notifications. `ImpartStoreAdapter.didMutate()`
    /// calls `postMutation(...)` from its main-actor context.
    public nonisolated let events = StoreEventPublisher()

    // MARK: - Shared store handle

    #if canImport(ImpressRustCore)
    nonisolated(unsafe) private var _store: SharedStore?
    nonisolated(unsafe) private var storeOpenAttempted = false
    private let storeLock = NSLock()

    nonisolated private func handle() -> SharedStore? {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let s = _store { return s }
        if storeOpenAttempted { return nil }
        storeOpenAttempted = true
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let path = SharedWorkspace.databaseURL.path
            let s = try SharedStore.open(path: path)
            _store = s
            gatewayLog.infoCapture(
                "ImpartImpressStore: opened SharedStore at \(path)",
                category: "impress-store"
            )
            return s
        } catch {
            gatewayLog.errorCapture(
                "ImpartImpressStore: failed to open SharedStore — \(error.localizedDescription)",
                category: "impress-store"
            )
            return nil
        }
    }
    #endif

    // MARK: - Init

    public init() {}

    #if canImport(ImpressRustCore)
    /// Test-only constructor for injecting an in-memory SharedStore.
    public init(testStore: SharedStore) {
        self._store = testStore
        self.storeOpenAttempted = true
    }
    #endif

    // MARK: - Event fan-in

    /// Called from `ImpartStoreAdapter.didMutate()` after any mutation.
    public nonisolated func postMutation(
        structural: Bool = true,
        affectedIDs: Set<UUID>? = nil,
        kind: MutationKind? = nil
    ) {
        if structural {
            events.emit(.structural)
        } else if let kind, let ids = affectedIDs, !ids.isEmpty {
            events.emit(.itemsMutated(kind: kind, ids: ids))
        } else {
            events.emit(.structural)
        }
    }

    // MARK: - Read API (TODO — filled in when impart schemas stabilize)
    //
    // Pattern to follow once the schemas are final:
    //
    //     public nonisolated func loadMessage(id: UUID) -> ImpartMessage? {
    //         StoreTimings.shared.measure("ImpartImpressStore.loadMessage") {
    //             guard let store = handle() else { return nil }
    //             do {
    //                 guard let row = try store.getItem(id: id.uuidString) else { return nil }
    //                 return ImpartMessage(row: row)
    //             } catch {
    //                 gatewayLog.errorCapture("loadMessage failed: \(error.localizedDescription)", category: "impress-store")
    //                 return nil
    //             }
    //         }
    //     }
    //
    //     public nonisolated func listMessagesForThread(threadID: UUID) -> [ImpartMessage] { ... }
    //     public nonisolated func listRecentMessages(limit: UInt32) -> [ImpartMessage] { ... }
    //     public nonisolated func listThreadIDs() -> Set<UUID> { ... }
    //
    // The imprint template (`apps/imprint/Packages/ImprintCore/Sources/ImprintCore/ImprintImpressStore.swift`)
    // shows the full pattern including StoreTimings instrumentation,
    // JSON payload parsing via an `init?(row:)` extension, and a
    // client-side filter when SharedStore.queryBySchema lacks a
    // per-payload-field predicate.
}
