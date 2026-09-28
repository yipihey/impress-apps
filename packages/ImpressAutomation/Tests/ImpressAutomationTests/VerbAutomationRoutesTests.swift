//
//  VerbAutomationRoutesTests.swift
//  ImpressAutomationTests
//
//  The P5 transport's server side, the parts this package can pin without a
//  Rust store: path matching, the caller-identity JSON it builds from the
//  request (ADR-0034 D3, hook H-P5-1's `traceparent`), and the HTTP status
//  text table. `dispatch_verb` itself — the actual verb lookup and
//  pipeline run — is Rust's own tests
//  (`crates/impress-store-ffi/src/verb.rs`, `crates/implore-verbs-ffi`) and
//  the parity test (`crates/impress-app-transport/tests/implore_parity.rs`);
//  this package never learns the verb vocabulary (see the file header on
//  `VerbAutomation.swift`), so there is nothing to fake a host for the way
//  `LayoutAutomationRoutesTests` fakes a tree.
//

import Foundation
import Testing

@testable import ImpressAutomation

@Suite("VerbAutomationRoutes")
struct VerbAutomationRoutesTests {

    @Test
    func the_prefix_matches_a_name_but_not_the_bare_path() {
        #expect(VerbAutomationRoutes.matches("/api/verb/imbib-library-service_status"))
        #expect(VerbAutomationRoutes.matches("/api/verb/x"))
        #expect(!VerbAutomationRoutes.matches("/api/verb"))
        #expect(!VerbAutomationRoutes.matches("/api/verb/"))
        #expect(!VerbAutomationRoutes.matches("/api/verbs/x"))
        #expect(!VerbAutomationRoutes.matches("/api/layout/verb"))
    }

    @Test
    func a_get_or_a_bare_prefix_falls_through_to_nil() async {
        let getRequest = HTTPRequest(method: "GET", path: "/api/verb/imbib-library-service_status")
        let answer = await VerbAutomationRoutes.route(
            "/api/verb/imbib-library-service_status", method: "GET", request: getRequest)
        #expect(answer == nil)

        let bareRequest = HTTPRequest(method: "POST", path: "/api/verb/")
        let bareAnswer = await VerbAutomationRoutes.route("/api/verb/", method: "POST", request: bareRequest)
        #expect(bareAnswer == nil)
    }

    @Test
    func the_caller_json_carries_the_traceparent_header_when_present() {
        let withTrace = HTTPRequest(
            method: "POST", path: "/api/verb/x", headers: ["traceparent": "00-abc-def-01"])
        let json = VerbAutomationRoutes.callerJSONFor(withTrace)
        let value = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(value["kind"] as? String == "app")
        #expect(value["trace_id"] as? String == "00-abc-def-01")
    }

    @Test
    func no_traceparent_header_means_no_trace_id_key() {
        let withoutTrace = HTTPRequest(method: "POST", path: "/api/verb/x")
        let json = VerbAutomationRoutes.callerJSONFor(withoutTrace)
        let value = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(value["kind"] as? String == "app")
        #expect(value["trace_id"] == nil)
    }

    @Test
    func an_empty_traceparent_header_is_treated_as_absent() {
        let empty = HTTPRequest(method: "POST", path: "/api/verb/x", headers: ["traceparent": ""])
        let json = VerbAutomationRoutes.callerJSONFor(empty)
        let value = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(value["trace_id"] == nil)
    }

    @Test
    func the_status_text_table_matches_the_refusal_codes_map() {
        #expect(VerbAutomationRoutes.statusText(200) == "OK")
        #expect(VerbAutomationRoutes.statusText(404) == "Not Found")
        #expect(VerbAutomationRoutes.statusText(503) == "Service Unavailable")
        #expect(VerbAutomationRoutes.statusText(999) == "Error")
    }

    @Test
    func domain_dispatch_awaits_the_host_and_preserves_its_refusal() async throws {
        let service = "proof-\(UUID().uuidString)-service"
        let verb = service + "_read"
        let body = #"{"ok":false,"code":"not-found","message":"native record missing","wire_version":1}"#
        VerbAutomationRoutes.registerDomainDispatcher(services: [service]) { name, args, caller in
            #expect(name == verb)
            #expect(args == #"{"id":"missing"}"#)
            #expect(caller.contains("proof-trace"))
            await MainActor.run {}
            return VerbDispatchResponse(status: 404, bodyJSON: body)
        }
        let request = HTTPRequest(
            method: "POST", path: "/api/verb/" + verb,
            headers: ["traceparent": "proof-trace"], body: #"{"id":"missing"}"#)
        let response = try #require(await VerbAutomationRoutes.route(
            request.path, method: request.method, request: request))
        #expect(response.status == 404)
        // A fallback to the kit would replace this with "no such verb".
        #expect(response.body == Data(body.utf8))
    }
}
