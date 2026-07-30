//
//  SharedAutomationRoutes.swift
//  ImpressAutomation
//
//  Stage 4b: the GENERIC half of every app's HTTP routing table, once.
//
//  `LogEndpointHandler` has been shared since the log endpoints were unified —
//  but the ROUTING TABLE was not, so all five app routers hand-pasted the same
//  `if path == "/api/logs" { … }` chain, and four of them then diverged in ways
//  nobody chose:
//
//    * `/api/logs/stream` existed in imprint ONLY, even though the handler it
//      calls has always been in this package. imbib, impart, implore and impel
//      404'd a route they already had the code for.
//    * `/api/performance` and `/api/store-timings` were copied between imprint
//      and imbib character-for-character — and then `/api/store-timings/reset`
//      drifted to POST in one app and GET in the other, and
//      `/api/performance/reset` answered `{"status":"ok","reset":true}` in one
//      and `{"status":"ok"}` in the other.
//    * `handleCORSPreflight()` was five identical private methods.
//
//  `HTTPRouter` has no registration API — it is one `route(_:) async ->
//  HTTPResponse` method per app, dispatching through an `if`/`switch` chain — so
//  "mountable route group" here means a function that answers the generic paths
//  and returns `nil` for everything else. A router mounts it with one line at
//  the top of its dispatch and keeps only its domain routes:
//
//  ```swift
//  if let response = await SharedAutomationRoutes.route(request) { return response }
//  ```
//
//  NOT included, deliberately:
//
//    * `/api/search`. Same path, incompatible semantics: imprint requires `q`
//      (400 without it) and returns section hits under `results`; imbib treats a
//      missing `q` as "" , takes nine filter params, returns papers under
//      `papers`, and has authorization arms. Sharing the path would mean
//      choosing one app's contract for the other's agents. `searchEnvelope`
//      below shares the part that IS common — the envelope keys — and nothing
//      more.
//    * `/` and `/api` info. The envelope is shared, the endpoint inventory is
//      per app by definition.
//    * auth and request logging. Those live in `HTTPServer.processRequest`
//      (`HTTPAuthPolicy.evaluate` + `logRequests`), above every router.
//
//  WIRE COMPATIBILITY. Response shapes are byte-compatible with what each app
//  emitted before, with three ADDITIVE differences (no consumer reads a removed
//  key, because none is removed):
//
//    1. `statusPayload` emits BOTH `port` and `serverPort` with the same value.
//       imbib emitted only `serverPort` (read by `ServerInfo.server_port` in
//       `crates/impress-app-client`); the other four emitted only `port`, while
//       `ImprintServerInfo` in that same crate has always *expected*
//       `serverPort` and silently received `None`. Emitting both keeps every
//       existing reader working and fixes the latent mismatch.
//    2. `statusPayload` always includes `app`. imbib's status had no `app` key.
//    3. The reset routes answer `{"status":"ok","reset":true}` and accept GET or
//       POST — the union of what imprint and imbib each accepted.
//
//  The `/api/logs` shape is untouched, which matters more than it looks: all
//  four Rust `get_logs` implementations read `data.entries[]` with a top-level
//  `entries` fallback, and a rename there returns an EMPTY LIST rather than an
//  error — indistinguishable from "no logs yet".
//

import Foundation
import ImpressLogging

/// The generic route group every impress app's router mounts.
public enum SharedAutomationRoutes {

    // MARK: - Mount point

    /// The paths this group answers. Exposed so a router (or a test) can assert
    /// it is not shadowing one with a domain route of its own.
    public static let paths: Set<String> = [
        "/api/logs",
        "/api/logs/stream",
        "/api/performance",
        "/api/performance/reset",
        "/api/store-timings",
        "/api/store-timings/reset",
    ]

    /// Answer `request` if it is one of the generic routes; return `nil` to let
    /// the caller fall through to its own dispatch.
    ///
    /// Path matching is lowercased-and-trailing-slash-tolerant because the five
    /// routers disagreed about which normalisation they applied
    /// (`request.path.lowercased()` in three, `pathLower` alongside the original
    /// in imprint, raw in one branch of impel).
    ///
    /// - Parameter includeCORSPreflight: answers any `OPTIONS` request with the
    ///   204 + `Access-Control-*` response all five routers had a private copy
    ///   of. A router that wants to handle `OPTIONS` itself passes `false`.
    public static func route(
        _ request: HTTPRequest,
        includeCORSPreflight: Bool = true
    ) async -> HTTPResponse? {
        if includeCORSPreflight, request.method.uppercased() == "OPTIONS" {
            return corsPreflight()
        }

        let path = normalize(request.path)
        let method = request.method.uppercased()

        switch path {
        case "/api/logs":
            guard method == "GET" else { return nil }
            return await LogEndpointHandler.handle(request)

        case "/api/logs/stream":
            guard method == "GET" else { return nil }
            return await LogEndpointHandler.handleStream(request)

        case "/api/performance":
            guard method == "GET" else { return nil }
            return performance()

        case "/api/store-timings":
            guard method == "GET" else { return nil }
            return storeTimings(request)

        // Reset accepts GET or POST: imprint registered POST, imbib registered
        // GET, and an agent that learned one against the wrong app got a 404.
        case "/api/performance/reset":
            guard method == "GET" || method == "POST" else { return nil }
            PerfMetrics.shared.reset()
            return .json(["status": "ok", "reset": true])

        case "/api/store-timings/reset":
            guard method == "GET" || method == "POST" else { return nil }
            StoreTimings.shared.reset()
            return .json(["status": "ok", "reset": true])

        default:
            return nil
        }
    }

    /// Lowercase, and drop a single trailing slash on anything but the root.
    static func normalize(_ path: String) -> String {
        let lower = path.lowercased()
        guard lower.count > 1, lower.hasSuffix("/") else { return lower }
        return String(lower.dropLast())
    }

    // MARK: - CORS

    /// The 204 preflight answer all five routers carried privately.
    public static func corsPreflight() -> HTTPResponse {
        HTTPResponse(
            status: 204,
            statusText: "No Content",
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400",
            ]
        )
    }

    // MARK: - /api/status

    /// The shared `/api/status` envelope, with the app's domain counts merged in.
    ///
    /// `/api/status` cannot be mounted wholesale: every app's domain fields come
    /// from a different actor-isolated read (a Core Data background task in
    /// impart, a `MainActor.run` in imprint, an orchestrator query in impel), so
    /// the ROUTE stays per app and only the envelope is shared. That envelope is
    /// what `crates/impress-app-client` decodes and what the MCP reachability
    /// probe gates every app-scoped tool on — `status` is the one field it
    /// requires, and losing it turns all of Tier B into silent skips.
    ///
    /// - Parameters:
    ///   - app: the app's short name, e.g. `"imprint"`.
    ///   - port: the port the server is bound to. Emitted as BOTH `port` and
    ///     `serverPort`; see the file header.
    ///   - version: defaults to `CFBundleShortVersionString`, falling back to
    ///     `"1.0.0"` (what the two apps without a bundle read hard-coded).
    ///   - domain: the app's own counts. Wins over the envelope on key collision,
    ///     so an app can still override `version` or add its own `port` spelling.
    public static func statusPayload(
        app: String,
        port: Int,
        version: String? = nil,
        domain: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "status": "ok",
            "app": app,
            "version": version
                ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "1.0.0",
            "port": port,
            "serverPort": port,
        ]
        for (key, value) in domain { payload[key] = value }
        return payload
    }

    /// `statusPayload(...)` as a response.
    public static func status(
        app: String,
        port: Int,
        version: String? = nil,
        domain: [String: Any] = [:]
    ) -> HTTPResponse {
        .json(statusPayload(app: app, port: port, version: version, domain: domain))
    }

    // MARK: - /api/search envelope

    /// The three keys imprint's and imbib's `/api/search` genuinely agree on.
    ///
    /// The rest of that route is NOT shared — see the file header. This exists so
    /// a new app's search answers `{status, query, count}` the same way rather
    /// than inventing a fourth spelling, and so the divergence stays visible as
    /// "these two add different result keys" instead of two unrelated handlers.
    public static func searchEnvelope(
        query: String,
        count: Int,
        resultsKey: String,
        results: [[String: Any]],
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "status": "ok",
            "query": query,
            "count": count,
            resultsKey: results,
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    // MARK: - /api/performance

    /// `PerfMetrics.shared.snapshot()` as JSON — per-operation buckets (compile,
    /// render, search, store, snapshot, http, throughline) with count, min/mean/
    /// max, p50/p95, main-thread share and budget-breach counts. The
    /// machine-readable form of the Console "Performance" tab, so an agent can
    /// spot bottlenecks headlessly.
    ///
    /// Byte-identical to the two hand-pasted copies, rounding included.
    public static func performance() -> HTTPResponse {
        let snap = PerfMetrics.shared.snapshot()
        let buckets: [[String: Any]] = snap.buckets.map { b in
            var dict: [String: Any] = [
                "name": b.name,
                "count": b.count,
                "mainThreadCount": b.mainThreadCount,
                "mainThreadShare": round(b.mainThreadShare * 10000) / 10000,
                "minMillis": round(b.minMillis * 1000) / 1000,
                "meanMillis": round(b.meanMillis * 1000) / 1000,
                "p50Millis": round(b.p50Millis * 1000) / 1000,
                "p95Millis": round(b.p95Millis * 1000) / 1000,
                "maxMillis": round(b.maxMillis * 1000) / 1000,
                "breachCount": b.breachCount,
                "totalNanos": b.totalNanos,
            ]
            if let budget = b.budgetMillis {
                dict["budgetMillis"] = round(budget * 1000) / 1000
            }
            return dict
        }
        return .json([
            "status": "ok",
            "capturedAt": ISO8601DateFormatter().string(from: snap.capturedAt),
            "bucketCount": snap.buckets.count,
            "buckets": buckets,
        ])
    }

    // MARK: - /api/store-timings

    /// `StoreTimings.shared.snapshot()` as JSON — per-caller counts, mean/max
    /// latencies, and how much of it happened on the main thread.
    ///
    /// - Parameter request: read for `?top=N` (default 20).
    public static func storeTimings(_ request: HTTPRequest) -> HTTPResponse {
        let top = Int(request.queryParams["top"] ?? "20") ?? 20
        let snap = StoreTimings.shared.snapshot(topCallerCount: top)
        let callers: [[String: Any]] = snap.topCallers.map { stat in
            [
                "caller": stat.caller,
                "count": stat.count,
                "mainThreadCount": stat.mainThreadCount,
                "meanMillis": round(stat.meanMillis * 1000) / 1000,
                "maxMillis": round(stat.maxMillis * 1000) / 1000,
                "totalNanos": stat.totalNanos,
            ]
        }
        return .json([
            "status": "ok",
            "capturedAt": ISO8601DateFormatter().string(from: snap.capturedAt),
            "totalCalls": snap.totalCalls,
            "mainThreadCalls": snap.mainThreadCalls,
            "backgroundCalls": snap.backgroundCalls,
            "mainThreadShare": round(snap.mainThreadShare * 10000) / 10000,
            "totalMainThreadMillis": round(snap.totalMainThreadMillis * 1000) / 1000,
            "slowestMainThreadCaller": snap.slowestMainThreadCaller,
            "slowestMainThreadMillis": round(snap.slowestMainThreadMillis * 1000) / 1000,
            "topCallers": callers,
        ])
    }
}
