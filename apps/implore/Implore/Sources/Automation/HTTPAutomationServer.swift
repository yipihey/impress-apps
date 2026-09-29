//
//  HTTPAutomationServer.swift
//  implore
//
//  Local HTTP server for viewer requests and browser extension support.
//  Provides viewer exports, plots and the shared automation endpoints.
//

import Foundation
import ImpressAutomation
import ImpressKit
import ImpressLogging

// MARK: - HTTP Automation Server

/// Local HTTP server for automation and integration.
///
/// Runs on `127.0.0.1:23123` (localhost only for security).
/// Provides endpoints for:
/// - `GET /api/status` - Server health and app stats
/// - `GET /api/rg/slice/png` and `/api/plot/*` - Viewer exports and plots
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

    /// Default port. Read from THE sibling-app table
    /// (`SiblingApp.descriptors` in ImpressKit), not declared here: siblings
    /// dial implore at `SiblingApp.implore.httpPort`, so the server has to bind
    /// what the published address says. It used to declare 23124 — impel's
    /// port — which meant whichever app launched first won the socket and the
    /// loser's automation API silently never came up.
    public static let defaultPort: UInt16 = SiblingApp.implore.httpPort

    /// The port to bind: `httpAutomationPort` from the defaults, else
    /// `defaultPort`. implore has no settings pane that writes it, so it is
    /// set only by a launch argument (`-httpAutomationPort 23181`, the
    /// volatile argument domain), which is how a second implore (a branch
    /// build under test) runs beside the user's without taking its socket.
    /// The same key and rule as impress's, imprint's and impel's servers.
    public static var configuredPort: UInt16 { settings.port }

    /// The shared settings (P0, SEC-4): enabled, port, logging and the
    /// network fields, the same six keys in every app.
    static var settings: AutomationServerSettings {
        AutomationServerSettings.load(defaultPort: defaultPort)
    }

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
            logInfo("HTTP server already running", category: "http-server")
            return
        }

        let settings = Self.settings
        guard isEnabled, settings.httpEnabled else {
            logInfo("HTTP server is disabled", category: "http-server")
            return
        }

        let configuration = HTTPServerConfiguration(settings: settings, loggerSubsystem: "com.implore.app")

        await server.start(configuration: configuration)
        logInfo("HTTP server started on port \(settings.port)", category: "http-server")
    }

    /// Stop the HTTP server.
    public func stop() async {
        await server.stop()
        logInfo("HTTP server stopped", category: "http-server")
    }

    /// Restart the server.
    public func restart() async {
        let configuration = HTTPServerConfiguration(settings: Self.settings, loggerSubsystem: "com.implore.app")

        await server.restart(configuration: configuration)
        logInfo("HTTP server restarted", category: "http-server")
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
