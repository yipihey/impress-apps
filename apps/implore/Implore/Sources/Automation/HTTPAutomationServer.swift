//
//  HTTPAutomationServer.swift
//  implore
//
//  Local HTTP server for MCP integration and browser extension support.
//  Provides JSON REST API for figure management and export.
//

import Foundation
import ImpressAutomation
import OSLog

private let httpLogger = Logger(subsystem: "com.implore.app", category: "httpServer")

// MARK: - HTTP Automation Server

/// Local HTTP server for automation and integration.
///
/// Runs on `127.0.0.1:23124` (localhost only for security).
/// Provides endpoints for:
/// - `GET /api/status` - Server health and app stats
/// - `GET /api/figures` - List figures
/// - `GET /api/figures/{id}/export` - Export figure as PNG/SVG/PDF
/// - `POST /api/figures` - Create a figure
///
/// Usage:
/// ```swift
/// await HTTPAutomationServer.shared.start()
/// // Later...
/// await HTTPAutomationServer.shared.stop()
/// ```
public actor HTTPAutomationServer {

    // MARK: - Singleton

    public static let shared = HTTPAutomationServer()

    // MARK: - Configuration

    /// Default port (after impel's 23123)
    public static let defaultPort: UInt16 = 23124

    // MARK: - State

    private let server: HTTPServer<ImploreHTTPRouter>
    private let router: ImploreHTTPRouter
    private var isEnabled: Bool = true

    // MARK: - Initialization

    private init() {
        self.router = ImploreHTTPRouter()
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

        guard isEnabled else {
            httpLogger.info("HTTP server is disabled")
            return
        }

        let configuration = HTTPServerConfiguration(
            port: Self.defaultPort,
            loggerSubsystem: "com.implore.app",
            loggerCategory: "httpServer",
            logRequests: true
        )

        await server.start(configuration: configuration)
        httpLogger.info("HTTP server started on port \(Self.defaultPort)")
    }

    /// Stop the HTTP server.
    public func stop() async {
        await server.stop()
        httpLogger.info("HTTP server stopped")
    }

    /// Restart the server.
    public func restart() async {
        let configuration = HTTPServerConfiguration(
            port: Self.defaultPort,
            loggerSubsystem: "com.implore.app",
            loggerCategory: "httpServer",
            logRequests: true
        )

        await server.restart(configuration: configuration)
        httpLogger.info("HTTP server restarted")
    }

    /// Check if the server is currently running.
    public var running: Bool {
        get async {
            await server.running
        }
    }

    /// Enable or disable the HTTP server.
    public func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        if enabled {
            await start()
        } else {
            await stop()
        }
    }
}
