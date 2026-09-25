//
//  SurfaceAutomation.swift
//  ImpressAutomation
//
//  `/api/surface` and `/api/surface/…` for every chassis app, not just imbib.
//
//  S7 mounted these in `HTTPAutomationRouter`, which is imbib's router on
//  port 23120. The app that renders surfaces is **impress** (the layout tree
//  is behind `com.impress.impress`'s flag), and impress's router is the
//  smallest one in the suite: the shared group plus `/api/status`. So the
//  routes the hand-off asks to curl on 23125 answered 404 there — verified
//  live on 2026-09-22 — while the same paths worked on 23120, where no
//  surface pane is rendering.
//
//  This is `LayoutAutomationRoutes` one door down, and deliberately the same
//  shape: the group owns the paths and the failure mode, a registered HOST
//  owns everything that needs a store handle or a Rust type. That keeps
//  ImpressAutomation free of ImpressRustCore (it has never linked it) while
//  every app that mounts the shared group gains the surface surface.
//
//  THE ROUTE TABLE IS RUST'S. The host forwards method + path + body to
//  `SharedSurface.surfaceHttp`, where each route runs the surface verb of
//  the same name through the argument parser MCP and the CLI use, and
//  answers that verb's result (wave 7 T6a; the table is in
//  docs/agent-surfaces.md). Swift chooses no paths, parses no bodies and
//  invents no statuses — if a route moves in
//  `crates/impress-store-ffi/src/surface.rs`, it moves here for free.
//

import Foundation

// MARK: - The host

/// The object that can answer an `/api/surface/…` request — in practice the
/// chassis' store adapter, which owns the `SharedStore` handle the Rust route
/// table needs.
@MainActor
public protocol SurfaceAutomationHost: AnyObject {

    /// Route one request through `SharedSurface.surfaceHttp`.
    ///
    /// `path` already carries its query string; `body` is the raw request
    /// body (empty for methods that take none). The reply is Rust's own
    /// status and JSON body, passed through untouched.
    ///
    /// `async`: `surfaceHttp` runs sources and effects — verb calls that may
    /// be HTTP round trips to another app — on Rust's own runtime, and the
    /// main actor is suspended, not blocked, while it does (wave 7, SK-K2).
    func routeSurfaceRequest(method: String, path: String, body: String) async -> (
        status: Int, body: String
    )
}

/// Where the app announces it can serve surfaces.
@MainActor
public final class SurfaceAutomation {

    public static let shared = SurfaceAutomation()

    /// Weak, like `LayoutAutomation.host`: the registry must never be the
    /// reason a store adapter outlives its app.
    public weak var host: SurfaceAutomationHost?

    public var isActive: Bool { host != nil }

    private init() {}
}

// MARK: - The routes

/// The surface half of the shared routing table.
public enum SurfaceAutomationRoutes {

    /// `/api/surface` exactly, or anything beneath it. Unlike the other
    /// groups this is a PREFIX match, because the sub-paths
    /// (`/<id>/render`, `/<id>/dispatch`, `/<id>/events`, …) are Rust's to
    /// name — see the file header.
    static func matches(_ path: String) -> Bool {
        path == "/api/surface" || path.hasPrefix("/api/surface/")
    }

    static func route(_ path: String, method: String, request: HTTPRequest) async -> HTTPResponse? {
        guard matches(path) else { return nil }
        let fullPath = pathWithQuery(path, params: request.queryParams)
        let body = request.body ?? ""
        return await answer(method: method, path: fullPath, body: body)
    }

    /// On the main actor only to find the host; the host's own `await` of
    /// Rust suspends it rather than holding it.
    @MainActor
    private static func answer(method: String, path: String, body: String) async -> HTTPResponse {
        guard let host = SurfaceAutomation.shared.host else {
            // 503, not 404: the route exists, the app cannot serve it yet
            // (its store is not open). A 404 here would read as "this build
            // has no surfaces". The body is the wire's refusal envelope.
            return HTTPResponse.json(
                [
                    "ok": false,
                    "code": "store-unavailable",
                    "message":
                        "no surface host is registered in this app: the shared store must be "
                        + "open before the surface routes can answer. Headless callers need no "
                        + "app at all — the same verbs are impress-surface-service_surface-* "
                        + "over MCP.",
                    "wire_version": 1,
                ],
                status: 503)
        }
        let reply = await host.routeSurfaceRequest(method: method, path: path, body: body)
        return HTTPResponse(
            status: reply.status,
            statusText: statusText(reply.status),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data(reply.body.utf8))
    }

    /// Re-attach the query string the router already parsed away, because
    /// Rust's table reads `?host=`, `?after_seq=`, `?timeout_ms=` itself.
    static func pathWithQuery(_ path: String, params: [String: String]) -> String {
        guard !params.isEmpty else { return path }
        let query = params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encoded =
                    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
        return "\(path)?\(query)"
    }

    /// The statuses `impress_service_core::refusal::http_status` maps a
    /// refusal's code to.
    static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
