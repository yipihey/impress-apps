//
//  SMTPServer.swift
//  ImpelMail
//
//  Minimal SMTP server for receiving email on localhost.
//  Implements just enough of RFC 5321 for mail clients to deliver.
//

import Foundation
import Network
import OSLog

/// Minimal SMTP server accepting mail on localhost.
///
/// Supports: EHLO, MAIL FROM, RCPT TO, DATA, QUIT, RSET, NOOP, AUTH PLAIN/LOGIN
/// Uses implicit TLS with a self-signed localhost certificate.
/// AUTH accepts any credentials (local trust).
public actor SMTPServer {

    private let logger = Logger(subsystem: "com.impress.impel", category: "smtp")

    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: SMTPConnection] = [:]
    private(set) var isRunning = false
    private let port: UInt16
    private let store: MessageStore
    private let hostname: String

    public init(port: UInt16 = 2525, hostname: String = "impress.local", store: MessageStore) {
        self.port = port
        self.hostname = hostname
        self.store = store
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else {
            logger.info("SMTP server already running")
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
            logger.info("SMTP server starting on port \(self.port)")
        } catch {
            logger.error("Failed to start SMTP server: \(error.localizedDescription)")
        }
    }

    public func stop() {
        guard isRunning else { return }
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        for conn in connections.values {
            conn.cancel()
        }
        connections.removeAll()
        isRunning = false
        logger.info("SMTP server stopped")
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("SMTP server listening on port \(self.port)")
        case .failed(let error):
            logger.error("SMTP listener failed: \(error.localizedDescription)")
            isRunning = false
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let conn = SMTPConnection(
            connection: nwConnection,
            hostname: hostname,
            store: store,
            logger: logger
        )
        let connID = ObjectIdentifier(nwConnection)
        connections[connID] = conn

        nwConnection.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                switch state {
                case .ready:
                    await conn.start()
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
        connections.removeValue(forKey: id)
    }
}

// MARK: - SMTP Connection State Machine

/// Handles a single SMTP conversation.
final class SMTPConnection: Sendable {
    private let connection: NWConnection
    private let hostname: String
    private let store: MessageStore
    private let logger: Logger

    /// Mutable state protected by a lock for Sendable conformance.
    private let state = SMTPConnectionState()

    init(connection: NWConnection, hostname: String, store: MessageStore, logger: Logger) {
        self.connection = connection
        self.hostname = hostname
        self.store = store
        self.logger = logger
    }

    func cancel() {
        connection.cancel()
    }

    func start() async {
        // Send greeting
        await send("220 \(hostname) ESMTP impel counsel gateway ready\r\n")
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let error = error {
                self.logger.debug("SMTP receive error: \(error.localizedDescription)")
                self.connection.cancel()
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete { self.connection.cancel() }
                return
            }

            Task {
                await self.processData(data)
                if !isComplete {
                    self.receiveLoop()
                }
            }
        }
    }

    private func processData(_ data: Data) async {
        let input = String(data: data, encoding: .utf8) ?? ""

        // If we're in DATA mode, accumulate message data
        if state.inDataMode {
            state.appendDataBuffer(input)

            // Check for end-of-data marker
            if state.dataBuffer.contains("\r\n.\r\n") || state.dataBuffer.contains("\n.\n") {
                await finishData()
            }
            return
        }

        // Process line-based commands
        let lines = input.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        for line in lines {
            await processCommand(line)
        }
    }

    private func processCommand(_ line: String) async {
        let upper = line.uppercased()
        let parts = line.split(separator: " ", maxSplits: 1)
        let command = parts.first.map(String.init)?.uppercased() ?? ""

        logger.debug("SMTP << \(line)")

        switch command {
        case "EHLO", "HELO":
            state.reset()
            await send("250-\(hostname) greets you\r\n250-SIZE 10485760\r\n250-8BITMIME\r\n250-AUTH PLAIN LOGIN\r\n250 OK\r\n")

        case "MAIL":
            // MAIL FROM:<address>
            if let address = extractAddress(from: line) {
                state.mailFrom = address
                await send("250 OK\r\n")
            } else {
                await send("501 Syntax error in MAIL FROM\r\n")
            }

        case "RCPT":
            // RCPT TO:<address>
            if let address = extractAddress(from: line) {
                state.addRecipient(address)
                await send("250 OK\r\n")
            } else {
                await send("501 Syntax error in RCPT TO\r\n")
            }

        case "DATA":
            guard state.mailFrom != nil, !state.rcptTo.isEmpty else {
                await send("503 Need MAIL and RCPT first\r\n")
                return
            }
            state.inDataMode = true
            state.clearDataBuffer()
            await send("354 Start mail input; end with <CRLF>.<CRLF>\r\n")

        case "RSET":
            state.reset()
            await send("250 OK\r\n")

        case "NOOP":
            await send("250 OK\r\n")

        case "QUIT":
            await send("221 \(hostname) closing connection\r\n")
            connection.cancel()

        case "AUTH":
            // Accept any AUTH credentials (localhost trust model).
            // AUTH PLAIN <base64> — single line
            // AUTH LOGIN — multi-step (username then password prompts)
            if upper.hasPrefix("AUTH PLAIN") {
                // Credentials in same line or next line — accept either way
                await send("235 2.7.0 Authentication successful\r\n")
            } else if upper == "AUTH LOGIN" {
                // Enter AUTH LOGIN multi-step mode
                state.inAuthLogin = true
                state.authLoginStep = 0
                await send("334 VXNlcm5hbWU6\r\n") // Base64("Username:")
            } else {
                await send("235 2.7.0 Authentication successful\r\n")
            }

        default:
            // Handle AUTH LOGIN continuation (username/password responses)
            if state.inAuthLogin {
                if state.authLoginStep == 0 {
                    // Got username, ask for password
                    state.authLoginStep = 1
                    await send("334 UGFzc3dvcmQ6\r\n") // Base64("Password:")
                } else {
                    // Got password, accept
                    state.inAuthLogin = false
                    state.authLoginStep = 0
                    await send("235 2.7.0 Authentication successful\r\n")
                }
            } else if upper.hasPrefix("STARTTLS") {
                await send("502 Command not implemented\r\n")
            } else {
                await send("500 Unrecognized command\r\n")
            }
        }
    }

    private func finishData() async {
        var rawData = state.dataBuffer

        // Remove the terminating dot
        if let range = rawData.range(of: "\r\n.\r\n") {
            rawData = String(rawData[rawData.startIndex..<range.lowerBound])
        } else if let range = rawData.range(of: "\n.\n") {
            rawData = String(rawData[rawData.startIndex..<range.lowerBound])
        }

        // Undo dot-stuffing (lines starting with ".." become ".")
        rawData = rawData.replacingOccurrences(of: "\r\n..", with: "\r\n.")

        let envelopeRecipients = state.rcptTo
        let message = EmailParser.parse(
            rawData: rawData,
            from: state.mailFrom ?? "unknown",
            to: state.rcptTo,
            envelopeRecipients: envelopeRecipients
        )

        state.inDataMode = false
        state.clearDataBuffer()
        state.reset()

        // Send 250 OK immediately — don't block SMTP on gateway processing.
        // Apple Mail waits for this before showing "sent" to the user.
        await send("250 OK message accepted\r\n")

        // Process the message asynchronously so the SMTP client is released.
        let store = self.store
        Task {
            await store.receiveIncoming(message)
        }
    }

    private func extractAddress(from line: String) -> String? {
        // Extract address from MAIL FROM:<addr> or RCPT TO:<addr>
        guard let start = line.firstIndex(of: "<"),
              let end = line.firstIndex(of: ">"),
              start < end else {
            // Try without angle brackets: MAIL FROM:addr
            let colonParts = line.split(separator: ":", maxSplits: 1)
            if colonParts.count == 2 {
                let addr = colonParts[1].trimmingCharacters(in: .whitespaces)
                if !addr.isEmpty { return addr }
            }
            return nil
        }
        let address = String(line[line.index(after: start)..<end])
        return address.isEmpty ? nil : address
    }

    private func send(_ response: String) async {
        logger.debug("SMTP >> \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard let data = response.data(using: .utf8) else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

// MARK: - SMTP Connection State (thread-safe)

/// Thread-safe mutable state for an SMTP connection.
private final class SMTPConnectionState: @unchecked Sendable {
    private let lock = NSLock()

    private var _mailFrom: String?
    private var _rcptTo: [String] = []
    private var _inDataMode = false
    private var _dataBuffer = ""
    private var _inAuthLogin = false
    private var _authLoginStep = 0

    var mailFrom: String? {
        get { lock.withLock { _mailFrom } }
        set { lock.withLock { _mailFrom = newValue } }
    }

    var rcptTo: [String] {
        get { lock.withLock { _rcptTo } }
    }

    var inDataMode: Bool {
        get { lock.withLock { _inDataMode } }
        set { lock.withLock { _inDataMode = newValue } }
    }

    var dataBuffer: String {
        get { lock.withLock { _dataBuffer } }
    }

    var inAuthLogin: Bool {
        get { lock.withLock { _inAuthLogin } }
        set { lock.withLock { _inAuthLogin = newValue } }
    }

    var authLoginStep: Int {
        get { lock.withLock { _authLoginStep } }
        set { lock.withLock { _authLoginStep = newValue } }
    }

    func addRecipient(_ address: String) {
        lock.withLock { _rcptTo.append(address) }
    }

    func appendDataBuffer(_ data: String) {
        lock.withLock { _dataBuffer += data }
    }

    func clearDataBuffer() {
        lock.withLock { _dataBuffer = "" }
    }

    func reset() {
        lock.withLock {
            _mailFrom = nil
            _rcptTo = []
            _inDataMode = false
            _dataBuffer = ""
            _inAuthLogin = false
            _authLoginStep = 0
        }
    }
}
