//
//  LayoutAutomation.swift
//  ImpressAutomation
//
//  The ADR-0031 layout tree over HTTP automation, for every app at once.
//
//  WHY THIS IS SHARED AND NOT imbib's. The tree is the chassis' layout model,
//  not one app's: `ChassisRootView` renders it for whichever app is hosting,
//  and the five shipped presets are "what each app IS" (ADR-0031 D10). An
//  automation surface written into one router would have to be re-typed into
//  the other four — which is exactly the history `SharedAutomationRoutes`
//  exists to end (ADR-0022 D9 finding 4: the fourth adopter retyping is what
//  turned a duplication into a finding).
//
//  WHAT WAS THERE BEFORE. imbib's `/api/layout`, `/api/layout/apply` and
//  `/api/layout/save` drive the pre-tree Boolean model of imbib's own window
//  (`sidebarVisible`, `detailPaneVisible`, `detailTab`), which lives in
//  imbib's app target and answers through the host imbib registers with its
//  router. Every CHASSIS window is the layout tree (plan wave 6 W5 removed
//  the flag), and none of them serves those routes. They carry `model: "pane-layout-state"` so an agent can tell
//  which of the two models it drove.
//
//  THE VOCABULARY STAYS IN ONE PLACE. This package must not learn
//  `impress_layout::Verb`: the verbs are Rust's, the Swift spelling is
//  `LayoutVerb` in the chassis, and a third copy here could disagree with
//  both. So the routes below are a thin envelope over a HOST — the object
//  that owns the live tree registers itself, and the verb body is forwarded
//  verbatim as JSON to `SharedLayout.apply(verbJson:actor:)`. New verbs in
//  Rust are reachable over HTTP the day they land, with nothing to add here.
//
//  ACTOR. Every mutation from this surface is attributed to `"agent"`, never
//  to `"human"`, so the undo rings and the log can tell a script's split from
//  a person's (ADR-0031 D7).
//
//  No tree rendering → **409**, with the reason. Not a 200 with an empty
//  body, and not a 404: the route exists, the tree does not.
//

import Foundation

// MARK: - The host

/// What an app's live layout tree must offer for the HTTP routes to drive it.
///
/// Implemented by the chassis' `LayoutController` (PublicationManagerCore,
/// macOS). Everything is `[String: Any]` JSON in both directions because the
/// one thing this package must NOT hold is the verb vocabulary — see the file
/// header.
@MainActor
public protocol LayoutAutomationHost: AnyObject {

    /// The app whose tree this is: `"imbib"`, `"imprint"`, …
    var layoutAppID: String { get }

    /// The whole live tree — windows, tiles, channels — plus `version` and
    /// `focused`. The same value `GET /api/layout/tree` returns.
    func layoutTreeJSON() -> [String: Any]

    /// Apply one `impress_layout::Verb`, given in its own serde spelling.
    /// Throws with a human-readable message when Rust refuses it.
    func applyLayoutVerb(_ verb: [String: Any]) throws -> [String: Any]

    /// The operations that are not `Verb` cases — `undo`, `redo`,
    /// `resize-share`, `save-layout`, `apply-layout`, `delete-layout`. `body`
    /// is the request's JSON object.
    func applyLayoutOperation(_ operation: String, body: [String: Any]) throws -> [String: Any]

    /// The saved layouts, in ⌃⌘1–9 order.
    func savedLayoutsJSON() -> [[String: Any]]
}

/// Where the live tree announces itself.
///
/// The chassis sets this when `LayoutTreeHost` opens a controller and clears
/// it when the window goes away, so "is a tree rendering?" is one optional
/// rather than a flag that can outlive the thing it describes.
@MainActor
public final class LayoutAutomation {

    public static let shared = LayoutAutomation()

    /// Weak: the controller belongs to the window, and a registry that kept it
    /// alive would answer verbs into a tree nobody is looking at.
    public weak var host: LayoutAutomationHost?

    private init() {}
}

// MARK: - The routes

/// The layout-tree half of the shared routing table.
///
/// Mounted by `SharedAutomationRoutes.route(_:)`; nothing calls this directly
/// except its tests.
public enum LayoutAutomationRoutes {

    /// The actor every mutation from HTTP is attributed to.
    public static let actor = "agent"

    public static let paths: Set<String> = [
        "/api/layout/tree",
        "/api/layout/verb",
        "/api/layout/op",
        "/api/layout/layouts",
    ]

    /// The operations `/api/layout/op` forwards. Kept here so a typo answers
    /// 400 with the list rather than reaching the host as an unknown string.
    public static let operations: Set<String> = [
        "undo", "redo", "resize-share", "save-layout", "apply-layout", "delete-layout",
    ]

    static func route(_ path: String, method: String, request: HTTPRequest) async -> HTTPResponse? {
        switch (path, method) {
        case ("/api/layout/tree", "GET"):
            return await withHost { host in
                var payload = host.layoutTreeJSON()
                payload["status"] = "ok"
                payload["app"] = host.layoutAppID
                return .json(payload)
            }

        case ("/api/layout/layouts", "GET"):
            return await withHost { host in
                let rows = host.savedLayoutsJSON()
                return .json(["status": "ok", "app": host.layoutAppID, "layouts": rows])
            }

        case ("/api/layout/verb", "POST"):
            guard let body = jsonBody(request) else {
                return .badRequest(
                    "Expected an impress_layout::Verb JSON object, e.g. "
                        + #"{"verb":"focus","target":{"ref":"role","role":"detail"}}"#)
            }
            return await withHost { host in
                do {
                    var payload = try host.applyLayoutVerb(body)
                    payload["status"] = "ok"
                    return .json(payload)
                } catch {
                    return refused(error)
                }
            }

        case ("/api/layout/op", "POST"):
            guard let body = jsonBody(request), let op = body["op"] as? String else {
                return .badRequest(
                    "Expected {\"op\": ...} — one of "
                        + operations.sorted().joined(separator: ", "))
            }
            guard operations.contains(op) else {
                return .badRequest(
                    "Unknown layout operation '\(op)'. Known: "
                        + operations.sorted().joined(separator: ", ")
                        + ". Tree-shaped verbs go to POST /api/layout/verb.")
            }
            return await withHost { host in
                do {
                    var payload = try host.applyLayoutOperation(op, body: body)
                    payload["status"] = "ok"
                    return .json(payload)
                } catch {
                    return refused(error)
                }
            }

        default:
            return nil
        }
    }

    // MARK: Helpers

    /// Run `work` against the live tree, or answer 409.
    ///
    /// The hop to the MainActor is here and nowhere else: the host is the
    /// window's controller, and every read of it is a read of view state.
    private static func withHost(
        _ work: @MainActor @escaping (LayoutAutomationHost) -> HTTPResponse
    ) async -> HTTPResponse {
        await MainActor.run {
            guard let host = LayoutAutomation.shared.host else {
                return HTTPResponse.json(
                    [
                        "status": "error",
                        "error": "no layout tree is rendering in this app",
                        "detail":
                            "Every chassis app's window is the ADR-0031 layout tree (impress, impel, "
                            + "implore, impart, imprint), so there this answer means the window has not "
                            + "opened its tree yet. imbib's own window is its pre-chassis ContentView "
                            + "and has no tree. Headless callers do not need the app at all — "
                            + "the same verbs are `layout-service_*` over MCP and `impress <verb>` in the CLI.",
                    ],
                    status: 409)
            }
            return work(host)
        }
    }

    /// A verb Rust refused is a 422, not a 500: the request was well-formed
    /// and the tree said no (last pane of a window, unknown role, …).
    private static func refused(_ error: Error) -> HTTPResponse {
        .json(
            ["status": "error", "error": String(describing: error)],
            status: 422)
    }

    private static func jsonBody(_ request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body, let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
