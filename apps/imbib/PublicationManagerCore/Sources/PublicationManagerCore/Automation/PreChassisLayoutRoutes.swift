//
//  PreChassisLayoutRoutes.swift
//  PublicationManagerCore
//
//  `/api/layout` (GET, POST), `/api/layout/apply` and `/api/layout/save`
//  drive imbib's pre-chassis window: its sidebar / list / detail visibility,
//  detail tab, appearance mirrors and named layouts. That model lives in
//  imbib's app target, with the window that draws it, so this package holds
//  only the hook: the app registers a host, and the router forwards the three
//  routes to it (the `LayoutAutomationHost` pattern).
//
//  No host → 404 with the reason, never a silent `ok`: imbib-iOS and any
//  process without that window has nothing these routes could change. A
//  chassis window is the layout tree, whose routes are `/api/layout/tree`,
//  `/api/layout/verb` and `/api/layout/op` (`SharedAutomationRoutes`).
//

import Foundation

/// One layout route's answer: an HTTP status and a JSON object, already
/// serialized so it crosses from the main actor to the router's actor.
public struct PreChassisLayoutReply: Sendable {
    public let status: Int
    public let json: Data

    public init(status: Int = 200, object: [String: Any]) {
        self.status = status
        self.json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

/// What imbib's own window offers the layout routes.
@MainActor
public protocol PreChassisLayoutRoutesHost: AnyObject {
    /// Answer `path` (`/api/layout`, `/api/layout/apply`, `/api/layout/save`)
    /// for `method`, with the request's raw body.
    func layoutRoute(path: String, method: String, body: Data) -> PreChassisLayoutReply

    /// `POST /api/appearance` wrote the authoritative stores; the window's
    /// model mirrors whichever of the two it was given.
    func appearanceDidChange(appAppearance: String?, pdfDarkMode: Bool?)
}

/// Where imbib's window model registers itself.
@MainActor
public final class PreChassisLayoutRoutes {

    public static let shared = PreChassisLayoutRoutes()

    /// The paths the host answers.
    public nonisolated static let paths: Set<String> = [
        "/api/layout", "/api/layout/apply", "/api/layout/save",
    ]

    public weak var host: PreChassisLayoutRoutesHost?

    private init() {}

    /// The reason a process with no host gives.
    public nonisolated static func unservedReason(_ path: String) -> String {
        "\(path) drives imbib's own window's pane model, and this process has none. "
            + "A chassis window is the layout tree: use /api/layout/tree, /api/layout/verb "
            + "and /api/layout/op."
    }
}
