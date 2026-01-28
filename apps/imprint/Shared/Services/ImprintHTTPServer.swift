//
//  ImprintHTTPServer.swift
//  imprint
//
//  Created by Claude on 2026-01-28.
//
//  Local HTTP server for AI automation and MCP integration.
//  Provides JSON REST API for document operations.
//

import Foundation
import Network
import OSLog

private let httpLogger = Logger(subsystem: "com.imbib.imprint", category: "httpServer")

// MARK: - HTTP Automation Server

/// Local HTTP server for AI agent and MCP integration.
///
/// Runs on `127.0.0.1:23121` (localhost only for security).
/// Provides endpoints for:
/// - `GET /api/status` - Server health
/// - `GET /api/documents` - List open documents
/// - `GET /api/documents/{id}` - Get document content/metadata
/// - `POST /api/documents/{id}/compile` - Compile to PDF
/// - `POST /api/documents/{id}/insert-citation` - Insert citation
///
/// Usage:
/// ```swift
/// await ImprintHTTPServer.shared.start()
/// // Later...
/// await ImprintHTTPServer.shared.stop()
/// ```
public actor ImprintHTTPServer {

    // MARK: - Singleton

    public static let shared = ImprintHTTPServer()

    // MARK: - Configuration

    /// Default port (after imbib's 23120)
    public static let defaultPort: UInt16 = 23121

    // MARK: - State

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var isRunning = false

    private let router: ImprintHTTPRouter

    // MARK: - Settings

    /// Whether the HTTP server is enabled
    @MainActor
    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "httpAutomationEnabled")
    }

    /// The configured port
    @MainActor
    private static var configuredPort: UInt16 {
        let port = UserDefaults.standard.integer(forKey: "httpAutomationPort")
        return port > 0 ? UInt16(port) : defaultPort
    }

    // MARK: - Initialization

    private init() {
        self.router = ImprintHTTPRouter()
    }

    // MARK: - Lifecycle

    /// Start the HTTP server on the configured port.
    @MainActor
    public func start() async {
        let alreadyRunning = await isRunningAsync
        guard !alreadyRunning else {
            httpLogger.info("HTTP server already running")
            return
        }

        guard Self.isEnabled else {
            httpLogger.info("HTTP server is disabled in settings")
            return
        }

        let port = NWEndpoint.Port(rawValue: Self.configuredPort) ?? NWEndpoint.Port(rawValue: Self.defaultPort)!

        await startListener(on: port)
    }

    private func startListener(on port: NWEndpoint.Port) {
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
            httpLogger.info("HTTP server starting on port \(port.rawValue)")

        } catch {
            httpLogger.error("Failed to start HTTP server: \(error.localizedDescription)")
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
        httpLogger.info("HTTP server stopped")
    }

    /// Restart the server (e.g., after port change).
    @MainActor
    public func restart() async {
        await stopAsync()
        try? await Task.sleep(for: .milliseconds(100))
        await start()
    }

    private func stopAsync() async {
        stop()
    }

    /// Check if the server is currently running.
    public var running: Bool {
        isRunning
    }

    private var isRunningAsync: Bool {
        isRunning
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                httpLogger.info("HTTP server listening on port \(port.rawValue)")
            }
        case .failed(let error):
            httpLogger.error("HTTP server listener failed: \(error.localizedDescription)")
            isRunning = false
        case .cancelled:
            httpLogger.info("HTTP server listener cancelled")
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
            httpLogger.debug("Connection failed: \(error.localizedDescription)")
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
                    httpLogger.debug("Receive error: \(error.localizedDescription)")
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

        httpLogger.debug("HTTP \(request.method) \(request.path)")

        // Route the request
        let response = await router.route(request)

        httpLogger.debug("HTTP \(request.method) \(request.path) -> \(response.status)")

        await sendResponse(response, on: connection)
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) async {
        let responseData = response.toData()

        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                httpLogger.debug("Send error: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }
}

// MARK: - HTTP Request

/// Simple HTTP request parser.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let queryParams: [String: String]
    public let headers: [String: String]
    public let body: String?

    /// Parse an HTTP request string.
    public static func parse(_ string: String) -> HTTPRequest? {
        let lines = string.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse request line
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }

        let method = requestLine[0]
        let fullPath = requestLine[1]

        // Parse path and query parameters
        let pathComponents = fullPath.components(separatedBy: "?")
        let path = pathComponents[0]

        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            let queryString = pathComponents[1]
            for param in queryString.components(separatedBy: "&") {
                let parts = param.components(separatedBy: "=")
                if parts.count == 2 {
                    let key = parts[0].removingPercentEncoding ?? parts[0]
                    let value = parts[1].removingPercentEncoding ?? parts[1]
                    queryParams[key] = value
                }
            }
        }

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStartIndex: Int?

        for (index, line) in lines.dropFirst().enumerated() {
            if line.isEmpty {
                bodyStartIndex = index + 2  // +1 for dropFirst, +1 for empty line
                break
            }
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                headers[headerParts[0].lowercased()] = headerParts.dropFirst().joined(separator: ": ")
            }
        }

        // Parse body
        var body: String?
        if let startIndex = bodyStartIndex, startIndex < lines.count {
            body = lines[startIndex...].joined(separator: "\r\n")
        }

        return HTTPRequest(
            method: method,
            path: path,
            queryParams: queryParams,
            headers: headers,
            body: body
        )
    }
}

// MARK: - HTTP Response

/// Simple HTTP response builder.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let statusText: String
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, statusText: String, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    /// Convert to HTTP response data.
    public func toData() -> Data {
        var responseString = "HTTP/1.1 \(status) \(statusText)\r\n"

        // Add default headers
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"

        // Add CORS headers for browser/tool requests
        allHeaders["Access-Control-Allow-Origin"] = "*"
        allHeaders["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        allHeaders["Access-Control-Allow-Headers"] = "Content-Type, Authorization"

        for (key, value) in allHeaders {
            responseString += "\(key): \(value)\r\n"
        }
        responseString += "\r\n"

        var responseData = responseString.data(using: .utf8) ?? Data()
        responseData.append(body)
        return responseData
    }

    // MARK: - Factory Methods

    /// Create a JSON response.
    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return HTTPResponse(
                status: status,
                statusText: statusText(for: status),
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        } catch {
            return serverError("JSON serialization failed: \(error.localizedDescription)")
        }
    }

    /// Create a JSON response from Codable.
    public static func jsonCodable<T: Encodable>(_ object: T, status: Int = 200) -> HTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(object)
            return HTTPResponse(
                status: status,
                statusText: statusText(for: status),
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        } catch {
            return serverError("JSON encoding failed: \(error.localizedDescription)")
        }
    }

    /// Create a plain text response.
    public static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            statusText: statusText(for: status),
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: string.data(using: .utf8) ?? Data()
        )
    }

    /// Create a 200 OK response.
    public static func ok(_ body: [String: Any] = [:]) -> HTTPResponse {
        var response = body
        response["status"] = "ok"
        return json(response)
    }

    /// Create a 400 Bad Request response.
    public static func badRequest(_ message: String) -> HTTPResponse {
        json(["status": "error", "error": message], status: 400)
    }

    /// Create a 403 Forbidden response.
    public static func forbidden(_ message: String) -> HTTPResponse {
        json(["status": "error", "error": message], status: 403)
    }

    /// Create a 404 Not Found response.
    public static func notFound(_ message: String = "Not found") -> HTTPResponse {
        json(["status": "error", "error": message], status: 404)
    }

    /// Create a 500 Server Error response.
    public static func serverError(_ message: String) -> HTTPResponse {
        json(["status": "error", "error": message], status: 500)
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
