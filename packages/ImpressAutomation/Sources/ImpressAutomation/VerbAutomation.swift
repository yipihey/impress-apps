//
//  VerbAutomation.swift
//  ImpressAutomation
//
//  P5 transport, server side (plan-verb-pipeline-and-transport.md § P5,
//  ADR-0034 D2): `POST /api/verb/<name>` for every app, one door down from
//  `LayoutAutomationRoutes` and `SurfaceAutomationRoutes` but simpler than
//  either — no live-window host to find, because a verb dispatch needs
//  only the process-wide store to be open, which `impress-store-ffi` and
//  its `dispatch_verb` already assume (the same assumption `LoopbackToken`
//  makes calling into this package's existing `ImpressRustCore` link — see
//  its file header). No registration, no weak reference to a controller:
//  this route is a direct call.
//
//  THE ROUTE IS RUST'S TO ANSWER. `dispatch_verb` (`impress-store-ffi`)
//  looks the verb up in whatever `*-service` crates this app's binary
//  links, runs it through `impress_service_core::pipeline::invoke_blocking`
//  — the same chain MCP, the CLI and every other entry path runs through —
//  and hands back a status and a wire-convention body. Swift maps a path
//  segment to a name and a header to a caller; it decides no verb
//  semantics (P5a scope note: today every app's binary links the same
//  `impress-store-ffi`, which links `implore-service` unconditionally —
//  see that crate's `verb.rs` module doc for why and what P5b narrows).
//
//  CALLER IDENTITY (ADR-0034 D3). This route only answers a request that
//  already passed `HTTPAuthPolicy` (the P0 loopback token, or the network
//  bearer) — `HTTPServer.processRequest` enforces that before any router
//  runs. Having passed it, the caller is `CallerIdentity::App(<this app's
//  name>)`: never a claim the body makes. A future agent-style caller (an
//  MCP host reaching this route on a non-loopback bearer) is out of P5a's
//  scope; `caller_json`'s `kind`/`name` shape already leaves room for it
//  (`dispatch_verb`'s `parse_caller`), and this route would only need to
//  read one more header to fill it in.
//
//  TRACEPARENT (hook H-P5-1). The `traceparent` request header, when
//  present, is passed straight through as `caller_json.trace_id` so the
//  pipeline's span/audit joins the caller's own trace instead of minting a
//  fresh one every hop.
//
//  THE WIRE CONVENTION is the same one `/api/layout/*` and `/api/surface/*`
//  already answer — see `LayoutAutomation.swift`'s file header:
//  snake_case, `"wire_version"`, `{"ok": false, "code", "message"}` on
//  refusal — because `dispatch_verb` builds the body itself; this route
//  never reshapes it.
//

import Foundation
import ImpressRustCore

/// The verb-dispatch half of the shared routing table.
///
/// Mounted by `SharedAutomationRoutes.route(_:)`; nothing calls this
/// directly except its tests.
public enum VerbAutomationRoutes {

    /// `impress_service_core::wire::WIRE_VERSION` — see
    /// `LayoutAutomationRoutes.wireVersion`'s comment for why this package
    /// keeps its own copy rather than reading it from a Rust export: the
    /// wire body itself already carries it, this constant is only for the
    /// route's own refusals (no host registered, an unrecognised path).
    public static let wireVersion = 1

    static let prefix = "/api/verb/"

    static func matches(_ path: String) -> Bool {
        path.hasPrefix(prefix) && path.count > prefix.count
    }

    static func route(_ path: String, method: String, request: HTTPRequest) async -> HTTPResponse? {
        guard matches(path), method == "POST" else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty else { return nil }

        let argsJSON = request.body ?? "{}"
        let callerJSON = callerJSONFor(request)
        // `dispatch_verb` runs the pipeline's own handler under
        // `invoke_blocking` — blocking, on the caller's thread, exactly
        // like `applyLayoutVerb`'s FFI call already does from this same
        // server. Off the actor running `HTTPServer.processRequest`'s
        // dispatch would be nicer; matching the layout route's existing
        // behaviour here is deliberate rather than an oversight (it is a
        // store-backed call, not a network one, so it is fast).
        let result = dispatchVerb(name: name, argsJson: argsJSON, callerJson: callerJSON)
        return HTTPResponse(
            status: Int(result.status),
            statusText: statusText(Int(result.status)),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data(result.bodyJson.utf8))
    }

    /// `{"kind": "app", "name": <this app>, "trace_id": <traceparent, if
    /// any>}` — `dispatch_verb`'s `parse_caller` shape (ADR-0034 D3, hook
    /// H-P5-1). The app name comes from the bundle identifier's last
    /// component (`com.impress.implore` → `implore`), which every app
    /// already carries and needs no new lookup.
    static func callerJSONFor(_ request: HTTPRequest) -> String {
        var caller: [String: Any] = ["kind": "app"]
        if let name = Bundle.main.bundleIdentifier?.components(separatedBy: ".").last {
            caller["name"] = name
        }
        if let traceparent = request.headers["traceparent"], !traceparent.isEmpty {
            caller["trace_id"] = traceparent
        }
        return (try? JSONSerialization.data(withJSONObject: caller))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"kind\":\"app\"}"
    }

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
