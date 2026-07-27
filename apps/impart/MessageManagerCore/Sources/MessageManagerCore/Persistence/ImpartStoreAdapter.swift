//
//  ImpartStoreAdapter.swift
//  MessageManagerCore
//
//  Adapter for storing impart mail data in the shared impress-core SQLite
//  store (GUI unification Stage 0 WP3).
//
//  Mail rows use deterministic UUIDv5 ids (see `DeterministicID`) so
//  dual-writes, backfill re-runs, and cross-process writers converge on the
//  same store rows. The hierarchy is mirrored on the item envelope:
//
//      email-message.parent = mail-folder item
//      mail-folder.parent   = mail-account item
//
//  Two types share this file:
//
//  - `MailStoreMirror` — nonisolated engine owning the store handle and the
//    gated write path. `SyncService` (an actor) and `ImpartStoreBackfill`
//    call it directly without crossing the main actor.
//  - `ImpartStoreAdapter` — the @MainActor, @Observable facade impart's
//    SwiftUI views already observe (`dataVersion`, `isReady`).
//
//  ## Startup invariant (CLAUDE.md)
//
//  No store mutations may happen in the first 90 seconds after launch.
//  All write entry points funnel through `MailStoreMirror.dispatch(ops:)`,
//  which buffers operations during the grace window and flushes them (in
//  order, batched ≤500 rows per transaction) once the window has passed.
//  Live dual-writes after the window apply immediately via `upsertItemV2`.
//
//  ## Sync exclusion
//
//  Mail schemas are excluded from the CloudKit outbox at store open —
//  IMAP is mail's own sync protocol, so CloudKit re-sync would be redundant.
//

import Foundation
import OSLog
import ImpressKit
import ImpressLogging
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - MailItemUpsert

/// Sendable mirror of the FFI `SharedItemUpsert` row, so mapped rows can
/// cross actor boundaries (Core Data background context → mirror/backfill)
/// without importing UniFFI types into every signature.
public struct MailItemUpsert: Sendable, Equatable {
    public var id: String
    public var schemaRef: String
    public var payloadJson: String
    public var parentId: String?
    public var tags: [String]
    public var createdMs: Int64?
    public var isRead: Bool?
    public var isStarred: Bool?

    public init(
        id: String,
        schemaRef: String,
        payloadJson: String,
        parentId: String? = nil,
        tags: [String] = [],
        createdMs: Int64? = nil,
        isRead: Bool? = nil,
        isStarred: Bool? = nil
    ) {
        self.id = id
        self.schemaRef = schemaRef
        self.payloadJson = payloadJson
        self.parentId = parentId
        self.tags = tags
        self.createdMs = createdMs
        self.isRead = isRead
        self.isStarred = isStarred
    }

    #if canImport(ImpressRustCore)
    /// Convert to the FFI row type at the write site.
    var shared: SharedItemUpsert {
        SharedItemUpsert(
            id: id,
            schemaRef: schemaRef,
            payloadJson: payloadJson,
            parentId: parentId,
            tags: tags,
            createdMs: createdMs,
            isRead: isRead,
            isStarred: isStarred
        )
    }
    #endif
}

// MARK: - Pending operations

/// A store mutation deferred by the startup-grace gate.
enum PendingStoreOp: Sendable {
    case upsert(MailItemUpsert)
    case setRead(id: String, read: Bool)
}

// MARK: - MailStoreMirror

/// Nonisolated dual-write engine for impart's unified-store rows.
///
/// Owns the shared store handle (lazily opened, lock-guarded) and enforces
/// the 90-second startup mutation embargo: operations dispatched during the
/// grace window are buffered and flushed in order once it passes.
public final class MailStoreMirror: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = MailStoreMirror()

    // MARK: - Constants

    /// Mail schemas never enter the CloudKit sync outbox — IMAP is mail's
    /// own sync protocol. Declared once at store open (idempotent).
    public static let mailSyncExcludedSchemas = [
        "email-message", "chat-message", "mail-account", "mail-folder"
    ]

    /// Startup invariant: no store mutations in the first 90 s after launch.
    public static let startupGraceSeconds: TimeInterval = 90

    /// Maximum rows per batched store transaction (WAL contention with
    /// impel-taskd's 5 s writes — keep transactions short).
    public static let maxBatchRows = 500

    // MARK: - State (lock-guarded)

    private let lock = NSLock()
    #if canImport(ImpressRustCore)
    private var _store: SharedStore?
    private var openAttempted = false
    #endif
    private var pendingOps: [PendingStoreOp] = []
    private var flushScheduled = false
    private let launchDate = Date()

    init() {}

    // MARK: - Store handle

    #if canImport(ImpressRustCore)
    /// Lazily open (or return) the shared store handle. Thread-safe.
    /// The first successful open also declares the mail schemas
    /// sync-excluded (idempotent; drains any queued outbox rows).
    public func storeHandle() -> SharedStore? {
        lock.lock()
        defer { lock.unlock() }
        if let store = _store { return store }
        if openAttempted { return nil }
        openAttempted = true
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let path = SharedWorkspace.databaseURL.path
            let store = try SharedStore.open(path: path)
            _store = store
            Logger.impartStore.infoCapture(
                "MailStoreMirror: opened SharedStore at \(path)",
                category: "store"
            )
            do {
                try store.addSyncExcludedSchemas(schemas: Self.mailSyncExcludedSchemas)
                Logger.impartStore.infoCapture(
                    "Mail schemas declared sync-excluded: \(Self.mailSyncExcludedSchemas.joined(separator: ", "))",
                    category: "store"
                )
            } catch {
                Logger.impartStore.errorCapture(
                    "addSyncExcludedSchemas failed: \(error)",
                    category: "store"
                )
            }
            return store
        } catch {
            Logger.impartStore.errorCapture(
                "MailStoreMirror: failed to open SharedStore — \(error.localizedDescription)",
                category: "store"
            )
            return nil
        }
    }

    /// Test-only: inject a preopened store (e.g. `SharedStore.openInMemory()`).
    func adopt(store: SharedStore) {
        lock.lock()
        _store = store
        openAttempted = true
        lock.unlock()
    }
    #endif

    // MARK: - Startup grace gate

    /// Whether the 90-second startup mutation embargo has elapsed.
    public var isPastStartupGrace: Bool {
        Date().timeIntervalSince(launchDate) >= Self.startupGraceSeconds
    }

    // MARK: - Write API

    /// Mirror mapped rows into the shared store, in array order — put
    /// account and folder rows before their children (parents upserted
    /// first). During the startup grace window the rows are buffered and
    /// flushed in one batch once the window passes.
    public func mirror(rows: [MailItemUpsert]) {
        dispatch(ops: rows.map(PendingStoreOp.upsert))
    }

    /// Mirror read-flag changes for messages already in the store.
    /// Unknown ids (not yet dual-written or backfilled) are skipped.
    public func setMessagesRead(itemIDs: [String], read: Bool) {
        dispatch(ops: itemIDs.map { .setRead(id: $0, read: read) })
    }

    // MARK: - Gated write path

    private func dispatch(ops: [PendingStoreOp]) {
        guard !ops.isEmpty else { return }
        if isPastStartupGrace {
            // Preserve ordering: drain anything still buffered from the
            // grace window before applying the new operations.
            flushPendingOps()
            apply(ops: ops, batched: false)
        } else {
            buffer(ops: ops)
        }
    }

    private func buffer(ops: [PendingStoreOp]) {
        lock.lock()
        pendingOps.append(contentsOf: ops)
        let pendingCount = pendingOps.count
        let needsSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()

        Logger.impartStore.infoCapture(
            "Startup grace: buffered \(ops.count) store ops (pending: \(pendingCount))",
            category: "store"
        )

        if needsSchedule {
            let remaining = max(0, Self.startupGraceSeconds - Date().timeIntervalSince(launchDate)) + 1
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self?.flushPendingOps()
            }
        }
    }

    /// Drain and apply all buffered operations (no-op when empty).
    private func flushPendingOps() {
        lock.lock()
        let ops = pendingOps
        pendingOps.removeAll()
        lock.unlock()
        guard !ops.isEmpty else { return }
        Logger.impartStore.infoCapture(
            "Startup grace over: flushing \(ops.count) buffered store ops",
            category: "store"
        )
        apply(ops: ops, batched: true)
    }

    /// Apply operations to the store. `batched: true` groups consecutive
    /// upserts into `upsertItems` transactions of ≤500 rows (grace-flush
    /// path); `batched: false` uses per-row `upsertItemV2` (live dual-write).
    private func apply(ops: [PendingStoreOp], batched: Bool) {
        #if canImport(ImpressRustCore)
        guard let store = storeHandle() else {
            Logger.impartStore.warningCapture(
                "MailStoreMirror: store not open — dropping \(ops.count) ops",
                category: "store"
            )
            return
        }

        var batch: [SharedItemUpsert] = []
        var applied = 0

        func flushBatch() {
            guard !batch.isEmpty else { return }
            do {
                let result = try store.upsertItems(rows: batch)
                applied += batch.count
                Logger.impartStore.infoCapture(
                    "upsertItems: \(batch.count) rows (inserted \(result.inserted), updated \(result.updated))",
                    category: "store"
                )
            } catch {
                Logger.impartStore.errorCapture(
                    "upsertItems failed for \(batch.count) rows — \(error)",
                    category: "store"
                )
            }
            batch.removeAll(keepingCapacity: true)
        }

        for op in ops {
            switch op {
            case .upsert(let row):
                if batched {
                    batch.append(row.shared)
                    if batch.count >= Self.maxBatchRows { flushBatch() }
                } else {
                    do {
                        try store.upsertItemV2(row: row.shared)
                        applied += 1
                    } catch {
                        Logger.impartStore.errorCapture(
                            "upsertItemV2 failed for \(row.id) — \(error)",
                            category: "store"
                        )
                    }
                }
            case .setRead(let id, let read):
                flushBatch()   // preserve op ordering across kinds
                do {
                    try store.setRead(id: id, isRead: read)
                    applied += 1
                } catch {
                    // NotFound is expected for messages not yet mirrored.
                    Logger.impartStore.infoCapture(
                        "setRead skipped for \(id) — \(error)",
                        category: "store"
                    )
                }
            }
        }
        flushBatch()

        if applied > 0 {
            Task { @MainActor in
                ImpartStoreAdapter.shared.didMutate()
            }
        }
        #endif
    }
}

// MARK: - ImpartStoreAdapter

/// @MainActor facade over `MailStoreMirror` for impart's SwiftUI views.
///
/// ## Usage
///
/// ```swift
/// // At app startup (MainActor)
/// ImpartStoreAdapter.shared.setup()
///
/// // From any isolation (e.g. SyncService) — gated on the startup clock:
/// MailStoreMirror.shared.mirror(rows: [accountRow, folderRow] + messageRows)
/// ```
@MainActor
@Observable
public final class ImpartStoreAdapter {

    // MARK: - Singleton

    /// Shared adapter instance.
    public static let shared = ImpartStoreAdapter()

    // MARK: - Observable state

    /// Bumped on every successful mutation. Observers can react to this.
    public private(set) var dataVersion: Int = 0

    /// Whether the adapter successfully opened the shared workspace.
    public private(set) var isReady: Bool = false

    // MARK: - Database path

    /// Absolute path to the shared impress-core SQLite database.
    ///
    /// All impress apps share this path via the `group.com.impress.suite`
    /// app group container (see `SharedWorkspace`).
    public nonisolated var databasePath: String {
        SharedWorkspace.databaseURL.path
    }

    // MARK: - Init

    private init() {}

    // MARK: - Setup

    /// Prepare the shared workspace, open the store handle, and declare
    /// the mail schemas sync-excluded (via `MailStoreMirror`).
    ///
    /// Call once at app startup (e.g., from `ImpartApp.init()`).
    /// Safe to call multiple times.
    public func setup() {
        #if canImport(ImpressRustCore)
        isReady = MailStoreMirror.shared.storeHandle() != nil
        #else
        do {
            try SharedWorkspace.ensureDirectoryExists()
            isReady = true
        } catch {
            isReady = false
        }
        #endif
        if isReady {
            Logger.impartStore.infoCapture(
                "ImpartStoreAdapter ready — db: \(databasePath)",
                category: "store"
            )
        } else {
            Logger.impartStore.errorCapture(
                "ImpartStoreAdapter setup failed — see MailStoreMirror logs",
                category: "store"
            )
        }
    }

    // MARK: - Mutation signalling

    /// Increment `dataVersion` to notify observers of a store change.
    /// Also fans out a `.structural` event on the `ImpartImpressStore`
    /// publisher so future snapshot maintainers can subscribe via the
    /// `ImpressStoreKit` stream without going through `NotificationCenter`.
    public func didMutate() {
        dataVersion += 1
        ImpartImpressStore.shared.postMutation(structural: true)
    }

    // MARK: - Email messages (single-message facade)

    /// Store an email message in the shared impress-core store.
    ///
    /// Builds an `email-message` row with a deterministic UUIDv5 id derived
    /// from `messageID` and routes it through the gated dual-write path.
    public func storeEmailMessage(
        messageID: String,
        subject: String,
        body: String,
        from: String,
        to: [String],
        cc: [String] = [],
        mailbox: String? = nil,
        threadID: String? = nil
    ) {
        guard isReady else {
            Logger.impartStore.warningCapture(
                "storeEmailMessage called before setup — skipping \(messageID)",
                category: "store"
            )
            return
        }

        let row = Self.emailMessageRow(
            messageID: messageID,
            fallbackURI: messageID,
            subject: subject,
            body: body,
            from: from,
            to: to,
            cc: cc,
            threadID: threadID,
            channel: mailbox
        )
        MailStoreMirror.shared.mirror(rows: [row])

        Logger.impartStore.infoCapture(
            "storeEmailMessage: queued \(messageID) → item \(row.id)",
            category: "store"
        )
    }

    // MARK: - Chat messages

    /// Store a chat/IM message in the shared impress-core store as a
    /// `chat-message` item with a deterministic UUIDv5 id.
    public func storeChatMessage(
        messageID: String,
        body: String,
        from: String,
        channel: String? = nil,
        threadID: String? = nil
    ) {
        guard isReady else {
            Logger.impartStore.warningCapture(
                "storeChatMessage called before setup — skipping \(messageID)",
                category: "store"
            )
            return
        }

        var payload: [String: Any] = ["body": body, "from": from]
        if let channel { payload["channel"] = channel }
        if let threadID { payload["thread_id"] = threadID }

        let row = MailItemUpsert(
            id: DeterministicID.itemID(for: messageID),
            schemaRef: "chat-message",
            payloadJson: Self.encodeJSON(payload)
        )
        MailStoreMirror.shared.mirror(rows: [row])

        Logger.impartStore.infoCapture(
            "storeChatMessage: queued \(messageID) → item \(row.id)",
            category: "store"
        )
    }

    // MARK: - Bulk sync

    /// Sync all messages from a mailbox into the shared store.
    ///
    /// Mirrors an `email-message` row for each message, with real message
    /// dates and read/star flags.
    ///
    /// - Parameters:
    ///   - messages: Messages to sync (from `MessageManagerCore.Message`).
    ///   - mailbox: Mailbox name these messages belong to.
    public func syncMessages(_ messages: [Message], mailbox: String) {
        guard isReady else { return }
        guard !messages.isEmpty else { return }

        Logger.impartStore.infoCapture(
            "syncMessages: \(messages.count) messages in '\(mailbox)'",
            category: "store"
        )

        let rows = messages.map { message in
            Self.emailMessageRow(
                messageID: message.messageId,
                fallbackURI: message.id.uuidString,
                subject: message.subject,
                body: message.snippet,    // snippet until full body is fetched
                from: message.from.first?.email ?? message.fromDisplayString,
                to: message.to.map(\.email),
                cc: message.cc.map(\.email),
                threadID: nil,
                channel: mailbox,
                date: message.date,
                isRead: message.isRead,
                isStarred: message.isStarred
            )
        }
        MailStoreMirror.shared.mirror(rows: rows)
    }

    // MARK: - Row mapping (pure, testable)

    /// Row for a `mail-account` item. Deterministic id from the account
    /// address (fallback: display name).
    public nonisolated static func accountRow(
        email: String,
        displayName: String,
        provider: String? = nil,
        sortOrder: Int? = nil
    ) -> MailItemUpsert {
        var payload: [String: Any] = [
            "name": displayName.isEmpty ? email : displayName,
            "address": email
        ]
        if let provider { payload["provider"] = provider }
        if let sortOrder { payload["sort_order"] = sortOrder }
        return MailItemUpsert(
            id: DeterministicID.accountItemID(address: email, name: displayName),
            schemaRef: "mail-account",
            payloadJson: encodeJSON(payload)
        )
    }

    /// Row for a `mail-folder` item, parented to its account row.
    /// Deterministic id from `"<account>/<remote path or name>"`.
    public nonisolated static func folderRow(
        accountEmail: String,
        name: String,
        remotePath: String,
        role: String? = nil,
        sortOrder: Int? = nil
    ) -> MailItemUpsert {
        var payload: [String: Any] = ["name": name]
        if !remotePath.isEmpty { payload["remote_path"] = remotePath }
        if let role = storeFolderRole(role) { payload["role"] = role }
        if let sortOrder { payload["sort_order"] = sortOrder }
        return MailItemUpsert(
            id: DeterministicID.folderItemID(
                accountKey: accountEmail, remotePath: remotePath, name: name
            ),
            schemaRef: "mail-folder",
            payloadJson: encodeJSON(payload),
            parentId: DeterministicID.accountItemID(address: accountEmail)
        )
    }

    /// Row for an `email-message` item. Deterministic id from the RFC-822
    /// Message-ID (fallback: `fallbackURI`, e.g. the Core Data objectID
    /// URI). When account + folder context is provided the row is parented
    /// to its folder item; `createdMs` carries the REAL message date so
    /// mail sorts correctly.
    public nonisolated static func emailMessageRow(
        messageID: String?,
        fallbackURI: String,
        subject: String,
        body: String,
        from: String,
        to: [String],
        cc: [String],
        threadID: String? = nil,
        channel: String? = nil,
        accountEmail: String? = nil,
        folderPath: String? = nil,
        folderName: String? = nil,
        date: Date? = nil,
        isRead: Bool? = nil,
        isStarred: Bool? = nil
    ) -> MailItemUpsert {
        var payload: [String: Any] = [
            "subject": subject,
            "body": body,
            "from": from
        ]
        if !to.isEmpty { payload["to"] = to }
        if !cc.isEmpty { payload["cc"] = cc }
        if let messageID, !messageID.isEmpty { payload["message_id"] = messageID }
        if let threadID, !threadID.isEmpty { payload["thread_id"] = threadID }
        if let channel, !channel.isEmpty { payload["channel"] = channel }

        var parentId: String?
        if let accountEmail, !accountEmail.isEmpty {
            parentId = DeterministicID.folderItemID(
                accountKey: accountEmail,
                remotePath: folderPath ?? "",
                name: folderName ?? ""
            )
        }

        return MailItemUpsert(
            id: DeterministicID.messageItemID(messageID: messageID, fallbackURI: fallbackURI),
            schemaRef: "email-message",
            payloadJson: encodeJSON(payload),
            parentId: parentId,
            createdMs: date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
            isRead: isRead,
            isStarred: isStarred
        )
    }

    /// Row for an `email-message` item built from a `CDMessage`.
    ///
    /// Must be called on the message's managed-object-context queue
    /// (e.g. inside `performBackgroundTask`).
    public nonisolated static func messageRow(from message: CDMessage) -> MailItemUpsert {
        let folder = message.folder
        let account = folder?.account
        return emailMessageRow(
            messageID: message.messageId,
            fallbackURI: message.objectID.uriRepresentation().absoluteString,
            subject: message.subject,
            body: message.content?.textBody ?? message.snippet,
            from: message.fromAddresses.first?.email ?? message.fromDisplayString,
            to: message.toAddresses.map(\.email),
            cc: message.ccAddresses.map(\.email),
            threadID: message.thread?.id.uuidString.lowercased(),
            channel: folder?.name,
            accountEmail: account?.email,
            folderPath: folder?.fullPath,
            folderName: folder?.name,
            date: message.date,
            isRead: message.isRead,
            isStarred: message.isStarred
        )
    }

    /// Map an app folder role raw value onto the `mail-folder` schema's
    /// role vocabulary (inbox|sent|drafts|trash|archive|spam); unknown or
    /// custom roles are omitted.
    public nonisolated static func storeFolderRole(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        let known: Set<String> = ["inbox", "sent", "drafts", "trash", "archive", "spam"]
        return known.contains(raw) ? raw : nil
    }

    private nonisolated static func encodeJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

// Note: Logger.impartStore is declared in Logger+Extensions.swift
