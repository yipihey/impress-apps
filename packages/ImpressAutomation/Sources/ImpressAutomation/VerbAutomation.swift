//
//  VerbAutomation.swift
//  ImpressAutomation
//
//  P5 transport, server side (ADR-0034 D2): one POST /api/verb/<name>
//  route. The host registers its domain service namespaces against its own
//  UniFFI inventory. Other names go to the kit inventory in ImpressRustCore.
//  Both use the same Rust invoker pipeline; Swift owns no argument schema.
//
//  Domain ownership is chosen before dispatch. A real not-found result is
//  returned intact, never treated as permission to try a different backend.
//  Async domain dispatch lets a native backend await MainActor state without
//  blocking that actor or making a loopback HTTP request to itself.
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

/// The native dispatcher returns Rust's wire body without Swift reshaping it.
public struct VerbDispatchResponse: Sendable {
    public let status: Int
    public let bodyJSON: String

    public init(status: Int, bodyJSON: String) {
        self.status = status
        self.bodyJSON = bodyJSON
    }
}

private final class DomainDispatchers: @unchecked Sendable {
    typealias Dispatch = @Sendable (String, String, String) async -> VerbDispatchResponse
    private let lock = NSLock()
    private var services: [String: Dispatch] = [:]

    func register(_ names: Set<String>, dispatch: @escaping Dispatch) {
        lock.withLock {
            for name in names { services[name] = dispatch }
        }
    }

    func dispatcher(for verb: String) -> Dispatch? {
        guard let separator = verb.firstIndex(of: "_") else { return nil }
        return lock.withLock { services[String(verb[..<separator])] }
    }
}

/// The verb-dispatch half of the shared routing table.
///
/// Mounted by `SharedAutomationRoutes.route(_:)`; nothing calls this
/// directly except its tests.
public enum VerbAutomationRoutes {
    private static let domains = DomainDispatchers()

    /// Install the app-owned FFI for these service namespaces. Ownership is
    /// selected before invocation: a domain's business refusal, including a
    /// missing record, must never be retried against another store or backend.
    public static func registerDomainDispatcher(
        services: Set<String>,
        dispatch: @escaping @Sendable (String, String, String) async -> VerbDispatchResponse
    ) {
        domains.register(services, dispatch: dispatch)
    }

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
        if let dispatch = domains.dispatcher(for: name) {
            let result = await dispatch(name, argsJSON, callerJSON)
            return HTTPResponse(
                status: result.status,
                statusText: statusText(result.status),
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: Data(result.bodyJSON.utf8))
        }
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
