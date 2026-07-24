//
//  HTTPServer.swift
//  ImpressAutomation
//
//  Generic HTTP server actor for impress apps.
//  Handles TCP connections via Network.framework.
//

import Foundation
import Network
import OSLog

/// Configuration for an HTTP server instance.
public struct HTTPServerConfiguration: Sendable {
    /// The port to listen on
    public let port: UInt16

    /// Logger subsystem for this server
    public let loggerSubsystem: String

    /// Logger category for this server
    public let loggerCategory: String

    /// Whether to log all requests
    public let logRequests: Bool

    /// Opt-in: also accept NON-loopback peers (e.g. over the user's tailnet).
    /// When false (default) the listener binds loopback only — the pre-2026-07
    /// behavior, byte-identical for every existing caller.
    public let allowNetworkAccess: Bool

    /// Bearer token required from non-loopback peers. Loopback peers are
    /// never asked for it. See `HTTPAuthPolicy`.
    public let authToken: String?

    public init(
        port: UInt16,
        loggerSubsystem: String,
        loggerCategory: String = "httpServer",
        logRequests: Bool = false,
        allowNetworkAccess: Bool = false,
        authToken: String? = nil
    ) {
        self.port = port
        self.loggerSubsystem = loggerSubsystem
        self.loggerCategory = loggerCategory
        self.logRequests = logRequests
        self.allowNetworkAccess = allowNetworkAccess
        self.authToken = authToken
    }
}

/// Generic local HTTP server for automation and integration.
///
/// Runs on `127.0.0.1` (localhost only for security).
/// Uses a generic `Router` to handle app-specific endpoints.
public actor HTTPServer<Router: HTTPRouter> {

    // MARK: - State

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var isRunning = false
    private var currentConfiguration: HTTPServerConfiguration?

    private let router: Router
    private var logger: Logger?

    // MARK: - Initialization

    public init(router: Router) {
        self.router = router
    }

    // MARK: - Lifecycle

    /// Start the HTTP server with the given configuration.
    public func start(configuration: HTTPServerConfiguration) {
        guard !isRunning else {
            logger?.info("HTTP server already running")
            return
        }

        currentConfiguration = configuration
        logger = Logger(subsystem: configuration.loggerSubsystem, category: configuration.loggerCategory)

        let port = NWEndpoint.Port(rawValue: configuration.port)!

        do {
            let parameters = NWParameters.tcp
            if configuration.allowNetworkAccess {
                // Opt-in network mode: listen on ALL interfaces. Note the
                // port-only listener form — pinning requiredLocalEndpoint
                // to 0.0.0.0 makes NWListener unreachable from non-loopback
                // peers (verified empirically); omitting the endpoint is the
                // canonical any-interface bind. Non-loopback peers are gated
                // per-request by HTTPAuthPolicy (bearer token).
                listener = try NWListener(using: parameters, on: port)
            } else {
                // Default: localhost only — the historical guarantee.
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: port
                )
                listener = try NWListener(using: parameters)
            }

            listener?.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.handleListenerState(state) }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.handleNewConnection(connection) }
            }

            listener?.start(queue: .global(qos: .userInitiated))
            isRunning = true
            logger?.info("HTTP server starting on port \(port.rawValue)")

        } catch {
            logger?.error("Failed to start HTTP server: \(error.localizedDescription)")
        }
    }

    /// Stop the HTTP server.
    public func stop() {
        guard isRunning else { return }

        listener?.cancel()
        listener = nil

        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()

        isRunning = false
        logger?.info("HTTP server stopped")
    }

    /// Restart the server with a new configuration.
    public func restart(configuration: HTTPServerConfiguration) async {
        stop()
        try? await Task.sleep(for: .milliseconds(100))
        start(configuration: configuration)
    }

    /// Check if the server is currently running.
    public var running: Bool {
        isRunning
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                logger?.info("HTTP server listening on port \(port.rawValue)")
            }
        case .failed(let error):
            logger?.error("HTTP server listener failed: \(error.localizedDescription)")
            isRunning = false
        case .cancelled:
            logger?.info("HTTP server listener cancelled")
            isRunning = false
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleConnectionState(connection, state: state) }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func handleConnectionState(_ connection: NWConnection, state: NWConnection.State) {
        switch state {
        case .ready:
            receiveRequest(on: connection)
        case .failed(let error):
            logger?.debug("Connection failed: \(error.localizedDescription)")
            removeConnection(connection)
        case .cancelled:
            removeConnection(connection)
        default:
            break
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }

    // MARK: - Request Handling

    private func receiveRequest(on connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let error = error {
                    await self.logger?.debug("Receive error: \(error.localizedDescription)")
                    connection.cancel()
                    return
                }

                var buffer = buffered
                if let data, !data.isEmpty {
                    buffer.append(data)
                }

                guard !buffer.isEmpty else {
                    if isComplete { connection.cancel() }
                    return
                }

                if buffer.count > httpMaxRequestBytes {
                    await self.sendResponse(
                        HTTPResponse.badRequest("Request too large"), on: connection)
                    return
                }

                // A single receive() returns at most one TCP read (~64KB) — a
                // large POST body spans several. Accumulate until the headers
                // AND the full Content-Length body have arrived (this was the
                // "bodies ≳64KB fail JSON parse" truncation bug).
                if httpRequestIsComplete(buffer) || isComplete {
                    await self.processRequest(buffer, on: connection)
                } else {
                    await self.receiveRequest(on: connection, buffered: buffer)
                }
            }
        }
    }
}

/// Upper bound on an accepted request (headers + body). Plot specs with large
/// series legitimately reach several MB; this cap only guards against
/// unbounded memory use on a local port. (File-scope: HTTPServer is a generic
/// actor, which cannot hold static stored properties.)
private let httpMaxRequestBytes = 32 * 1024 * 1024

/// True when `buffer` holds a full HTTP request: complete header block, plus
/// `Content-Length` bytes of body when the header declares one.
private func httpRequestIsComplete(_ buffer: Data) -> Bool {
        let crlfcrlf = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: crlfcrlf) else {
            return false  // headers not finished
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return true  // undecodable — hand to the parser to reject
        }
        var contentLength = 0
        for line in headerString.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                break
            }
        }
        let bodyBytes = buffer.count - (headerEnd.upperBound - buffer.startIndex)
        return bodyBytes >= contentLength
}

extension HTTPServer {
    private func processRequest(_ data: Data, on connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            await sendResponse(HTTPResponse.badRequest("Invalid request encoding"), on: connection)
            return
        }

        // Parse HTTP request
        guard let request = HTTPRequest.parse(requestString) else {
            await sendResponse(HTTPResponse.badRequest("Invalid HTTP request"), on: connection)
            return
        }

        logger?.debug("HTTP \(request.method) \(request.path)")

        // Access policy BEFORE routing: loopback peers pass untouched;
        // non-loopback peers must present the configured bearer token.
        // Indeterminate peers count as remote (fail closed).
        let decision = HTTPAuthPolicy.evaluate(
            peerIsLoopback: Self.isLoopbackPeer(connection),
            allowNetworkAccess: currentConfiguration?.allowNetworkAccess ?? false,
            authToken: currentConfiguration?.authToken,
            authorizationHeader: request.headers["authorization"]
        )
        if case .deny(let reason) = decision {
            logger?.info("HTTP \(request.method) \(request.path) denied (\(reason))")
            await sendResponse(
                HTTPResponse(
                    status: 401,
                    statusText: "Unauthorized",
                    headers: [
                        "WWW-Authenticate": "Bearer",
                        "Content-Type": "application/json; charset=utf-8",
                    ],
                    body: Data("{\"status\":\"error\",\"reason\":\"unauthorized\"}".utf8)
                ),
                on: connection
            )
            return
        }

        // Route the request
        let response = await router.route(request)

        // Log if enabled
        if currentConfiguration?.logRequests == true {
            logger?.info("HTTP \(request.method) \(request.path) -> \(response.status)")
        }

        await sendResponse(response, on: connection)
    }

    /// Whether the connection's transport peer is positively loopback.
    /// Anything indeterminate (named endpoints, missing path info) returns
    /// false — the auth policy treats that as remote.
    static func isLoopbackPeer(_ connection: NWConnection) -> Bool {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return addr.rawValue.first == 127
        case .ipv6(let addr):
            if addr.isLoopback { return true }
            // IPv4-mapped loopback (::ffff:127.x.x.x)
            if let v4 = addr.asIPv4 { return v4.rawValue.first == 127 }
            return false
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) async {
        let responseData = response.toData()

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                Task { await self?.logger?.debug("Send error: \(error.localizedDescription)") }
            }
            connection.cancel()
        })
    }
}
