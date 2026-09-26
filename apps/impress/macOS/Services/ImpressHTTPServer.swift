#if os(macOS)
//
//  ImpressHTTPServer.swift
//  impress
//
//  The local automation server, on impress's row of THE port table
//  (`SiblingApp.descriptors`, ImpressKit — 23125).
//
//  This file and its router are the SMALLEST automation surface in the suite,
//  and deliberately so: everything generic — CORS preflight, `/api/logs`,
//  `/api/logs/stream`, `/api/performance{,/reset}`, `/api/store-timings{,/reset}`
//  — is `SharedAutomationRoutes` (Stage 4b), so the router below adds exactly
//  one route of its own. impel's router is the shape this copies; impel's is
//  1384 lines because impel has a domain. impress's domain IS the store, and
//  the store's agent surface is the Rust `#[impress_service]` layer
//  (`impress-store-service` → MCP/CLI), never a hand-written HTTP handler
//  (CLAUDE.md, "Rust-first logic").
//

import Foundation
import ImpressAutomation
import ImpressKit
import OSLog

private let httpLogger = Logger(subsystem: "com.impress.impress", category: "httpServer")

/// impress's routing table: the shared route group, one status route, nothing
/// else.
public actor ImpressHTTPRouter: HTTPRouter {

    public init() {}

    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        // The GENERIC route group, mounted once. Returns nil for anything it
        // does not own.
        if let shared = await SharedAutomationRoutes.route(request) {
            return shared
        }

        let path = request.path.lowercased()
        if request.method == "GET", path == "/status" || path == "/api/status" {
            return Self.status(for: request)
        }

        return HTTPResponse.notFound()
    }

    /// `/api/status`. Its `port` is the one the request ARRIVED on — the
    /// port this server is bound to, which is what a caller probing several
    /// impress instances needs — and only for a request that does not know
    /// (one built by hand) the port the settings name. It reported the
    /// table's default (plan wave 7 T5's finding 4; implore's half was
    /// #73's); a setting read at request time is a second source that can
    /// disagree with the socket, the socket cannot.
    static func status(for request: HTTPRequest) -> HTTPResponse {
        SharedAutomationRoutes.status(
            app: "impress",
            port: Int(request.localPort ?? ImpressHTTPServer.configuredPort),
            domain: ["shell": "impress", "facets": "all"])
    }
}

/// Local HTTP server for AI agent and MCP integration.
public actor ImpressHTTPServer {

    public static let shared = ImpressHTTPServer()

    /// Default port — THE sibling-app table's row for impress. Never a literal.
    public static let defaultPort: UInt16 = SiblingApp.impress.httpPort

    private static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "httpAutomationEnabled")
    }

    /// The port `start()` binds: the saved or launch-argument
    /// `httpAutomationPort`, else the table's default.
    static var configuredPort: UInt16 {
        let port = UserDefaults.standard.integer(forKey: "httpAutomationPort")
        return port > 0 ? UInt16(port) : defaultPort
    }

    private let server: HTTPServer<ImpressHTTPRouter>
    private let router: ImpressHTTPRouter

    private init() {
        self.router = ImpressHTTPRouter()
        self.server = HTTPServer(router: router)
    }

    public func start() async {
        let alreadyRunning = await server.running
        guard !alreadyRunning else { return }
        guard Self.isEnabled else {
            httpLogger.info("HTTP server is disabled in settings")
            return
        }
        await server.start(
            configuration: HTTPServerConfiguration(
                port: Self.configuredPort,
                loggerSubsystem: "com.impress.impress",
                loggerCategory: "httpServer",
                logRequests: true))
        httpLogger.info("HTTP server started on port \(Self.configuredPort)")
    }

    public func stop() async { await server.stop() }

    public var running: Bool { get async { await server.running } }
}
#endif // os(macOS)
