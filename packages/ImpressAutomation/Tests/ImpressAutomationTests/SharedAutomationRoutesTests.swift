//
//  SharedAutomationRoutesTests.swift
//  ImpressAutomationTests
//
//  Stage 4b. `HTTPRouter.route` is a plain function with value-type input and
//  output, so a route group is unit-testable without a socket — there was simply
//  no precedent in-repo (zero tests existed for any of the five app routers).
//  These pin the WIRE SHAPES the group now owns, because four Rust consumers and
//  imprint-selftest's Tier B read them, and the failure mode of a renamed key is
//  an empty list rather than an error — indistinguishable from "no data yet".
//

import Foundation
import Testing
@testable import ImpressAutomation
@testable import ImpressLogging

// Serialized: these tests share the `LogStore` / `PerfMetrics` / `StoreTimings`
// singletons, and swift-testing runs `@Test`s in parallel by default — the same
// reason `PerfMetricsTests` is serialized.
@Suite("SharedAutomationRoutes", .serialized)
struct SharedAutomationRoutesTests {

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func request(
        _ method: String, _ path: String, query: [String: String] = [:]
    ) -> HTTPRequest {
        HTTPRequest(method: method, path: path, queryParams: query)
    }

    // MARK: - Mount behaviour

    @Test("unknown paths fall through so the app's domain table still sees them")
    func fallsThrough() async {
        #expect(await SharedAutomationRoutes.route(request("GET", "/api/documents")) == nil)
        #expect(await SharedAutomationRoutes.route(request("GET", "/api/papers")) == nil)
        #expect(await SharedAutomationRoutes.route(request("GET", "/threads")) == nil)
        // `/api/search` is deliberately NOT in the group: imprint and imbib share
        // only the envelope keys, not the contract.
        #expect(await SharedAutomationRoutes.route(request("GET", "/api/search")) == nil)
        #expect(await SharedAutomationRoutes.route(request("GET", "/api/status")) == nil)
    }

    @Test("a generic path on the wrong method falls through rather than 405-ing")
    func wrongMethodFallsThrough() async {
        #expect(await SharedAutomationRoutes.route(request("DELETE", "/api/logs")) == nil)
        #expect(await SharedAutomationRoutes.route(request("PUT", "/api/performance")) == nil)
    }

    @Test("path matching is case- and trailing-slash-tolerant")
    func pathNormalization() {
        #expect(SharedAutomationRoutes.normalize("/API/Logs") == "/api/logs")
        #expect(SharedAutomationRoutes.normalize("/api/logs/") == "/api/logs")
        #expect(SharedAutomationRoutes.normalize("/") == "/")
    }

    // MARK: - CORS

    @Test("OPTIONS is answered with the 204 preflight all five routers copied")
    func corsPreflight() async throws {
        let response = try #require(
            await SharedAutomationRoutes.route(request("OPTIONS", "/api/anything")))
        #expect(response.status == 204)
        #expect(response.headers["Access-Control-Allow-Origin"] == "*")
        #expect(response.headers["Access-Control-Max-Age"] == "86400")
        let methods = try #require(response.headers["Access-Control-Allow-Methods"])
        for verb in ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] {
            #expect(methods.contains(verb))
        }
    }

    @Test("a router that owns OPTIONS itself can opt out")
    func corsOptOut() async {
        #expect(
            await SharedAutomationRoutes.route(
                request("OPTIONS", "/api/anything"), includeCORSPreflight: false) == nil)
    }

    // MARK: - /api/logs

    @Test("GET /api/logs keeps the nested `data.entries` shape the Rust clients read")
    @MainActor
    func logsShape() async throws {
        LogStore.shared.clear()
        logInfo("stage 4b probe", category: "test")

        let response = try #require(
            await SharedAutomationRoutes.route(request("GET", "/api/logs")))
        let body = try json(response)
        #expect(body["status"] as? String == "ok")

        // `data.entries[]` with `message`/`timestamp`/`level`/`category` is the
        // contract all four `get_logs` implementations in
        // `crates/impress-app-client` + the `*-service-http` crates decode. A
        // rename here returns an empty list, not an error.
        let data = try #require(body["data"] as? [String: Any])
        #expect(data["count"] != nil)
        #expect(data["totalInStore"] != nil)
        let entries = try #require(data["entries"] as? [[String: Any]])
        let entry = try #require(entries.first)
        #expect(entry["message"] as? String == "stage 4b probe")
        #expect(entry["category"] as? String == "test")
        #expect(entry["level"] as? String == "info")
        #expect(entry["timestamp"] is String)
        #expect(entry["id"] is String)
    }

    @Test("GET /api/logs/stream is now mounted for every app, with its cursor keys")
    @MainActor
    func logStreamShape() async throws {
        LogStore.shared.clear()
        logInfo("stream probe", category: "test")

        // Only imprint ever registered this route; the other four 404'd a handler
        // that has always lived in this package.
        let response = try #require(
            await SharedAutomationRoutes.route(
                request("GET", "/api/logs/stream", query: ["after": "0"])))
        let body = try json(response)
        #expect(body["status"] as? String == "ok")
        let data = try #require(body["data"] as? [String: Any])
        #expect(data["entries"] is [[String: Any]])
        #expect(data["count"] != nil)
        #expect(data["nextCursor"] is String)
        #expect(data["hasMore"] is Bool)
        #expect(data["serverTime"] is String)
    }

    // MARK: - /api/performance

    @Test("GET /api/performance keeps every bucket key imprint and imbib emitted")
    func performanceShape() async throws {
        PerfMetrics.shared.reset()
        PerfMetrics.shared.measure("search") { _ = (0..<1000).reduce(0, +) }

        let response = try #require(
            await SharedAutomationRoutes.route(request("GET", "/api/performance")))
        let body = try json(response)
        #expect(body["status"] as? String == "ok")
        #expect(body["capturedAt"] is String)
        #expect(body["bucketCount"] as? Int == (body["buckets"] as? [[String: Any]])?.count)

        let buckets = try #require(body["buckets"] as? [[String: Any]])
        let bucket = try #require(buckets.first { $0["name"] as? String == "search" })
        for key in [
            "name", "count", "mainThreadCount", "mainThreadShare", "minMillis",
            "meanMillis", "p50Millis", "p95Millis", "maxMillis", "breachCount",
            "totalNanos",
        ] {
            #expect(bucket[key] != nil, "missing /api/performance bucket key \(key)")
        }
    }

    @Test("performance reset answers the richer body and accepts GET or POST")
    func performanceReset() async throws {
        // imprint registered reset under POST, imbib under GET, and imbib's body
        // omitted `reset`. The group accepts both and always answers both keys.
        for method in ["GET", "POST"] {
            PerfMetrics.shared.measure("search") { _ = (0..<10).reduce(0, +) }
            let response = try #require(
                await SharedAutomationRoutes.route(
                    request(method, "/api/performance/reset")))
            let body = try json(response)
            #expect(body["status"] as? String == "ok")
            #expect(body["reset"] as? Bool == true)
            let snapshot = PerfMetrics.shared.snapshot()
            #expect(snapshot.buckets.allSatisfy { $0.count == 0 })
        }
    }

    // MARK: - /api/store-timings

    @Test("GET /api/store-timings keeps every top-level and per-caller key")
    func storeTimingsShape() async throws {
        StoreTimings.shared.reset()
        StoreTimings.shared.measure("stage4b") { _ = (0..<1000).reduce(0, +) }

        let response = try #require(
            await SharedAutomationRoutes.route(request("GET", "/api/store-timings")))
        let body = try json(response)
        for key in [
            "status", "capturedAt", "totalCalls", "mainThreadCalls",
            "backgroundCalls", "mainThreadShare", "totalMainThreadMillis",
            "slowestMainThreadCaller", "slowestMainThreadMillis", "topCallers",
        ] {
            #expect(body[key] != nil, "missing /api/store-timings key \(key)")
        }
        let callers = try #require(body["topCallers"] as? [[String: Any]])
        let caller = try #require(callers.first { $0["caller"] as? String == "stage4b" })
        for key in [
            "caller", "count", "mainThreadCount", "meanMillis", "maxMillis", "totalNanos",
        ] {
            #expect(caller[key] != nil, "missing topCallers key \(key)")
        }
    }

    @Test("?top=N is honoured")
    func storeTimingsTopParam() async throws {
        StoreTimings.shared.reset()
        for i in 0..<5 {
            StoreTimings.shared.measure("caller\(i)") { _ = (0..<(i * 20 + 1)).reduce(0, +) }
        }
        let response = try #require(
            await SharedAutomationRoutes.route(
                request("GET", "/api/store-timings", query: ["top": "2"])))
        let callers = try #require(try json(response)["topCallers"] as? [[String: Any]])
        #expect(callers.count == 2)
    }

    @Test("store-timings reset accepts GET or POST and clears the counters")
    func storeTimingsReset() async throws {
        for method in ["GET", "POST"] {
            StoreTimings.shared.measure("x") { _ = (0..<10).reduce(0, +) }
            let response = try #require(
                await SharedAutomationRoutes.route(
                    request(method, "/api/store-timings/reset")))
            let body = try json(response)
            #expect(body["status"] as? String == "ok")
            #expect(body["reset"] as? Bool == true)
            #expect(StoreTimings.shared.snapshot().totalCalls == 0)
        }
    }

    // MARK: - /api/status envelope

    @Test("the status envelope emits both `port` and `serverPort`")
    func statusEmitsBothPortSpellings() {
        // imbib emitted only `serverPort` (decoded by `ServerInfo.server_port` in
        // crates/impress-app-client); the other four emitted only `port`, while
        // `ImprintServerInfo` expected `serverPort` and silently got nothing.
        // Emitting both keeps every existing reader working.
        let payload = SharedAutomationRoutes.statusPayload(
            app: "imprint", port: 23121, version: "9.9.9")
        #expect(payload["status"] as? String == "ok")
        #expect(payload["app"] as? String == "imprint")
        #expect(payload["version"] as? String == "9.9.9")
        #expect(payload["port"] as? Int == 23121)
        #expect(payload["serverPort"] as? Int == 23121)
    }

    @Test("domain fields merge in and win on collision")
    func statusMergesDomainFields() {
        let payload = SharedAutomationRoutes.statusPayload(
            app: "impel", port: 23124,
            domain: ["threads": 7, "tasks_api": true, "version": "override"])
        #expect(payload["threads"] as? Int == 7)
        #expect(payload["tasks_api"] as? Bool == true)
        #expect(payload["version"] as? String == "override")
    }

    @Test("`status` — the one field the MCP reachability probe requires — is always present")
    func statusAlwaysHasStatus() throws {
        // `crates/impress-app-client`'s `*ServerInfo` has exactly one
        // non-optional field. Losing it does not fail Tier B; it turns every
        // capability into a silent skip.
        let response = SharedAutomationRoutes.status(app: "implore", port: 23123)
        #expect(try json(response)["status"] as? String == "ok")
    }

    // MARK: - /api/search envelope

    @Test("the search envelope shares only the three keys the apps agree on")
    func searchEnvelope() {
        let payload = SharedAutomationRoutes.searchEnvelope(
            query: "reionization", count: 1, resultsKey: "results",
            results: [["title": "x"]])
        #expect(payload["status"] as? String == "ok")
        #expect(payload["query"] as? String == "reionization")
        #expect(payload["count"] as? Int == 1)
        #expect((payload["results"] as? [[String: Any]])?.count == 1)
        // imbib spells the array `papers` and echoes limit/offset; imprint spells
        // it `results` and 400s on a missing `q`. That is why the ROUTE is not
        // shared — only this envelope is.
        let imbibShaped = SharedAutomationRoutes.searchEnvelope(
            query: "", count: 0, resultsKey: "papers", results: [],
            extra: ["limit": 50, "offset": 0])
        #expect(imbibShaped["papers"] is [[String: Any]])
        #expect(imbibShaped["limit"] as? Int == 50)
    }
}
