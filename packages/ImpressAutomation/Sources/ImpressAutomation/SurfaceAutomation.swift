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
//  `SharedSurface.surfaceHttp`, which is the same table MCP and the CLI
//  reach. Swift chooses no paths, parses no bodies and invents no statuses —
//  if a route moves in `crates/impress-store-ffi/src/surface.rs`, it moves
//  here for free.
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
    func routeSurfaceRequest(method: String, path: String, body: String) -> (
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
        return await MainActor.run {
            guard let host = SurfaceAutomation.shared.host else {
                // 409, not 404: the route exists, the app cannot serve it
                // (its store is not open yet). A 404 here would read as
                // "this build has no surfaces".
                return HTTPResponse.json(
                    [
                        "status": "error",
                        "error": "no surface host is registered in this app",
                        "detail":
                            "The shared store must be open before the surface routes can "
                            + "answer. Headless callers need no app at all — the same verbs "
                            + "are `impress-surface-service_surface-*` over MCP.",
                    ],
                    status: 409)
            }
            let reply = host.routeSurfaceRequest(method: method, path: fullPath, body: body)
            return HTTPResponse(
                status: reply.status,
                statusText: statusText(reply.status),
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: Data(reply.body.utf8))
        }
    }

    /// Re-attach the query string the router already parsed away, because
    /// Rust's table reads `?pane=` and `?after=` itself.
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

    /// The three statuses `SharedSurface.surfaceHttp` documents.
    static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "Error"
        }
    }
}
