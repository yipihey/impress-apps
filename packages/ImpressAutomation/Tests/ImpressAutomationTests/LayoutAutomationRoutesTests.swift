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
    var refusal: String?

    func layoutTreeJSON() -> [String: Any] {
        ["version": 7, "focused": 2, "layout": ["tiles": ["1": ["pane": [:]]]]]
    }

    func savedLayoutsJSON() -> [[String: Any]] {
        [["id": "abc", "ordinal": 1, "name": "Reading", "created": "t", "modified": "t"]]
    }

    func applyLayoutVerb(_ verb: [String: Any]) throws -> [String: Any] {
        lastVerb = verb
        if let refusal { throw LayoutHostRefusal(message: refusal) }
        return ["version": 8, "affectedPanes": [2]]
    }

    func applyLayoutOperation(_ operation: String, body: [String: Any]) throws -> [String: Any] {
        lastOperation = (operation, body)
        if let refusal { throw LayoutHostRefusal(message: refusal) }
        return ["version": 9, "affectedPanes": []]
    }
}

private struct LayoutHostRefusal: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

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
            #expect(payload["status"] as? String == "error")
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
            #expect(payload["status"] as? String == "ok")
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
            "target": ["ref": "role", "role": "detail"],
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
        }
    }

    @Test("a verb the tree refuses is 422, carrying Rust's own message")
    func refusedVerbIs422() async throws {
        let host = FakeLayoutHost()
        host.refusal = "cannot close the last pane of a window"
        try await withHost(host) {
            let response = try #require(
                await SharedAutomationRoutes.route(
                    post("/api/layout/verb", ["verb": "close"])))
            #expect(response.status == 422)
            let payload = try json(response)
            #expect(
                (payload["error"] as? String ?? "").contains("last pane"))
        }
    }

    @Test("a body that is not JSON is 400 with an example, not a 500")
    func malformedVerbBody() async throws {
        try await withHost(FakeLayoutHost()) {
            let response = try #require(
                await SharedAutomationRoutes.route(
                    HTTPRequest(method: "POST", path: "/api/layout/verb", body: "not json")))
            #expect(response.status == 400)
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
            let error = payload["error"] as? String ?? ""
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
        // imbib's legacy PaneLayoutStore routes are NOT ours: `/api/layout`
        // itself must still reach the app's own table.
        #expect(await SharedAutomationRoutes.route(HTTPRequest(method: "GET", path: "/api/layout")) == nil)
        #expect(await SharedAutomationRoutes.route(HTTPRequest(method: "POST", path: "/api/layout/apply")) == nil)
        #expect(await SharedAutomationRoutes.route(HTTPRequest(method: "POST", path: "/api/layout/save")) == nil)
    }
}
