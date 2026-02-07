//
//  IMAPServer.swift
//  ImpelMail
//
//  Minimal IMAP server for serving counsel@ replies to mail clients.
//  Implements just enough of RFC 3501 for clients to read messages.
//

import Foundation
import Network
import OSLog

/// Minimal IMAP4rev1 server on localhost.
///
/// Serves a single mailbox (INBOX) containing counsel@ replies.
/// Supports: CAPABILITY, LOGIN, LIST, LSUB, SELECT, EXAMINE, FETCH,
///           SEARCH, STORE, EXPUNGE, NOOP, CLOSE, LOGOUT
///
/// Uses implicit TLS with a self-signed localhost certificate.
/// No real authentication — localhost only, single user.
public actor IMAPServer {

    private let logger = Logger(subsystem: "com.impress.impel", category: "imap")

    private var listeners: [NWListener] = []
    private var connections: Set<ObjectIdentifier> = []
    private(set) var isRunning = false
    private let port: UInt16
    private let store: MessageStore

    public init(port: UInt16 = 1143, store: MessageStore) {
        self.port = port
        self.store = store
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else {
            logger.info("IMAP server already running")
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            logger.error("Invalid port: \(self.port)")
            return
        }

        let parameters = TLSIdentity.tlsParameters() ?? .tcp

        do {
            let listener = try NWListener(using: parameters, on: nwPort)

            listener.stateUpdateHandler = { [weak self] state in
                Task { [weak self] in
                    await self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { [weak self] in
                    await self?.handleNewConnection(connection)
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
            listeners.append(listener)
            isRunning = true
            logger.info("IMAP server starting on port \(self.port)")
        } catch {
            logger.error("Failed to start IMAP server: \(error.localizedDescription)")
        }
    }

    public func stop() {
        guard isRunning else { return }
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        connections.removeAll()
        isRunning = false
        logger.info("IMAP server stopped")
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("IMAP server listening on port \(self.port)")
        case .failed(let error):
            logger.error("IMAP listener failed: \(error.localizedDescription)")
            isRunning = false
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let connID = ObjectIdentifier(nwConnection)
        connections.insert(connID)

        let handler = IMAPConnectionHandler(connection: nwConnection, store: store, logger: logger)

        nwConnection.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                switch state {
                case .ready:
                    await handler.start()
                case .failed, .cancelled:
                    await self?.removeConnection(connID)
                default:
                    break
                }
            }
        }

        nwConnection.start(queue: .global(qos: .userInitiated))
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        connections.remove(id)
    }
}

// MARK: - IMAP Connection Handler

/// Handles a single IMAP session.
final class IMAPConnectionHandler: Sendable {
    private let connection: NWConnection
    private let store: MessageStore
    private let logger: Logger
    private let state = IMAPSessionState()
    /// Listener registration ID for IDLE notifications.
    private let listenerState = IMAPListenerState()

    init(connection: NWConnection, store: MessageStore, logger: Logger) {
        self.connection = connection
        self.store = store
        self.logger = logger
    }

    func start() async {
        await send("* OK [CAPABILITY IMAP4rev1] impel counsel IMAP ready\r\n")
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let error = error {
                self.logger.debug("IMAP receive error: \(error.localizedDescription)")
                self.connection.cancel()
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete { self.connection.cancel() }
                return
            }

            Task {
                let input = String(data: data, encoding: .utf8) ?? ""
                // IMAP commands are line-based
                let lines = input.components(separatedBy: "\r\n").filter { !$0.isEmpty }
                for line in lines {
                    await self.processCommand(line)
                }

                if !isComplete {
                    self.receiveLoop()
                }
            }
        }
    }

    private func processCommand(_ line: String) async {
        logger.debug("IMAP << \(line)")

        // Handle DONE (untagged, terminates IDLE) before parsing tag+command
        if line.trimmingCharacters(in: .whitespaces).uppercased() == "DONE" {
            if let lid = listenerState.listenerID {
                await store.removeReplyListener(lid)
                listenerState.listenerID = nil
            }
            let idleTag = listenerState.idleTag ?? "*"
            listenerState.idleTag = nil
            await send("\(idleTag) OK IDLE terminated\r\n")
            return
        }

        // IMAP commands are: tag SP command SP arguments
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            await send("* BAD Invalid command\r\n")
            return
        }

        let tag = parts[0]
        let command = parts[1].uppercased()
        let args = parts.count > 2 ? parts[2] : ""

        switch command {
        case "CAPABILITY":
            await send("* CAPABILITY IMAP4rev1 LITERAL+ IDLE\r\n")
            await send("\(tag) OK CAPABILITY completed\r\n")

        case "LOGIN":
            // Accept any credentials on localhost
            state.authenticated = true
            await send("\(tag) OK LOGIN completed\r\n")

        case "LIST":
            await handleList(tag: tag, args: args)

        case "LSUB":
            // Same as LIST for our purposes
            await handleList(tag: tag, args: args)

        case "SELECT", "EXAMINE":
            await handleSelect(tag: tag, args: args, readOnly: command == "EXAMINE")

        case "FETCH":
            await handleFetch(tag: tag, args: args)

        case "SEARCH":
            await handleSearch(tag: tag, args: args)

        case "STORE":
            await handleStore(tag: tag, args: args)

        case "EXPUNGE":
            await handleExpunge(tag: tag)

        case "NOOP":
            // Report current mailbox status on NOOP (Apple Mail polls with this)
            if state.selectedMailbox != nil {
                let count = await store.messageCount
                await send("* \(count) EXISTS\r\n")
            }
            await send("\(tag) OK NOOP completed\r\n")

        case "CHECK":
            await send("\(tag) OK CHECK completed\r\n")

        case "CLOSE":
            state.selectedMailbox = nil
            await send("\(tag) OK CLOSE completed\r\n")

        case "LOGOUT":
            // Clean up any IDLE listener
            if let lid = listenerState.listenerID {
                await store.removeReplyListener(lid)
                listenerState.listenerID = nil
            }
            await send("* BYE impel counsel IMAP server signing off\r\n")
            await send("\(tag) OK LOGOUT completed\r\n")
            connection.cancel()

        case "IDLE":
            await handleIdle(tag: tag)

        case "UID":
            await handleUID(tag: tag, args: args)

        default:
            await send("\(tag) BAD Unknown command\r\n")
        }
    }

    // MARK: - LIST

    private func handleList(tag: String, args: String) async {
        // LIST "" "*" or LIST "" "INBOX" or LIST "" "%"
        await send("* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n")
        await send("\(tag) OK LIST completed\r\n")
    }

    // MARK: - SELECT

    private func handleSelect(tag: String, args: String, readOnly: Bool) async {
        state.selectedMailbox = "INBOX"

        let messageCount = await store.messageCount
        let recentCount = await store.recentCount
        _ = await store.unseenCount
        let firstUnseen = await store.firstUnseen
        let nextUID = await store.nextUIDValue
        let uidValidity = await store.uidValidity

        await send("* \(messageCount) EXISTS\r\n")
        await send("* \(recentCount) RECENT\r\n")
        await send("* OK [UIDVALIDITY \(uidValidity)] UIDs valid\r\n")
        await send("* OK [UIDNEXT \(nextUID)] Predicted next UID\r\n")
        if let unseen = firstUnseen {
            await send("* OK [UNSEEN \(unseen)] First unseen message\r\n")
        }
        await send("* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r\n")
        await send("* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)] Permanent flags\r\n")

        let access = readOnly ? "READ-ONLY" : "READ-WRITE"
        await send("\(tag) OK [\(access)] SELECT completed\r\n")
    }

    // MARK: - FETCH

    private func handleFetch(tag: String, args: String) async {
        // Parse: sequence_set SP fetch_items
        let fetchParts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard fetchParts.count >= 2 else {
            await send("\(tag) BAD Invalid FETCH arguments\r\n")
            return
        }

        let sequenceSet = fetchParts[0]
        let items = fetchParts[1].uppercased()

        let sequences = parseSequenceSet(sequenceSet)

        for seq in sequences {
            guard let message = await store.message(at: seq) else { continue }

            var responseItems: [String] = []

            // Check what the client wants
            let wantsAll = items.contains("ALL") || items.contains("FULL")
            let wantsEnvelope = wantsAll || items.contains("ENVELOPE")
            let wantsFlags = wantsAll || items.contains("FLAGS")
            let wantsInternalDate = wantsAll || items.contains("INTERNALDATE")
            let wantsSize = wantsAll || items.contains("RFC822.SIZE")
            let wantsUID = items.contains("UID")

            if wantsFlags {
                let flagStr = message.flags.map(\.rawValue).joined(separator: " ")
                responseItems.append("FLAGS (\(flagStr))")
            }

            if wantsUID {
                responseItems.append("UID \(message.sequenceNumber)")
            }

            if wantsInternalDate {
                let dateStr = formatInternalDate(message.date)
                responseItems.append("INTERNALDATE \"\(dateStr)\"")
            }

            if wantsSize {
                responseItems.append("RFC822.SIZE \(message.rfc2822Size)")
            }

            if wantsEnvelope {
                responseItems.append(formatEnvelope(message))
            }

            responseItems.append(contentsOf: buildBodyItems(message: message, items: items))

            // Mark as seen if non-PEEK body fetch
            if (items.contains("BODY[") || items.contains("RFC822")) &&
               !items.contains("PEEK") && !items.contains("BODY[HEADER") {
                await store.updateFlags(sequenceNumber: seq, add: [.seen])
            }

            let responseStr = responseItems.joined(separator: " ")
            await send("* \(seq) FETCH (\(responseStr))\r\n")
        }

        await send("\(tag) OK FETCH completed\r\n")
    }

    // MARK: - SEARCH

    private func handleSearch(tag: String, args: String) async {
        let upper = args.uppercased()
        let results: [Int]

        if upper.contains("UNSEEN") {
            results = await store.search(unseen: true)
        } else {
            results = await store.search(all: true)
        }

        let resultStr = results.map(String.init).joined(separator: " ")
        await send("* SEARCH \(resultStr)\r\n")
        await send("\(tag) OK SEARCH completed\r\n")
    }

    // MARK: - STORE

    private func handleStore(tag: String, args: String) async {
        // STORE sequence_set +FLAGS (\Deleted) or -FLAGS or FLAGS
        let parts = args.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            await send("\(tag) BAD Invalid STORE arguments\r\n")
            return
        }

        let sequenceSet = parts[0]
        let flagAction = parts[1].uppercased()
        let flagStr = parts.count > 2 ? parts[2] : ""

        let flags = parseFlags(flagStr)
        let sequences = parseSequenceSet(sequenceSet)

        for seq in sequences {
            if flagAction.contains("+FLAGS") {
                await store.updateFlags(sequenceNumber: seq, add: flags)
            } else if flagAction.contains("-FLAGS") {
                await store.updateFlags(sequenceNumber: seq, remove: flags)
            }
            // Report updated flags
            if let msg = await store.message(at: seq) {
                let currentFlags = msg.flags.map(\.rawValue).joined(separator: " ")
                await send("* \(seq) FETCH (FLAGS (\(currentFlags)))\r\n")
            }
        }

        await send("\(tag) OK STORE completed\r\n")
    }

    // MARK: - EXPUNGE

    private func handleExpunge(tag: String) async {
        let expunged = await store.expunge()
        for seq in expunged {
            await send("* \(seq) EXPUNGE\r\n")
        }
        await send("\(tag) OK EXPUNGE completed\r\n")
    }

    // MARK: - IDLE

    private func handleIdle(tag: String) async {
        listenerState.idleTag = tag

        // Register a listener that sends untagged EXISTS when new replies arrive
        let conn = self.connection
        let lid = await store.addReplyListener { newCount in
            let notification = "* \(newCount) EXISTS\r\n"
            if let data = notification.data(using: .utf8) {
                conn.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        listenerState.listenerID = lid

        // Tell the client we're now idling — it sends DONE to stop
        await send("+ idling\r\n")
    }

    // MARK: - UID Commands

    private func handleUID(tag: String, args: String) async {
        // UID subcommand args — e.g. "FETCH 3:4 (FLAGS UID ...)" or "SEARCH ALL"
        let uidParts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard uidParts.count >= 1 else {
            await send("\(tag) BAD Invalid UID arguments\r\n")
            return
        }

        let subcommand = uidParts[0].uppercased()
        let subArgs = uidParts.count > 1 ? uidParts[1] : ""

        switch subcommand {
        case "FETCH":
            await handleUIDFetch(tag: tag, args: subArgs)
        case "SEARCH":
            await handleUIDSearch(tag: tag, args: subArgs)
        case "STORE":
            await handleStore(tag: tag, args: subArgs)
        default:
            await send("\(tag) BAD Unknown UID subcommand\r\n")
        }
    }

    private func handleUIDFetch(tag: String, args: String) async {
        // Parse: uid_set SP fetch_items
        // e.g. "3:4 (INTERNALDATE UID RFC822.SIZE FLAGS BODY.PEEK[HEADER])"
        let fetchParts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard fetchParts.count >= 2 else {
            await send("\(tag) BAD Invalid UID FETCH arguments\r\n")
            return
        }

        let uidSet = fetchParts[0]
        let items = fetchParts[1].uppercased()

        // Parse the UID range
        let uids = parseSequenceSet(uidSet)
        let messageCount = await store.messageCount

        for uid in uids {
            guard let message = await store.message(uid: uid) else { continue }
            // Find the sequence number for this message
            var seqNum = 0
            for i in 1...messageCount {
                if let m = await store.message(at: i), m.sequenceNumber == uid {
                    seqNum = i
                    break
                }
            }
            if seqNum == 0 { continue }

            var responseItems: [String] = []

            // Always include UID in UID FETCH responses (required by RFC 3501)
            responseItems.append("UID \(message.sequenceNumber)")

            let wantsFlags = items.contains("FLAGS")
            let wantsInternalDate = items.contains("INTERNALDATE")
            let wantsSize = items.contains("RFC822.SIZE")
            if wantsFlags {
                let flagStr = message.flags.map(\.rawValue).joined(separator: " ")
                responseItems.append("FLAGS (\(flagStr))")
            }

            if wantsInternalDate {
                let dateStr = formatInternalDate(message.date)
                responseItems.append("INTERNALDATE \"\(dateStr)\"")
            }

            if wantsSize {
                responseItems.append("RFC822.SIZE \(message.rfc2822Size)")
            }

            responseItems.append(contentsOf: buildBodyItems(message: message, items: items))

            // Mark as seen if non-PEEK body fetch
            if (items.contains("BODY[") || items.contains("RFC822")) &&
               !items.contains("PEEK") && !items.contains("BODY[HEADER") {
                await store.updateFlags(sequenceNumber: seqNum, add: [.seen])
            }

            let responseStr = responseItems.joined(separator: " ")
            await send("* \(seqNum) FETCH (\(responseStr))\r\n")
        }

        await send("\(tag) OK UID FETCH completed\r\n")
    }

    private func handleUIDSearch(tag: String, args: String) async {
        // UID SEARCH returns UIDs instead of sequence numbers
        let upper = args.uppercased()
        let results: [Int]

        if upper.contains("UNSEEN") {
            results = await store.search(unseen: true)
        } else {
            results = await store.search(all: true)
        }

        // Convert sequence numbers to UIDs
        var uids: [Int] = []
        for seq in results {
            if let msg = await store.message(at: seq) {
                uids.append(msg.sequenceNumber)
            }
        }

        let resultStr = uids.map(String.init).joined(separator: " ")
        await send("* SEARCH \(resultStr)\r\n")
        await send("\(tag) OK UID SEARCH completed\r\n")
    }

    // MARK: - Body Item Builder

    /// Build FETCH response items for body-related requests.
    /// Properly extracts the BODY section specifier and echoes it back
    /// per RFC 3501 (BODY.PEEK[x] → BODY[x] in response).
    private func buildBodyItems(message: MailMessage, items: String) -> [String] {
        var result: [String] = []
        let rfc = message.toRFC2822()

        // Split into headers and body text
        let headerEnd = rfc.range(of: "\r\n\r\n")?.lowerBound ?? rfc.endIndex
        let headers = String(rfc[rfc.startIndex..<headerEnd]) + "\r\n\r\n"
        let bodyStart = rfc.range(of: "\r\n\r\n").map { $0.upperBound } ?? rfc.endIndex
        let bodyText = String(rfc[bodyStart...])

        // BODYSTRUCTURE
        if items.contains("BODYSTRUCTURE") {
            let size = bodyText.data(using: .utf8)?.count ?? 0
            let lines = bodyText.components(separatedBy: "\r\n").count
            result.append("BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" \(size) \(lines))")
        }

        // BODY[section] or BODY.PEEK[section] — extract section and echo back correctly
        if let section = extractBodySection(from: items) {
            let sectionUpper = section.uppercased()

            if sectionUpper.hasPrefix("HEADER") {
                // HEADER, HEADER.FIELDS (...), HEADER.FIELDS.NOT (...)
                let headerData = headers.data(using: .utf8) ?? Data()
                result.append("BODY[\(section)] {\(headerData.count)}\r\n\(headers)")
            } else if sectionUpper == "TEXT" {
                let textData = bodyText.data(using: .utf8) ?? Data()
                result.append("BODY[TEXT] {\(textData.count)}\r\n\(bodyText)")
            } else if sectionUpper == "1" {
                let textData = bodyText.data(using: .utf8) ?? Data()
                result.append("BODY[1] {\(textData.count)}\r\n\(bodyText)")
            } else if sectionUpper.isEmpty {
                // BODY[] — full message
                let fullData = rfc.data(using: .utf8) ?? Data()
                result.append("BODY[] {\(fullData.count)}\r\n\(rfc)")
            } else {
                logger.warning("IMAP: Unhandled BODY section: [\(section)]")
            }
        }

        // RFC822 variants (only when no BODY[] syntax was used)
        if !items.contains("BODY[") && !items.contains("BODY.PEEK[") {
            if items.contains("RFC822.HEADER") {
                let headerData = headers.data(using: .utf8) ?? Data()
                result.append("RFC822.HEADER {\(headerData.count)}\r\n\(headers)")
            } else if items.contains("RFC822.TEXT") {
                let textData = bodyText.data(using: .utf8) ?? Data()
                result.append("RFC822.TEXT {\(textData.count)}\r\n\(bodyText)")
            } else if items.contains("RFC822") && !items.contains("RFC822.") {
                let fullData = rfc.data(using: .utf8) ?? Data()
                result.append("RFC822 {\(fullData.count)}\r\n\(rfc)")
            }
        }

        return result
    }

    /// Extract the BODY section specifier from FETCH items.
    /// Handles BODY.PEEK[...] and BODY[...] — returns the section between brackets.
    private func extractBodySection(from items: String) -> String? {
        for pattern in ["BODY.PEEK[", "BODY["] {
            if let range = items.range(of: pattern) {
                let afterBracket = items[range.upperBound...]
                if let closeBracket = afterBracket.firstIndex(of: "]") {
                    return String(afterBracket[afterBracket.startIndex..<closeBracket])
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func parseSequenceSet(_ set: String) -> [Int] {
        var result: [Int] = []
        for part in set.split(separator: ",") {
            let rangeParts = part.split(separator: ":").compactMap { Int($0) }
            if rangeParts.count == 2 {
                let lower = min(rangeParts[0], rangeParts[1])
                let upper = max(rangeParts[0], rangeParts[1])
                result.append(contentsOf: lower...upper)
            } else if rangeParts.count == 1 {
                result.append(rangeParts[0])
            } else if part.contains("*") {
                // Handle ranges like "1:*"
                let starParts = part.split(separator: ":").map(String.init)
                if starParts.count == 2, let start = Int(starParts[0]) {
                    // "*" means the highest sequence number — use a reasonable max
                    result.append(contentsOf: start...(start + 1000))
                } else {
                    result.append(1) // "*" alone means "all"
                }
            }
        }
        return result
    }

    private func parseFlags(_ str: String) -> Set<IMAPFlag> {
        var flags: Set<IMAPFlag> = []
        let cleaned = str.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        for part in cleaned.split(separator: " ") {
            let flag = String(part)
            if let imapFlag = IMAPFlag(rawValue: flag) {
                flags.insert(imapFlag)
            }
        }
        return flags
    }

    private func formatEnvelope(_ msg: MailMessage) -> String {
        let date = formatInternalDate(msg.date)
        let subject = msg.subject.replacingOccurrences(of: "\"", with: "\\\"")
        let from = formatAddress(msg.from)
        let to = msg.to.map { formatAddress($0) }.joined(separator: " ")

        return "ENVELOPE (\"\(date)\" \"\(subject)\" ((\(from))) ((\(from))) ((\(from))) ((\(to))) NIL NIL \(msg.inReplyTo.map { "\"\($0)\"" } ?? "NIL") \"\(msg.messageID)\")"
    }

    private func formatAddress(_ addr: String) -> String {
        // Parse "Name <email>" or just "email"
        if let angleBracketStart = addr.firstIndex(of: "<"),
           let angleBracketEnd = addr.firstIndex(of: ">") {
            let name = String(addr[addr.startIndex..<angleBracketStart]).trimmingCharacters(in: .whitespaces)
            let email = String(addr[addr.index(after: angleBracketStart)..<angleBracketEnd])
            let emailParts = email.split(separator: "@")
            let mailbox = emailParts.first.map(String.init) ?? email
            let host = emailParts.count > 1 ? String(emailParts[1]) : "impress.local"
            let displayName = name.isEmpty ? "NIL" : "\"\(name)\""
            return "\(displayName) NIL \"\(mailbox)\" \"\(host)\""
        }

        let emailParts = addr.split(separator: "@")
        let mailbox = emailParts.first.map(String.init) ?? addr
        let host = emailParts.count > 1 ? String(emailParts[1]) : "impress.local"
        return "NIL NIL \"\(mailbox)\" \"\(host)\""
    }

    private func formatInternalDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func send(_ response: String) async {
        logger.debug("IMAP >> \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard let data = response.data(using: .utf8) else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

// MARK: - IMAP Session State

private final class IMAPSessionState: @unchecked Sendable {
    private let lock = NSLock()

    private var _authenticated = false
    private var _selectedMailbox: String?

    var authenticated: Bool {
        get { lock.withLock { _authenticated } }
        set { lock.withLock { _authenticated = newValue } }
    }

    var selectedMailbox: String? {
        get { lock.withLock { _selectedMailbox } }
        set { lock.withLock { _selectedMailbox = newValue } }
    }
}

/// Thread-safe state for IDLE listener tracking.
private final class IMAPListenerState: @unchecked Sendable {
    private let lock = NSLock()

    private var _listenerID: UUID?
    private var _idleTag: String?

    var listenerID: UUID? {
        get { lock.withLock { _listenerID } }
        set { lock.withLock { _listenerID = newValue } }
    }

    var idleTag: String? {
        get { lock.withLock { _idleTag } }
        set { lock.withLock { _idleTag = newValue } }
    }
}
