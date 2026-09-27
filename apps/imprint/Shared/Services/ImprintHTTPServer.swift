// The imprint automation HTTP surface is desktop-only for now — it
// drives macOS-only services (Process, AI tasks, intents). A slim iOS
// router for simulator testing is future work (Phase 4).
#if os(macOS)
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
import ImpressKit
import ImpressLogging
import OSLog

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

    /// Default port — read from the one sibling-app table
    /// (`SiblingApp.descriptors`) rather than re-declared here.
    public static let defaultPort: UInt16 = SiblingApp.imprint.httpPort

    // MARK: - Settings

    /// The shared settings (P0, SEC-4): enabled, port, logging and the
    /// network fields, the same six keys in every app.
    private static var settings: AutomationServerSettings {
        AutomationServerSettings.load(defaultPort: defaultPort)
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
            Logger.httpServer.infoCapture("HTTP server already running", category: "http-server")
            return
        }

        let settings = Self.settings
        guard settings.httpEnabled else {
            Logger.httpServer.infoCapture("HTTP server is disabled in settings", category: "http-server")
            return
        }

        do {
            try ImprintNativeVerbs.install()
        } catch {
            Logger.httpServer.errorCapture("Native verbs unavailable: \(error)", category: "http-server")
            return
        }

        let configuration = HTTPServerConfiguration(settings: settings, loggerSubsystem: "com.imprint.app")

        await server.start(configuration: configuration)
        Logger.httpServer.infoCapture("HTTP server started on port \(settings.port)", category: "http-server")
    }

    /// Stop the HTTP server.
    public func stop() async {
        await server.stop()
    }

    /// Restart the server (e.g., after port change).
    public func restart() async {
        do {
            try ImprintNativeVerbs.install()
        } catch {
            Logger.httpServer.errorCapture("Native verbs unavailable: \(error)", category: "http-server")
            return
        }
        let configuration = HTTPServerConfiguration(settings: Self.settings, loggerSubsystem: "com.imprint.app")

        await server.restart(configuration: configuration)
    }

    /// Check if the server is currently running.
    public var running: Bool {
        get async {
            await server.running
        }
    }
}

#endif // os(macOS)
