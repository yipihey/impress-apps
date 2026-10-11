//
//  KoineWebRoutesTests.swift
//  ImpressAutomationTests
//
//  `GET /ui/*` (koine docs/plan-koine-web.md D8, D9): the bundle is served
//  as itself, every other path under `/ui/` is the page, and the loopback
//  token reaches the page only for a loopback peer. The bundle folder is a
//  temporary directory here, because the committed resource folder holds
//  only a README until `scripts/build-koine-web.sh` has run.
//

import Foundation
import Testing
@testable import ImpressAutomation

@Suite("KoineWebRoutes")
struct KoineWebRoutesTests {

    private func bundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("koine-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("wasm"), withIntermediateDirectories: true)
        try "<!doctype html><html><head><title>koine</title></head><body></body></html>"
            .write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try Data([0, 0x61, 0x73, 0x6D]).write(to: root.appendingPathComponent("wasm/koine-web_bg.wasm"))
        try "export {};".write(
            to: root.appendingPathComponent("wasm/koine-web.js"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("only GET under /ui is this group's; the rest falls through or is 405")
    func mount() {
        #expect(KoineWebRoutes.route(HTTPRequest(method: "GET", path: "/api/status")) == nil)
        #expect(KoineWebRoutes.route(HTTPRequest(method: "GET", path: "/uix")) == nil)
        #expect(KoineWebRoutes.route(HTTPRequest(method: "POST", path: "/ui/surface/1"))?.status == 405)
    }

    @Test("a bundle file is served as itself with its content type")
    func files() throws {
        let root = try bundle()
        let wasm = KoineWebRoutes.serve(relativePath: "/wasm/koine-web_bg.wasm", from: root, token: nil)
        #expect(wasm.status == 200)
        #expect(wasm.headers["Content-Type"] == "application/wasm")
        #expect(wasm.body.count == 4)
        let js = KoineWebRoutes.serve(relativePath: "/wasm/koine-web.js", from: root, token: nil)
        #expect(js.headers["Content-Type"] == "text/javascript; charset=utf-8")
        #expect(KoineWebRoutes.serve(relativePath: "/wasm/missing.js", from: root, token: nil).status == 404)
    }

    @Test("the page answers /ui, /ui/ and the router's own paths")
    func page() throws {
        let root = try bundle()
        for path in ["", "/", "/surface/abc", "/layout", "/style"] {
            let page = KoineWebRoutes.serve(relativePath: path, from: root, token: nil)
            #expect(page.status == 200, "\(path)")
            #expect(page.headers["Content-Type"] == "text/html; charset=utf-8", "\(path)")
            #expect(String(data: page.body, encoding: .utf8)?.contains("koine-token") == false, "\(path)")
        }
    }

    @Test("a loopback peer's page carries the token; nobody else's does")
    func token() throws {
        let root = try bundle()
        let page = KoineWebRoutes.serve(relativePath: "/", from: root, token: "tok&\"<en")
        let html = try #require(String(data: page.body, encoding: .utf8))
        #expect(html.contains("<meta name=\"koine-token\" content=\"tok&amp;&quot;&lt;en\"></head>"))
        // `token(for:)` reads the file only for a positively loopback peer
        // with a known port; a hand-built request is neither.
        #expect(KoineWebRoutes.token(for: HTTPRequest(method: "GET", path: "/ui")) == nil)
        var remote = HTTPRequest(method: "GET", path: "/ui", localPort: 23125)
        remote.peerIsLoopback = false
        #expect(KoineWebRoutes.token(for: remote) == nil)
    }

    @Test("dotted and parent paths are not files")
    func safety() throws {
        let root = try bundle()
        #expect(KoineWebRoutes.serve(relativePath: "/../index.html", from: root, token: nil).status == 404)
        #expect(KoineWebRoutes.serve(relativePath: "/.hidden.js", from: root, token: nil).status == 404)
    }

    @Test("no bundle is a 503 naming the script, not a 404")
    func missing() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("koine-web-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let page = KoineWebRoutes.serve(relativePath: "/", from: empty, token: nil)
        #expect(page.status == 503)
        #expect(String(data: page.body, encoding: .utf8)?.contains("build-koine-web.sh") == true)
    }
}
