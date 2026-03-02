//
//  ImpartStoreAdapter.swift
//  MessageManagerCore
//
//  Adapter for storing impart messages in the shared impress-core SQLite store.
//
//  Messages are stored as `email-message@1.0.0` or `chat-message@1.0.0` items,
//  making them visible to any impress tool that can query the unified store
//  (imbib, imprint, implore, impel).
//
//  This is Phase 1 scaffolding: the workspace path is wired and the public API
//  is defined. Actual UniFFI FFI calls are marked TODO and will be added in a
//  follow-up unit once the impress-core XCFramework is built for impart.
//

import Foundation
import OSLog
import ImpressKit
import ImpressLogging
#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - ImpartStoreAdapter

/// Adapter for storing impart messages in the shared impress-core SQLite store.
///
/// Opens (or creates) the shared workspace database at
/// `SharedWorkspace.databaseURL` and exposes typed methods for writing
/// `email-message@1.0.0` and `chat-message@1.0.0` items.
///
/// ## Usage
///
/// ```swift
/// // At app startup
/// ImpartStoreAdapter.shared.setup()
///
/// // When a message arrives
/// ImpartStoreAdapter.shared.storeEmailMessage(
///     messageID: message.messageId ?? UUID().uuidString,
///     subject: message.subject,
///     body: content.plainTextBody ?? "",
///     from: message.fromDisplayString,
///     to: message.to.map(\.email),
///     threadID: nil
/// )
/// ```
///
/// ## Schema
///
/// `email-message@1.0.0` inherits from `chat-message@1.0.0`.
///
/// | Schema field | Type | Required | Source |
/// |---|---|---|---|
/// | `body` | String | yes | plain-text body |
/// | `from` | String | yes | `from[0].email` |
/// | `channel` | String | no | mailbox name (e.g., "INBOX") |
/// | `thread_id` | String | no | JWZ thread ID |
/// | `subject` | String | yes (email) | `message.subject` |
/// | `to` | StringArray | no | recipient addresses |
/// | `cc` | StringArray | no | CC addresses |
/// | `message_id` | String | no | RFC 2822 Message-ID |
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
    public var databasePath: String {
        SharedWorkspace.databaseURL.path
    }

    // MARK: - Shared Store

    #if canImport(ImpressRustCore)
    private var store: SharedStore?
    #endif

    // MARK: - Init

    private init() {}

    // MARK: - Setup

    /// Prepare the shared workspace directory.
    ///
    /// Call once at app startup (e.g., from `ImpartApp.init()` or `ImpartApp.body`).
    /// Safe to call multiple times.
    public func setup() {
        do {
            try SharedWorkspace.ensureDirectoryExists()
            #if canImport(ImpressRustCore)
            store = try SharedStore.open(path: databasePath)
            #endif
            isReady = true
            Logger.impartStore.infoCapture(
                "ImpartStoreAdapter ready — db: \(databasePath)",
                category: "store"
            )
        } catch {
            isReady = false
            Logger.impartStore.errorCapture(
                "ImpartStoreAdapter setup failed: \(error.localizedDescription)",
                category: "store"
            )
        }
    }

    // MARK: - Mutation signalling

    /// Increment `dataVersion` to notify observers of a store change.
    public func didMutate() {
        dataVersion += 1
    }

    // MARK: - Email messages

    /// Store an email message in the shared impress-core store.
    ///
    /// Creates or upserts an `email-message@1.0.0` item keyed by `messageID`.
    ///
    /// - Parameters:
    ///   - messageID: Stable unique identifier (RFC 2822 Message-ID or generated UUID string).
    ///   - subject: Email subject line (required by schema).
    ///   - body: Plain-text message body (required by schema).
    ///   - from: Sender address string (required by schema).
    ///   - to: Recipient address strings (stored as StringArray).
    ///   - cc: CC address strings (stored as StringArray), defaults to empty.
    ///   - mailbox: Mailbox name such as "INBOX" (stored as `channel`).
    ///   - threadID: JWZ thread identifier for grouping related messages.
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

        Logger.impartStore.infoCapture(
            "storeEmailMessage: subject='\(subject)' from='\(from)' messageID=\(messageID)",
            category: "store"
        )

        let payload: [String: Any?] = [
            "subject": subject,
            "body": body,
            "from": from,
            "to": to.isEmpty ? nil : to,
            "cc": cc.isEmpty ? nil : cc,
            "channel": mailbox,
            "thread_id": threadID,
            "message_id": messageID
        ]
        let compacted = payload.compactMapValues { $0 }
        if let payloadJSON = try? JSONSerialization.data(withJSONObject: compacted),
           let payloadString = String(data: payloadJSON, encoding: .utf8) {
            #if canImport(ImpressRustCore)
            do {
                try store?.upsertItem(id: messageID, schemaRef: "email-message", payloadJson: payloadString)
                Logger.impartStore.infoCapture(
                    "storeEmailMessage: upserted \(messageID) in shared store",
                    category: "store"
                )
            } catch {
                Logger.impartStore.errorCapture(
                    "storeEmailMessage: upsert failed for \(messageID) — \(error)",
                    category: "store"
                )
            }
            #else
            Logger.impartStore.infoCapture(
                "storeEmailMessage: \(messageID) (ImpressRustCore not linked)",
                category: "store"
            )
            #endif
        }

        didMutate()

        Logger.impartStore.infoCapture(
            "storeEmailMessage complete: messageID=\(messageID) dataVersion=\(dataVersion)",
            category: "store"
        )
    }

    // MARK: - Chat messages

    /// Store a chat/IM message in the shared impress-core store.
    ///
    /// Creates or upserts a `chat-message@1.0.0` item keyed by `messageID`.
    ///
    /// - Parameters:
    ///   - messageID: Stable unique identifier (generated UUID string or platform ID).
    ///   - body: Message body text (required by schema).
    ///   - from: Sender identifier — name, handle, or address (required by schema).
    ///   - channel: Channel or room name (e.g., "#general", "DM with Alice").
    ///   - threadID: Opaque thread identifier for grouping replies.
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

        Logger.impartStore.infoCapture(
            "storeChatMessage: from='\(from)' channel='\(channel ?? "none")' messageID=\(messageID)",
            category: "store"
        )

        let payload: [String: Any?] = [
            "body": body,
            "from": from,
            "channel": channel,
            "thread_id": threadID
        ]
        let compacted = payload.compactMapValues { $0 }
        if let payloadJSON = try? JSONSerialization.data(withJSONObject: compacted),
           let payloadString = String(data: payloadJSON, encoding: .utf8) {
            #if canImport(ImpressRustCore)
            do {
                try store?.upsertItem(id: messageID, schemaRef: "chat-message", payloadJson: payloadString)
                Logger.impartStore.infoCapture(
                    "storeChatMessage: upserted \(messageID) in shared store",
                    category: "store"
                )
            } catch {
                Logger.impartStore.errorCapture(
                    "storeChatMessage: upsert failed for \(messageID) — \(error)",
                    category: "store"
                )
            }
            #else
            Logger.impartStore.infoCapture(
                "storeChatMessage: \(messageID) (ImpressRustCore not linked)",
                category: "store"
            )
            #endif
        }

        didMutate()

        Logger.impartStore.infoCapture(
            "storeChatMessage complete: messageID=\(messageID) dataVersion=\(dataVersion)",
            category: "store"
        )
    }

    // MARK: - Bulk sync

    /// Sync all messages from a mailbox into the shared store.
    ///
    /// Iterates `messages` and calls `storeEmailMessage` for each.
    /// Intended for initial import or background refresh.
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

        for message in messages {
            storeEmailMessage(
                messageID: message.messageId ?? message.id.uuidString,
                subject: message.subject,
                body: message.snippet,    // snippet until full body is fetched
                from: message.fromDisplayString,
                to: message.to.map(\.email),
                cc: message.cc.map(\.email),
                mailbox: mailbox,
                threadID: nil
            )
        }
    }
}

// Note: Logger.impartStore is declared in Logger+Extensions.swift
