//
//  MessageStore.swift
//  ImpelMail
//
//  In-memory message store backing both SMTP receive and IMAP serve.
//

import Foundation
import OSLog

/// Stores messages for IMAP retrieval.
///
/// Maintains two separate streams:
/// - Incoming: messages from PI → counsel (processed by gateway, not served via IMAP)
/// - Replies: messages from counsel → PI (served to the PI's mail client via IMAP)
///
/// The PI's mail client connects via IMAP and sees only counsel's replies
/// in their inbox — exactly like emailing a colleague.
public actor MessageStore {

    private let logger = Logger(subsystem: "com.impress.impel", category: "messageStore")

    // MARK: - Reply Store (served via IMAP to the PI)

    /// Counsel's replies, keyed by message ID.
    private var replies: [String: MailMessage] = [:]

    /// Ordered list of reply message IDs for IMAP sequencing.
    private var replyOrder: [String] = []

    /// Next IMAP UID to assign.
    private var nextUID: Int = 1

    /// IMAP UIDVALIDITY — changes when the mailbox is reset.
    private(set) var uidValidity: Int = 1

    // MARK: - Incoming Store (PI's messages to counsel, for gateway processing)

    /// Incoming messages from the PI, kept for thread reference.
    private var incoming: [String: MailMessage] = [:]

    /// Default callback invoked when no prefix-based handler matches.
    private var onIncomingMessage: (@Sendable (MailMessage) async -> Void)?

    /// Prefix-based handlers: local-part prefix → handler.
    /// e.g., "capture" handles capture@impress.local
    private var prefixHandlers: [String: @Sendable (MailMessage) async -> Void] = [:]

    /// Set the default handler for incoming messages (from SMTP).
    /// Used as fallback when no prefix-based handler matches.
    public func setIncomingHandler(_ handler: @escaping @Sendable (MailMessage) async -> Void) {
        onIncomingMessage = handler
    }

    /// Register a handler for a specific address prefix.
    ///
    /// When a message arrives addressed to `{prefix}@...`, this handler fires
    /// instead of the default incoming handler.
    ///
    /// - Parameters:
    ///   - prefix: The local-part prefix to match (e.g., "capture" matches capture@impress.local).
    ///   - handler: Async handler receiving the matched message.
    public func addIncomingHandler(forPrefix prefix: String, handler: @escaping @Sendable (MailMessage) async -> Void) {
        prefixHandlers[prefix.lowercased()] = handler
    }

    // MARK: - SMTP Side (PI sends to counsel)

    /// Store an incoming message from SMTP and notify the appropriate handler.
    ///
    /// Checks envelope recipients against registered prefix handlers first.
    /// Falls back to the default incoming handler if no prefix matches.
    public func receiveIncoming(_ message: MailMessage) async {
        incoming[message.messageID] = message

        logger.info("Received message from \(message.from): \(message.subject)")

        // Check envelope recipients for prefix-based routing
        let recipients = message.envelopeRecipients.isEmpty ? message.to : message.envelopeRecipients
        for recipient in recipients {
            let localPart = recipient.components(separatedBy: "@").first?.lowercased() ?? ""
            if let handler = prefixHandlers[localPart] {
                await handler(message)
                return
            }
        }

        // No prefix match — use default handler
        await onIncomingMessage?(message)
    }

    // MARK: - Agent Side (counsel replies to PI)

    /// Store a reply from counsel for IMAP retrieval by the PI's mail client.
    public func storeReply(_ message: MailMessage) {
        var msg = message
        msg.sequenceNumber = nextUID
        nextUID += 1
        msg.flags.insert(.recent)
        replies[msg.messageID] = msg
        replyOrder.append(msg.messageID)

        logger.info("Stored reply for PI: \(msg.subject)")
        notifyListeners()
    }

    // MARK: - IMAP Side (serving counsel's replies to the PI)

    /// Total message count (replies only).
    public var messageCount: Int {
        replyOrder.count
    }

    /// Count of recent messages.
    public var recentCount: Int {
        replies.values.filter { $0.flags.contains(.recent) }.count
    }

    /// Count of unseen messages.
    public var unseenCount: Int {
        replies.values.filter { !$0.flags.contains(.seen) }.count
    }

    /// First unseen message sequence number (1-based).
    public var firstUnseen: Int? {
        for (index, msgID) in replyOrder.enumerated() {
            if let msg = replies[msgID], !msg.flags.contains(.seen) {
                return index + 1
            }
        }
        return nil
    }

    /// Next UID that will be assigned.
    public var nextUIDValue: Int {
        nextUID
    }

    /// Fetch a reply by 1-based sequence number.
    public func message(at sequenceNumber: Int) -> MailMessage? {
        let index = sequenceNumber - 1
        guard index >= 0, index < replyOrder.count else { return nil }
        return replies[replyOrder[index]]
    }

    /// Fetch a reply by UID.
    public func message(uid: Int) -> MailMessage? {
        replies.values.first { $0.sequenceNumber == uid }
    }

    /// Fetch replies in a sequence range (1-based, inclusive).
    public func messages(in range: ClosedRange<Int>) -> [MailMessage] {
        let clamped = max(1, range.lowerBound)...min(replyOrder.count, range.upperBound)
        return clamped.compactMap { message(at: $0) }
    }

    /// Update flags on a reply by sequence number.
    public func updateFlags(sequenceNumber: Int, add: Set<IMAPFlag> = [], remove: Set<IMAPFlag> = []) {
        let index = sequenceNumber - 1
        guard index >= 0, index < replyOrder.count else { return }
        let msgID = replyOrder[index]
        replies[msgID]?.flags.formUnion(add)
        replies[msgID]?.flags.subtract(remove)
    }

    /// Expunge replies marked as deleted.
    public func expunge() -> [Int] {
        var expunged: [Int] = []
        var i = replyOrder.count - 1
        while i >= 0 {
            let msgID = replyOrder[i]
            if let msg = replies[msgID], msg.flags.contains(.deleted) {
                expunged.insert(i + 1, at: 0) // 1-based
                replies.removeValue(forKey: msgID)
                replyOrder.remove(at: i)
            }
            i -= 1
        }
        return expunged
    }

    /// Search for replies matching simple criteria.
    public func search(unseen: Bool = false, all: Bool = false) -> [Int] {
        if all {
            return replyOrder.isEmpty ? [] : Array(1...replyOrder.count)
        }
        if unseen {
            return replyOrder.enumerated().compactMap { index, msgID in
                guard let msg = replies[msgID], !msg.flags.contains(.seen) else { return nil }
                return index + 1
            }
        }
        return []
    }

    /// Look up an incoming message by message ID (for thread context).
    public func incomingMessage(messageID: String) -> MailMessage? {
        incoming[messageID]
    }

    /// Total count of all messages (incoming + replies) for status display.
    public var totalCount: Int {
        incoming.count + replies.count
    }

    // MARK: - Change Notifications (for IMAP IDLE)

    /// Registered listeners for new reply notifications.
    private var replyListeners: [UUID: @Sendable (Int) -> Void] = [:]

    /// Register a listener that fires when a new reply is stored.
    /// Returns a registration ID for removal. The callback receives the new EXISTS count.
    public func addReplyListener(_ listener: @escaping @Sendable (Int) -> Void) -> UUID {
        let id = UUID()
        replyListeners[id] = listener
        return id
    }

    /// Remove a reply listener.
    public func removeReplyListener(_ id: UUID) {
        replyListeners.removeValue(forKey: id)
    }

    /// Notify all listeners of new reply count. Called internally after storeReply.
    private func notifyListeners() {
        let count = replyOrder.count
        for listener in replyListeners.values {
            listener(count)
        }
    }
}
