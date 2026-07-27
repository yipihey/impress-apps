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
//  Stage 0 WP3: the read API is real (`loadMessage`,
//  `listMessagesForThread`, `listRecentMessages`, `listThreadIDs`,
//  `messageCount(inFolder:)`) but Core Data remains the GUI's source of
//  truth — callers branch on `ImpartImpressStore.useUnifiedStoreReads`
//  (UserDefaults flag, default false). Rewiring the list views onto
//  these reads is Stage 2.
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

    // MARK: - Unified-reads flag

    /// UserDefaults key for the Stage 0 read flag.
    public static let unifiedReadsFlagKey = "useUnifiedStoreReads"

    /// When `true`, callers that can serve reads from the unified store
    /// should do so; when `false` (the default) Core Data remains the
    /// GUI's source of truth. Stage 0 only makes the read API real —
    /// list views branch on this in Stage 2.
    public nonisolated static var useUnifiedStoreReads: Bool {
        UserDefaults.standard.bool(forKey: unifiedReadsFlagKey)
    }

    // MARK: - Read API

    #if canImport(ImpressRustCore)

    /// Fetch a single email message by its (deterministic) item UUID.
    /// Returns `nil` on unknown id, schema mismatch, malformed payload,
    /// or FFI error.
    public nonisolated func loadMessage(id: UUID) -> ImpartStoreMessage? {
        StoreTimings.shared.measure("ImpartImpressStore.loadMessage") {
            guard let store = handle() else { return nil }
            do {
                guard let row = try store.getItem(id: id.uuidString.lowercased()) else { return nil }
                return ImpartStoreMessage(row: row)
            } catch {
                gatewayLog.errorCapture(
                    "loadMessage(\(id)) failed: \(error.localizedDescription)",
                    category: "impress-store"
                )
                return nil
            }
        }
    }

    /// All messages sharing a `thread_id`, oldest first (by real message
    /// date — `createdMs` carries the RFC-822 date).
    public nonisolated func listMessagesForThread(threadID: String, limit: UInt32 = 1000) -> [ImpartStoreMessage] {
        StoreTimings.shared.measure("ImpartImpressStore.listMessagesForThread") {
            guard let store = handle() else { return [] }
            do {
                let rows = try store.queryItems(query: SharedItemQuery(
                    schemaRef: "email-message",
                    parentId: nil,
                    payloadEq: [SharedFieldEq(field: "thread_id", valueJson: Self.jsonString(threadID))],
                    modifiedAfterMs: nil,
                    sortField: "created",
                    ascending: true,
                    limit: limit,
                    offset: 0
                ))
                return rows.compactMap { ImpartStoreMessage(row: $0) }
            } catch {
                gatewayLog.errorCapture(
                    "listMessagesForThread(\(threadID)) failed: \(error.localizedDescription)",
                    category: "impress-store"
                )
                return []
            }
        }
    }

    /// Most recent messages across all folders, newest first by real
    /// message date.
    public nonisolated func listRecentMessages(limit: UInt32 = 100) -> [ImpartStoreMessage] {
        StoreTimings.shared.measure("ImpartImpressStore.listRecentMessages") {
            guard let store = handle() else { return [] }
            do {
                let rows = try store.queryItems(query: SharedItemQuery(
                    schemaRef: "email-message",
                    parentId: nil,
                    payloadEq: [],
                    modifiedAfterMs: nil,
                    sortField: "created",
                    ascending: false,
                    limit: limit,
                    offset: 0
                ))
                return rows.compactMap { ImpartStoreMessage(row: $0) }
            } catch {
                gatewayLog.errorCapture(
                    "listRecentMessages failed: \(error.localizedDescription)",
                    category: "impress-store"
                )
                return []
            }
        }
    }

    /// Distinct `thread_id` values seen across all email messages.
    /// Pages the schema listing in chunks of 500.
    public nonisolated func listThreadIDs() -> Set<String> {
        StoreTimings.shared.measure("ImpartImpressStore.listThreadIDs") {
            guard let store = handle() else { return [] }
            var seen = Set<String>()
            var offset: UInt32 = 0
            let page: UInt32 = 500
            while true {
                do {
                    let rows = try store.queryItems(query: SharedItemQuery(
                        schemaRef: "email-message",
                        parentId: nil,
                        payloadEq: [],
                        modifiedAfterMs: nil,
                        sortField: "created",
                        ascending: true,
                        limit: page,
                        offset: offset
                    ))
                    for row in rows {
                        if let threadID = ImpartStoreMessage(row: row)?.threadID {
                            seen.insert(threadID)
                        }
                    }
                    if rows.count < Int(page) { break }
                    offset += page
                } catch {
                    gatewayLog.errorCapture(
                        "listThreadIDs failed at offset \(offset): \(error.localizedDescription)",
                        category: "impress-store"
                    )
                    break
                }
            }
            return seen
        }
    }

    /// Count of email messages parented to the given folder item.
    public nonisolated func messageCount(inFolder folderID: UUID) -> Int {
        StoreTimings.shared.measure("ImpartImpressStore.messageCount") {
            guard let store = handle() else { return 0 }
            do {
                let count = try store.countItems(query: SharedItemQuery(
                    schemaRef: "email-message",
                    parentId: folderID.uuidString.lowercased(),
                    payloadEq: [],
                    modifiedAfterMs: nil,
                    sortField: "",
                    ascending: false,
                    limit: 0,
                    offset: 0
                ))
                return Int(count)
            } catch {
                gatewayLog.errorCapture(
                    "messageCount(inFolder: \(folderID)) failed: \(error.localizedDescription)",
                    category: "impress-store"
                )
                return 0
            }
        }
    }

    /// Encode a Swift string as a JSON scalar for `SharedFieldEq.valueJson`.
    private nonisolated static func jsonString(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let array = String(data: data, encoding: .utf8),
           array.count >= 2 {
            return String(array.dropFirst().dropLast())
        }
        return "\"\(value)\""
    }

    #endif
}

// MARK: - ImpartStoreMessage

/// A parsed `email-message` row from the unified store.
public struct ImpartStoreMessage: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let subject: String
    public let body: String
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let messageID: String?
    public let threadID: String?
    /// Real message date (`createdMs` on the envelope).
    public let date: Date
    public let modified: Date
    /// Folder item id (envelope parent), if the row is parented.
    public let folderItemID: UUID?
    public let isRead: Bool
    public let isStarred: Bool
}

#if canImport(ImpressRustCore)
extension ImpartStoreMessage {
    /// Parse a `SharedItemRow`. Returns `nil` for non-email schemas or
    /// malformed ids/payloads.
    init?(row: SharedItemRow) {
        guard row.schemaRef.hasPrefix("email-message") else { return nil }
        guard let id = UUID(uuidString: row.id) else { return nil }
        guard let data = row.payloadJson.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        self.id = id
        self.subject = payload["subject"] as? String ?? ""
        self.body = payload["body"] as? String ?? ""
        self.from = payload["from"] as? String ?? ""
        self.to = payload["to"] as? [String] ?? []
        self.cc = payload["cc"] as? [String] ?? []
        self.messageID = payload["message_id"] as? String
        self.threadID = payload["thread_id"] as? String
        self.date = Date(timeIntervalSince1970: Double(row.createdMs) / 1000)
        self.modified = Date(timeIntervalSince1970: Double(row.modifiedMs) / 1000)
        self.folderItemID = row.parentId.flatMap(UUID.init(uuidString:))
        self.isRead = row.isRead
        self.isStarred = row.isStarred
    }
}
#endif
