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
/// - `POST /api/documents/{id}/compile` - Compile to PDF
/// - `POST /api/documents/{id}/insert-citation` - Insert citation
///
/// The app snapshots registry values on the main actor, then passes the
/// Sendable configuration to this actor so listener startup stays detached.
@MainActor
enum ImprintAutomationSettings {
    static let credentialDidChange = Notification.Name("ImprintAutomationCredentialDidChange")

    static func snapshot(defaults: UserDefaults = .standard) -> AutomationServerSettings {
        let registry = ImpressSettings.shared
        let savedPort = registry.value("imprint.automation.http_port", as: Int.self)
        let port = (1...Int(UInt16.max)).contains(savedPort)
            ? UInt16(savedPort) : ImprintHTTPServer.defaultPort
        return AutomationServerSettings(
            httpEnabled: registry.value("imprint.automation.http_enabled", as: Bool.self),
            port: port,
            logRequests: registry.value("imprint.automation.log_requests", as: Bool.self),
            allowNetworkAccess: registry.value("imprint.automation.allow_network_access", as: Bool.self),
            // The bearer is intentionally outside the generated, agent-readable
            // settings surface. Keep the existing credential key intact.
            networkAuthToken: defaults.string(forKey: AutomationServerSettings.Keys.networkAuthToken),
            networkBindAddress: registry.value("imprint.automation.network_bind_address", as: String.self)
        ).applyingLaunchOverrides(from: defaults)
    }
}

public actor ImprintHTTPServer {

    // MARK: - Singleton

    public static let shared = ImprintHTTPServer()
    public static let didApplySettings = Notification.Name("ImprintHTTPServerDidApplySettings")

    // MARK: - Configuration

    /// Default port — read from the one sibling-app table
    /// (`SiblingApp.descriptors`) rather than re-declared here.
    public static let defaultPort: UInt16 = SiblingApp.imprint.httpPort

    // MARK: - State

    private let server: HTTPServer<ImprintHTTPRouter>
    private let router: ImprintHTTPRouter
    private var appliedSettings: AutomationServerSettings?

    // MARK: - Initialization

    private init() {
        self.router = ImprintHTTPRouter()
        self.server = HTTPServer(router: router)
    }

    // MARK: - Lifecycle

    /// Apply a main-actor snapshot only when its effective configuration
    /// changed. A settings feed tick must not tear down a live listener.
    public func apply(settings: AutomationServerSettings) async {
        guard appliedSettings != settings else { return }
        let previous = appliedSettings
        appliedSettings = settings
        guard settings.httpEnabled else {
            if previous?.httpEnabled == true { await stop() }
            await announceAppliedSettings()
            return
        }
        if previous?.httpEnabled == true {
            await restart(settings: settings)
        } else {
            await start(settings: settings)
        }
        await announceAppliedSettings()
    }

    private func announceAppliedSettings() async {
        await MainActor.run {
            NotificationCenter.default.post(name: Self.didApplySettings, object: nil)
        }
    }

    /// Start the HTTP server on the snapshotted port.
    public func start(settings: AutomationServerSettings) async {
        let alreadyRunning = await server.running
        guard !alreadyRunning else {
            Logger.httpServer.infoCapture("HTTP server already running", category: "http-server")
            return
        }

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
    public func restart(settings: AutomationServerSettings) async {
        do {
            try ImprintNativeVerbs.install()
        } catch {
            Logger.httpServer.errorCapture("Native verbs unavailable: \(error)", category: "http-server")
            return
        }
        let configuration = HTTPServerConfiguration(settings: settings, loggerSubsystem: "com.imprint.app")

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
