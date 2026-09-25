//
//  LayoutAutomationRoutesTests.swift
//  ImpressAutomationTests
//
//  The ADR-0031 layout tree over HTTP, without a tree.
//
//  `LayoutAutomationHost` exists so this package never learns the verb
//  vocabulary — which also makes the routes testable against a fake host that
//  records what it was handed. What these pin is the ENVELOPE: the 409 when no
//  tree is rendering (the state every shipping build is in today, since the
//  tree is behind a flag), the verbatim forwarding of the verb body, and the
//  refusal of an operation name the host would otherwise receive as a string.
//

import Foundation
import Testing

@testable import ImpressAutomation

/// Records what the routes forwarded, and can be told to refuse.
@MainActor
private final class FakeLayoutHost: LayoutAutomationHost {

    let layoutAppID = "imbib"
    var lastVerb: [String: Any]?
    var lastOperation: (String, [String: Any])?
    var refusal: AutomationRefusal?
    var snapshotFails = false
    var layoutsFail = false

    func layoutTreeJSON() -> [String: Any] {
        if snapshotFails {
            return [
                "version": 7, "snapshot_error": "store: disk I/O error",
                "snapshot_code": "store-error",
            ]
        }
        return ["version": 7, "focused": 2, "layout": ["tiles": ["1": ["pane": [:]]]]]
    }

    func savedLayoutsJSON() throws -> [[String: Any]] {
        if layoutsFail {
            throw AutomationRefusal(code: "store-error", message: "read layouts: locked", status: 500)
        }
        return [["id": "abc", "ordinal": 1, "name": "Reading", "created": "t", "modified": "t"]]
    }

    func applyLayoutVerb(_ verb: [String: Any]) throws -> [String: Any] {
        lastVerb = verb
        if let refusal { throw refusal }
        return ["version": 8, "affected_panes": [2], "revision": 41]
    }

    func applyLayoutOperation(_ operation: String, body: [String: Any]) throws -> [String: Any] {
        lastOperation = (operation, body)
        if let refusal { throw refusal }
        return ["version": 9, "affected_panes": [] as [Int]]
    }
}

private struct SomethingElse: Error {}

@Suite("LayoutAutomationRoutes", .serialized)
@MainActor
struct LayoutAutomationRoutesTests {

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func post(_ path: String, _ body: [String: Any]) -> HTTPRequest {
        let data = try! JSONSerialization.data(withJSONObject: body)
        return HTTPRequest(
            method: "POST", path: path, body: String(data: data, encoding: .utf8))
    }

    private func get(_ path: String) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path)
    }

    /// Install `host` for the duration of `work`. The registry is a singleton
    /// shared with every other test in this package, hence `.serialized`.
    private func withHost(
        _ host: FakeLayoutHost?, _ work: () async throws -> Void
    ) async rethrows {
        LayoutAutomation.shared.host = host
        defer { LayoutAutomation.shared.host = nil }
        try await work()
    }

    // MARK: - No tree

    @Test("every layout route answers 409 when no tree is rendering")
    func conflictWithoutTree() async throws {
        // Deliberately not `nil`-guarded per route: a 200 with an empty body
        // here would read to an agent as "the window has no panes".
        for request in [
            get("/api/layout/tree"),
            get("/api/layout/layouts"),
            post("/api/layout/verb", ["verb": "focus"]),
            post("/api/layout/op", ["op": "undo", "stack": "arrangement"]),
        ] {
            let response = try #require(await SharedAutomationRoutes.route(request))
            #expect(response.status == 409)
            let payload = try json(response)
            #expect(payload["ok"] as? Bool == false)
            #expect(payload["code"] as? String == "no-layout-tree")
            #expect(payload["wire_version"] as? Int == LayoutAutomationRoutes.wireVersion)
            // The 409 must say why (no flag exists any more: a chassis window
            // IS the tree, imbib's own window has none) and name the headless
            // path that needs no app at all.
            let detail = payload["detail"] as? String ?? ""
            #expect(!detail.contains("layoutTree.enabled"))
            #expect(detail.contains("pre-chassis"))
            #expect(detail.contains("layout-service_"))
        }
    }

    // MARK: - Reads

    @Test("GET /api/layout/tree returns the host's tree under the shared envelope")
    func treeRead() async throws {
        let host = FakeLayoutHost()
        try await withHost(host) {
            let response = try #require(await SharedAutomationRoutes.route(get("/api/layout/tree")))
            #expect(response.status == 200)
            let payload = try json(response)
            #expect(payload["ok"] as? Bool == true)
            #expect(payload["wire_version"] as? Int == 1)
            #expect(payload["status"] == nil, "no status/error pair any more")
            #expect(payload["app"] as? String == "imbib")
            #expect(payload["version"] as? Int == 7)
            #expect(payload["focused"] as? Int == 2)
            #expect(payload["layout"] as? [String: Any] != nil)
        }
    }

    @Test("GET /api/layout/layouts lists the saved layouts in ordinal order")
    func layoutsRead() async throws {
        try await withHost(FakeLayoutHost()) {
            let response = try #require(
                await SharedAutomationRoutes.route(get("/api/layout/layouts")))
            let payload = try json(response)
            let rows = try #require(payload["layouts"] as? [[String: Any]])
            #expect(rows.first?["name"] as? String == "Reading")
            #expect(rows.first?["ordinal"] as? Int == 1)
        }
    }

    // MARK: - Verbs

    @Test("a verb body reaches the host VERBATIM — this package never parses it")
    func verbForwardedUntouched() async throws {
        let host = FakeLayoutHost()
        let verb: [String: Any] = [
            "verb": "split",
            "target": ["role": "detail"],
            "expected_revision": 40,
            "dir": "horizontal",
            "after": true,
            "new": ["view_kind": "source"],
        ]
        try await withHost(host) {
            let response = try #require(
                await SharedAutomationRoutes.route(post("/api/layout/verb", verb)))
            #expect(response.status == 200)
            let sent = try #require(host.lastVerb)
            // Every key, unaltered: a verb Rust grows tomorrow rides through
            // this route with nothing added here.
            #expect(sent.keys.sorted() == verb.keys.sorted())
            #expect(sent["verb"] as? String == "split")
            #expect((sent["target"] as? [String: Any])?["role"] as? String == "detail")
            let payload = try json(response)
            #expect(payload["ok"] as? Bool == true)
            #expect(payload["affected_panes"] as? [Int] == [2])
            #expect(payload["revision"] as? Int == 41)
        }
    }

    @Test("a verb the tree refuses carries Rust's code, message and status")
    func refusedVerbCarriesItsCode() async throws {
        let host = FakeLayoutHost()
        host.refusal = AutomationRefusal(
            code: "cannot-close-last-pane", message: "close: a window must keep at least one pane",
            status: 422)
        try await withHost(host) {
            let response = try #require(
                await SharedAutomationRoutes.route(
                    post("/api/layout/verb", ["verb": "close"])))
            #expect(response.status == 422)
            let payload = try json(response)
            #expect(payload["ok"] as? Bool == false)
            #expect(payload["code"] as? String == "cannot-close-last-pane")
            #expect((payload["message"] as? String ?? "").contains("at least one pane"))
            // The prose, not `String(describing:)` of an error type.
            #expect(!(payload["message"] as? String ?? "").contains("AutomationRefusal"))
            #expect(payload["error"] == nil)
        }
    }

    @Test("a refusal's status is the one Rust gave its code, not always 422")
    func refusalStatusFollowsTheCode() async throws {
        let host = FakeLayoutHost()
        host.refusal = AutomationRefusal(
            code: "not-found", message: "no saved layout named 'x'", status: 404)
        try await withHost(host) {
            let response = try #require(
                await SharedAutomationRoutes.route(
                    post("/api/layout/op", ["op": "delete-layout", "name": "x"])))
            #expect(response.status == 404)
            #expect(try json(response)["code"] as? String == "not-found")
        }
    }

    @Test("an error that is not a refusal is a 500 with code internal")
    func unknownErrorIs500() async throws {
        let response = LayoutAutomationRoutes.refused(SomethingElse())
        #expect(response.status == 500)
        #expect(try json(response)["code"] as? String == "internal")
    }

    @Test("a snapshot that failed is a 500 that says why, not a 200 with a null tree")
    func failedSnapshotIs500() async throws {
        let host = FakeLayoutHost()
        host.snapshotFails = true
        try await withHost(host) {
            let response = try #require(await SharedAutomationRoutes.route(get("/api/layout/tree")))
            #expect(response.status == 500)
            let payload = try json(response)
            #expect(payload["ok"] as? Bool == false)
            #expect(payload["code"] as? String == "store-error")
            #expect((payload["message"] as? String ?? "").contains("disk I/O"))
        }
    }

    @Test("saved layouts that could not be read are an error, not an empty list")
    func failedLayoutsReadIsAnError() async throws {
        let host = FakeLayoutHost()
        host.layoutsFail = true
        try await withHost(host) {
            let response = try #require(
                await SharedAutomationRoutes.route(get("/api/layout/layouts")))
            #expect(response.status == 500)
            #expect(try json(response)["code"] as? String == "store-error")
        }
    }

    @Test("a body that is not JSON is 400 with an example, not a 500")
    func malformedVerbBody() async throws {
        try await withHost(FakeLayoutHost()) {
            let response = try #require(
                await SharedAutomationRoutes.route(
                    HTTPRequest(method: "POST", path: "/api/layout/verb", body: "not json")))
            #expect(response.status == 400)
            #expect(try json(response)["code"] as? String == "invalid-argument")
        }
    }

    // MARK: - Operations

    @Test("an operation is validated HERE, so the host never sees an unknown name")
    func unknownOperationRejected() async throws {
        let host = FakeLayoutHost()
        try await withHost(host) {
            let response = try #require(
                await SharedAutomationRoutes.route(post("/api/layout/op", ["op": "split"])))
            #expect(response.status == 400)
            #expect(host.lastOperation == nil)
            // The 400 lists what IS accepted; "split" is a verb, not an op.
            let payload = try json(response)
            #expect(payload["code"] as? String == "invalid-argument")
            let error = payload["message"] as? String ?? ""
            #expect(error.contains("apply-layout"))
            #expect(error.contains("/api/layout/verb"))
        }
    }

    @Test("a known operation forwards its whole body")
    func operationForwarded() async throws {
        let host = FakeLayoutHost()
        try await withHost(host) {
            let response = try #require(
                await SharedAutomationRoutes.route(
                    post("/api/layout/op", ["op": "apply-layout", "ordinal": 3])))
            #expect(response.status == 200)
            let (op, body) = try #require(host.lastOperation)
            #expect(op == "apply-layout")
            #expect(body["ordinal"] as? Int == 3)
        }
    }

    // MARK: - Mount

    @Test("the layout paths are part of the shared group's declared set")
    func pathsDeclared() {
        for path in LayoutAutomationRoutes.paths {
            #expect(SharedAutomationRoutes.paths.contains(path))
        }
    }

    @Test("a layout path on the wrong method falls through to the app's table")
    func wrongMethodFallsThrough() async {
        #expect(await SharedAutomationRoutes.route(HTTPRequest(method: "POST", path: "/api/layout/tree")) == nil)
        #expect(await SharedAutomationRoutes.route(HTTPRequest(method: "GET", path: "/api/layout/verb")) == nil)
        // imbib's own-window layout routes are NOT ours: `/api/layout`
        // itself must still reach the app's own table.
        #expect(await SharedAutomationRoutes.route(HTTPRequest(method: "GET", path: "/api/layout")) == nil)
        #expect(await SharedAutomationRoutes.route(HTTPRequest(method: "POST", path: "/api/layout/apply")) == nil)
        #expect(await SharedAutomationRoutes.route(HTTPRequest(method: "POST", path: "/api/layout/save")) == nil)
    }
}
