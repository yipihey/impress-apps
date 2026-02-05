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
import ImpressAutomation
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

    // MARK: - Settings

    /// Whether the HTTP server is enabled
    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "httpAutomationEnabled")
    }

    /// The configured port
    private static var configuredPort: UInt16 {
        let port = UserDefaults.standard.integer(forKey: "httpAutomationPort")
        return port > 0 ? UInt16(port) : defaultPort
    }

    // MARK: - State

    private let server: HTTPServer<ImprintHTTPRouter>
    private let router: ImprintHTTPRouter

    // MARK: - Initialization

    private init() {
        self.router = ImprintHTTPRouter()
        self.server = HTTPServer(router: router)
    }

    // MARK: - Lifecycle

    /// Start the HTTP server on the configured port.
    public func start() async {
        let alreadyRunning = await server.running
        guard !alreadyRunning else {
            httpLogger.info("HTTP server already running")
            return
        }

        guard Self.isEnabled else {
            httpLogger.info("HTTP server is disabled in settings")
            return
        }

        let configuration = HTTPServerConfiguration(
            port: Self.configuredPort,
            loggerSubsystem: "com.imbib.imprint",
            loggerCategory: "httpServer",
            logRequests: true
        )

        await server.start(configuration: configuration)
        httpLogger.info("HTTP server started on port \(Self.configuredPort)")
    }

    /// Stop the HTTP server.
    public func stop() async {
        await server.stop()
    }

    /// Restart the server (e.g., after port change).
    public func restart() async {
        let configuration = HTTPServerConfiguration(
            port: Self.configuredPort,
            loggerSubsystem: "com.imbib.imprint",
            loggerCategory: "httpServer",
            logRequests: true
        )

        await server.restart(configuration: configuration)
    }

    /// Check if the server is currently running.
    public var running: Bool {
        get async {
            await server.running
        }
    }
}
