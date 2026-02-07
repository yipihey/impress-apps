//
//  ImpelHTTPServer.swift
//  impel
//
//  Local HTTP server for AI automation and MCP integration.
//  Provides JSON REST API for thread/agent/escalation operations.
//

import Foundation
import ImpressAutomation
import OSLog

private let httpLogger = Logger(subsystem: "com.impress.impel", category: "httpServer")

// MARK: - HTTP Automation Server

/// Local HTTP server for AI agent and MCP integration.
///
/// Runs on `127.0.0.1:23124` (localhost only for security).
/// Provides endpoints for thread management, agent orchestration,
/// escalation handling, and persona queries.
///
/// Usage:
/// ```swift
/// await ImpelHTTPServer.shared.start()
/// ```
public actor ImpelHTTPServer {

    // MARK: - Singleton

    public static let shared = ImpelHTTPServer()

    // MARK: - Configuration

    /// Default port (after imbib:23120, imprint:23121, impart:23122, implore:23123)
    public static let defaultPort: UInt16 = 23124

    // MARK: - Settings

    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "httpAutomationEnabled")
    }

    private static var configuredPort: UInt16 {
        let port = UserDefaults.standard.integer(forKey: "httpAutomationPort")
        return port > 0 ? UInt16(port) : defaultPort
    }

    // MARK: - State

    private let server: HTTPServer<ImpelHTTPRouter>
    private let router: ImpelHTTPRouter

    // MARK: - Initialization

    private init() {
        self.router = ImpelHTTPRouter()
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
            loggerSubsystem: "com.impress.impel",
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
            loggerSubsystem: "com.impress.impel",
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
