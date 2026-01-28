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

    public init(
        port: UInt16,
        loggerSubsystem: String,
        loggerCategory: String = "httpServer",
        logRequests: Bool = false
    ) {
        self.port = port
        self.loggerSubsystem = loggerSubsystem
        self.loggerCategory = loggerCategory
        self.logRequests = logRequests
    }
}

/// Generic local HTTP server for automation and integration.
///
/// Runs on `127.0.0.1` (localhost only for security).
/// Uses a generic `Router` to handle app-specific endpoints.
///
/// Usage:
/// ```swift
/// let server = HTTPServer(router: MyRouter())
/// await server.start(configuration: .init(
///     port: 23120,
///     loggerSubsystem: "com.myapp"
/// ))
/// // Later...
/// await server.stop()
/// ```
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
            // Create TCP listener on localhost only
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: port
            )

            listener = try NWListener(using: parameters)

            listener?.stateUpdateHandler = { [weak self] state in
                Task { [weak self] in
                    await self?.handleListenerState(state)
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                Task { [weak self] in
                    await self?.handleNewConnection(connection)
                }
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
            Task { [weak self] in
                await self?.handleConnectionState(connection, state: state)
            }
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

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { [weak self] in
                if let error = error {
                    await self?.logger?.debug("Receive error: \(error.localizedDescription)")
                    connection.cancel()
                    return
                }

                guard let data = data, !data.isEmpty else {
                    if isComplete {
                        connection.cancel()
                    }
                    return
                }

                await self?.processRequest(data, on: connection)
            }
        }
    }

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

        // Route the request
        let response = await router.route(request)

        // Log if enabled
        if currentConfiguration?.logRequests == true {
            logger?.info("HTTP \(request.method) \(request.path) -> \(response.status)")
        }

        await sendResponse(response, on: connection)
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) async {
        let responseData = response.toData()

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                Task { [weak self] in
                    await self?.logger?.debug("Send error: \(error.localizedDescription)")
                }
            }
            connection.cancel()
        })
    }
}
