//
//  HTTPServerLoopbackGateTests.swift
//  ImpressAutomationTests
//
//  P0 (SEC-1, SEC-2, SEC-3) over a real socket: the Host check, the loopback
//  token on non-GET, and no CORS header — the three things `curl` proves
//  against a running app, proven here against a server on a free port with a
//  token file under the unit-test container root (never the production one).
//

import Foundation
import ImpressKit
import XCTest
@testable import ImpressAutomation

private struct Echo: HTTPRouter {
    func route(_ request: HTTPRequest) async -> HTTPResponse {
        .json(["method": request.method, "path": request.path])
    }
}

final class HTTPServerLoopbackGateTests: XCTestCase {

    private struct ListenerNeverReady: Error {}

    private func start(_ server: HTTPServer<Echo>) async throws -> UInt16 {
        await server.start(
            configuration: HTTPServerConfiguration(
                port: 0, loggerSubsystem: "com.impress.tests"))
        for _ in 0..<100 {
            if let port = await server.boundPort, await server.loopbackToken != nil { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ListenerNeverReady()
    }

    /// One request; returns status and headers.
    private func send(
        _ method: String, port: UInt16, path: String = "/api/x", headers: [String: String] = [:]
    ) async throws -> (Int, HTTPURLResponse) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, http)
    }

    func testTheTokenIsWrittenWhereRustSaysAndTheGateHolds() async throws {
        let server = HTTPServer(router: Echo())
        let port = try await start(server)
        let installed = await server.loopbackToken
        let token = try XCTUnwrap(installed)

        // The file is at the contract's path, and holds exactly the token.
        let path = LoopbackToken.path(port: port)
        XCTAssertTrue(path.hasSuffix("/workspace/automation/loopback-\(port).token"), path)
        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            token)
        XCTAssertEqual(token.count, 64)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)

        // GET: no token needed, and no CORS header even with an Origin.
        let (getStatus, getHeaders) = try await send(
            "GET", port: port, headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(getStatus, 200)
        XCTAssertNil(getHeaders.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))

        // POST without the token: 401.
        let (noToken, noTokenHeaders) = try await send("POST", port: port)
        XCTAssertEqual(noToken, 401)
        XCTAssertEqual(noTokenHeaders.value(forHTTPHeaderField: "WWW-Authenticate"), "Bearer")

        // POST with the wrong token: 401.
        let (wrong, _) = try await send(
            "POST", port: port, headers: ["Authorization": "Bearer \(token)x"])
        XCTAssertEqual(wrong, 401)

        // POST with the token: through to the router.
        let (ok, _) = try await send(
            "POST", port: port, headers: ["Authorization": "Bearer \(token)"])
        XCTAssertEqual(ok, 200)

        // A foreign Host is 400 before anything else — token or not.
        let (host, _) = try await send(
            "GET", port: port, headers: ["Host": "attacker.example"])
        XCTAssertEqual(host, 400)
        let (hostPost, _) = try await send(
            "POST", port: port,
            headers: ["Host": "attacker.example", "Authorization": "Bearer \(token)"])
        XCTAssertEqual(hostPost, 400)

        // Stopping removes the file and forgets the token.
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let after = await server.loopbackToken
        XCTAssertNil(after)
    }

    func testNetworkModeDoesNotStartWithoutTokenAndAddress() async throws {
        let server = HTTPServer(router: Echo())
        await server.start(
            configuration: HTTPServerConfiguration(
                port: 0, loggerSubsystem: "com.impress.tests", allowNetworkAccess: true))
        let running = await server.running
        XCTAssertFalse(running)
        let port = await server.boundPort
        XCTAssertNil(port)
    }
}
