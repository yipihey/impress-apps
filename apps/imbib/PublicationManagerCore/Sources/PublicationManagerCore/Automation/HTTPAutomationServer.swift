//
//  HTTPAutomationServer.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-27.
//
//  Local HTTP server for browser extension and web integration.
//  Provides JSON REST API for citation search and BibTeX export.
//  Similar to Zotero's local server on port 23119.
//

import Foundation
import ImpressAutomation
import OSLog

private let httpLogger = Logger(subsystem: "com.imbib.app", category: "httpServer")

// MARK: - HTTP Automation Server

/// Local HTTP server for browser extension communication.
///
/// Runs on `127.0.0.1:23120` (localhost only for security).
/// Provides endpoints for:
/// - `GET /api/status` - Server health and library stats
/// - `GET /api/search?q=...` - Search library
/// - `GET /api/papers/{citeKey}` - Get paper with BibTeX
/// - `GET /api/export?keys=...` - Export BibTeX for cite keys
/// - `GET /api/collections` - List collections
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

    /// Default port (after Zotero's 23119)
    public static let defaultPort: UInt16 = 23120

    // MARK: - State

    private let server: HTTPServer<HTTPAutomationRouter>
    private let router: HTTPAutomationRouter

    // MARK: - Initialization

    private init() {
        self.router = HTTPAutomationRouter()
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

        let settings = await AutomationSettingsStore.shared.settings
        guard settings.isHTTPServerEnabled else {
            httpLogger.info("HTTP server is disabled in settings")
            return
        }

        let configuration = HTTPServerConfiguration(
            port: settings.httpServerPort,
            loggerSubsystem: "com.imbib.app",
            loggerCategory: "httpServer",
            logRequests: settings.logRequests
        )

        await server.start(configuration: configuration)
    }

    /// Stop the HTTP server.
    public func stop() async {
        await server.stop()
    }

    /// Restart the server (e.g., after port change).
    public func restart() async {
        let settings = await AutomationSettingsStore.shared.settings

        let configuration = HTTPServerConfiguration(
            port: settings.httpServerPort,
            loggerSubsystem: "com.imbib.app",
            loggerCategory: "httpServer",
            logRequests: settings.logRequests
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
