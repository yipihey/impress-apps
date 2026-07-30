// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a read-only
// `SharedStore` reader (Foundation + ImpressRustCore). While it was gated iOS
// could not read mail from the shared store AT ALL.
//
//  MailStoreReader.swift
//  PublicationManagerCore
//
//  Stage 2-A (ADR-0021): store access for the Mail section. Mail rows —
//  `mail-account` / `mail-folder` / `email-message` — live in the SHARED
//  impress store (written by impart's Stage-0 mirror/backfill in
//  MessageManagerCore), but the chassis cannot depend on MessageManagerCore
//  (PMC ships to every app). So this reader clones the FigureStoreReader
//  pattern: its own `SharedStore` handle on the same database, flat
//  `queryItems`/`countItems` reads only.
//
//  Scope discipline — READ-ONLY by design: mail's lifecycle (moves, deletes,
//  folder CRUD, read-state sync) is IMAP-owned and flows through impart's
//  MessageManagerCore, never through envelope mutations here. The only store
//  mutations the Mail chassis performs are the generic star/flag/tag ops via
//  `RustStoreAdapter.shared` (undo + StoreEvent fan-out preserved).
//

import Foundation
import ImpressKit
import ImpressRustCore
import OSLog

/// Decoded `email-message@…` payload fields (defensive: Stage-0 rows omit
/// empty arrays and optional ids).
struct MailMessagePayload: Decodable {
    var subject: String?
    var body: String?
    var from: String?
    var to: [String]?
    var cc: [String]?
    var messageID: String?
    var threadID: String?

    enum CodingKeys: String, CodingKey {
        case subject, body, from, to, cc
        case messageID = "message_id"
        case threadID = "thread_id"
    }
}

/// Decoded `mail-folder@…` payload fields.
struct MailFolderPayload: Decodable {
    var name: String?
    /// inbox | sent | drafts | trash | archive | spam (custom folders omit it).
    var role: String?
    var remotePath: String?
    var sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case name, role
        case remotePath = "remote_path"
        case sortOrder = "sort_order"
    }
}

/// Decoded `mail-account@…` payload fields.
struct MailAccountPayload: Decodable {
    var name: String?
    var address: String?
    var provider: String?
    var sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case name, address, provider
        case sortOrder = "sort_order"
    }
}

@MainActor
public final class MailStoreReader {

    public static let shared = MailStoreReader()

    private static let logger = Logger(subsystem: "com.imbib.app", category: "mail")

    private var store: SharedStore?

    private init() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            store = try SharedStore.open(path: SharedWorkspace.databasePath)
        } catch {
            Self.logger.error("MailStoreReader failed to open shared store: \(error)")
        }
    }

    public var isReady: Bool { store != nil }

    // MARK: - Reads

    /// All mail accounts, sorted by payload sort_order.
    public func fetchAccounts() -> [SharedItemRow] {
        guard let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "mail-account", parentId: nil, payloadEq: [],
            modifiedAfterMs: nil, sortField: "payload.sort_order",
            ascending: true, limit: 100, offset: 0))) ?? []
    }

    /// Mail folders, optionally scoped to one account (envelope parent);
    /// `nil` returns folders across all accounts.
    public func fetchFolders(accountID: String? = nil) -> [SharedItemRow] {
        guard let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "mail-folder", parentId: accountID?.lowercased(), payloadEq: [],
            modifiedAfterMs: nil, sortField: "payload.sort_order",
            ascending: true, limit: 1000, offset: 0))) ?? []
    }

    /// All folders with the inbox role, across every account (the fan-out
    /// source for the "All Inboxes" scope — fine at Stage-2 account counts).
    public func fetchInboxFolders() -> [SharedItemRow] {
        fetchFolders().filter { Self.folderPayload(from: $0)?.role == "inbox" }
    }

    /// Messages in one folder (envelope parentId filter, pushed to the
    /// store), newest first by REAL message date (`createdMs`, Stage 0-WP3).
    public func fetchMessages(inFolder folderID: String, limit: UInt32 = 5000) -> [SharedItemRow] {
        guard let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "email-message", parentId: folderID.lowercased(), payloadEq: [],
            modifiedAfterMs: nil, sortField: "created",
            ascending: false, limit: limit, offset: 0))) ?? []
    }

    /// Messages across all folders, newest first (flagged scope fan-in).
    public func fetchAllMessages(limit: UInt32 = 5000) -> [SharedItemRow] {
        guard let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "email-message", parentId: nil, payloadEq: [],
            modifiedAfterMs: nil, sortField: "created",
            ascending: false, limit: limit, offset: 0))) ?? []
    }

    /// One message row by store id.
    public func fetchMessage(id: String) -> SharedItemRow? {
        guard let store else { return nil }
        guard let row = try? store.getItem(id: id.lowercased()) else { return nil }
        // Schema refs may carry a version suffix ("email-message@1.0.0").
        guard row.schemaRef.hasPrefix("email-message")
            || row.schemaRef.hasPrefix("chat-message") else { return nil }
        return row
    }

    /// All messages sharing a payload `thread_id`, oldest first by real
    /// message date (the detail pane's thread view).
    public func fetchThread(threadID: String, limit: UInt32 = 1000) -> [SharedItemRow] {
        guard let store else { return [] }
        return (try? store.queryItems(query: SharedItemQuery(
            schemaRef: "email-message", parentId: nil,
            payloadEq: [SharedFieldEq(field: "thread_id", valueJson: Self.jsonString(threadID))],
            modifiedAfterMs: nil, sortField: "created",
            ascending: true, limit: limit, offset: 0))) ?? []
    }

    /// Count of messages parented to one folder (sidebar badges).
    public func messageCount(inFolder folderID: String) -> Int {
        guard let store else { return 0 }
        let count = (try? store.countItems(query: SharedItemQuery(
            schemaRef: "email-message", parentId: folderID.lowercased(), payloadEq: [],
            modifiedAfterMs: nil, sortField: "", ascending: false,
            limit: 0, offset: 0))) ?? 0
        return Int(count)
    }

    // MARK: - Scope resolution

    /// The rows one `MessageListScope` shows, thread-collapsed and newest-first.
    ///
    /// ADDITIVE (Stage 5c, flagged): this is `MessageListWrapper.reload()`'s
    /// body, lifted verbatim out of the macOS-gated list wrapper. It had to move
    /// because impart-iOS needs the same answer and the wrapper is AppKit-adjacent
    /// — and "which messages does All Inboxes contain" is not a rendering
    /// question. The fan-out rules (folder = envelope parent, account = its
    /// inbox-role folder, allInboxes = every inbox-role folder merged, flagged =
    /// colour filter over all messages) were the one part of the mail surface
    /// still spelled once per platform; now both list hosts call this.
    public func messages(in scope: MessageListScope, limit: UInt32 = 5000) -> [MessageRowData] {
        let fetched: [SharedItemRow]
        switch scope {
        case .folder(let id):
            // Folder scope = envelope parentId filter, pushed to the store.
            fetched = fetchMessages(inFolder: id.uuidString.lowercased(), limit: limit)
        case .account(let id):
            // v1: an account node lists its inbox-role folder. Sent/Drafts/…
            // are one click away as child folder nodes.
            let folders = fetchFolders(accountID: id.uuidString.lowercased())
            if let inbox = folders.first(where: {
                Self.folderPayload(from: $0)?.role == "inbox"
            }) {
                fetched = fetchMessages(inFolder: inbox.id, limit: limit)
            } else {
                fetched = []
            }
        case .allInboxes:
            // Fetch folders with role inbox, parentId-query each, merge+sort
            // — fine at Stage-2 scale (per-folder queries are indexed).
            fetched = fetchInboxFolders()
                .flatMap { fetchMessages(inFolder: $0.id, limit: limit) }
                .sorted { $0.createdMs > $1.createdMs }
        case .flagged(let color):
            fetched = fetchAllMessages(limit: limit).filter { row in
                guard let flagColor = row.flagColor else { return false }
                if let color { return flagColor == color.rawValue }
                return true
            }
        }
        // Thread grouping: collapse to the newest message per thread with a
        // "(n)" badge; the detail pane shows the full thread.
        return MessageRowData.collapsedByThread(fetched.compactMap { MessageRowData(from: $0) })
    }

    // MARK: - Payload decoding helpers

    nonisolated static func messagePayload(from row: SharedItemRow) -> MailMessagePayload? {
        guard let data = row.payloadJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MailMessagePayload.self, from: data)
    }

    nonisolated static func folderPayload(from row: SharedItemRow) -> MailFolderPayload? {
        guard let data = row.payloadJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MailFolderPayload.self, from: data)
    }

    nonisolated static func accountPayload(from row: SharedItemRow) -> MailAccountPayload? {
        guard let data = row.payloadJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MailAccountPayload.self, from: data)
    }

    /// Encode a Swift string as a JSON scalar for `SharedFieldEq.valueJson`
    /// (same helper shape as ImpartImpressStore's).
    private nonisolated static func jsonString(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let array = String(data: data, encoding: .utf8),
           array.count >= 2 {
            return String(array.dropFirst().dropLast())
        }
        return "\"\(value)\""
    }
}
