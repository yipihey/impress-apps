//
//  HTTPServerLocalPortTests.swift
//  ImpressAutomationTests
//
//  A request knows the port it arrived on (plan wave 8, U3). impress's
//  `/api/status` reported the port table's default while bound elsewhere,
//  which sends a caller probing a second instance back to the first. The
//  server now stamps each request with its local port; this drives a real
//  socket to prove it, because a hand-built `HTTPRequest` cannot.
//

import Foundation
import XCTest
@testable import ImpressAutomation

/// Answers every request with the port the server says it arrived on.
private struct LocalPortEcho: HTTPRouter {
    func route(_ request: HTTPRequest) async -> HTTPResponse {
        .json(["localPort": request.localPort.map { Int($0) } as Any])
    }
}

final class HTTPServerLocalPortTests: XCTestCase {

    /// Start on port 0 — the system picks a free one, so the test never
    /// collides with a running app and the answer cannot be a table default —
    /// and wait for the listener to say which.
    private func startOnAFreePort(_ server: HTTPServer<LocalPortEcho>) async throws -> UInt16 {
        await server.start(
            configuration: HTTPServerConfiguration(
                port: 0, loggerSubsystem: "com.impress.tests", loggerCategory: "httpServer"))
        for _ in 0..<100 {
            if let port = await server.boundPort { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ListenerNeverReady()
    }

    private struct ListenerNeverReady: Error {}

    func testARequestCarriesThePortTheServerIsBoundTo() async throws {
        let server = HTTPServer(router: LocalPortEcho())
        let port = try await startOnAFreePort(server)
        XCTAssertNotEqual(port, 0)

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/status"))
        let (data, _) = try await URLSession.shared.data(from: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["localPort"] as? Int, Int(port))
        await server.stop()
    }

    func testAHandBuiltRequestDoesNotClaimAPort() {
        XCTAssertNil(HTTPRequest(method: "GET", path: "/api/status").localPort)
        XCTAssertNil(HTTPRequest.parse("GET /api/status HTTP/1.1\r\nHost: x\r\n\r\n")?.localPort)
    }

    func testStoppingForgetsTheBoundPort() async throws {
        let server = HTTPServer(router: LocalPortEcho())
        _ = try await startOnAFreePort(server)
        await server.stop()
        let after = await server.boundPort
        XCTAssertNil(after)
    }
}
