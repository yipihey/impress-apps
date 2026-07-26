//
//  ImprintCompileClientTests.swift
//  CounselEngineTests
//
//  Phase 6.2 tests for the ImprintCompileClient. Uses URLProtocol mocks so
//  CI doesn't depend on imprint actually running.
//

import Foundation
import Testing
@testable import CounselEngine

// MARK: - URLProtocol mock

/// A scriptable URLProtocol that dispatches to per-test handlers.
///
/// Each test registers a handler keyed by a unique ID via
/// `MockURLProtocol.register(_:handler:)`. The base URL the test uses then
/// embeds that ID in the host (e.g. `http://test-XYZ.local`). The protocol
/// looks up the handler from the host string. This avoids global handler
/// clobbering when multiple test suites run concurrently.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func register(
        id: String,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = handler
    }

    static func unregister(id: String) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }

    /// Backward-compat shim: setting `handler` registers it under the
    /// well-known `__legacy__` key (and the test base URL must point at
    /// `http://__legacy__/`). Prefer `register(id:handler:)` for new tests.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        get {
            lock.lock(); defer { lock.unlock() }
            return handlers["__legacy__"] ?? { _ in throw URLError(.cannotConnectToHost) }
        }
        set {
            register(id: "__legacy__", handler: newValue)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? "__legacy__"
        Self.lock.lock()
        let handler = Self.handlers[host] ?? Self.handlers["__legacy__"] ?? { _ in
            throw URLError(.cannotConnectToHost)
        }
        Self.lock.unlock()
        do {
            let (response, body) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeTestClient(timeout: TimeInterval = 2) -> ImprintCompileClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return ImprintCompileClient(
        baseURL: URL(string: "http://imprint.test")!,
        session: session,
        requestTimeout: timeout
    )
}

/// Build a URLSession + a baseURL that routes only to the given handler.
/// The host portion of the URL is the per-test ID, so concurrent suites
/// don't clobber each other's handlers.
func makeIsolatedSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> (URLSession, URL) {
    let id = "test-\(UUID().uuidString.prefix(8).lowercased())"
    MockURLProtocol.register(id: id, handler: handler)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    let url = URL(string: "http://\(id)")!
    return (session, url)
}

private func httpResponse(
    url: URL,
    status: Int,
    headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

// MARK: - Suite (serialized — MockURLProtocol uses a global handler so we
// can't run these in parallel)

@Suite(.serialized)
struct ImprintCompileClientTests {

// MARK: - Success path

@Test func compileReturnsPDFBytesAndHeaders() async throws {
    let pdfBytes = Data("%PDF-1.4\n…fake pdf bytes…".utf8)
    MockURLProtocol.handler = { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/compile/typst")
        let response = httpResponse(
            url: request.url!,
            status: 200,
            headers: [
                "Content-Type":             "application/pdf",
                "X-Imprint-Compile-Status": "ok",
                "X-Imprint-Page-Count":     "3",
                "X-Imprint-Compile-Ms":     "142",
                "X-Imprint-Warnings":       "unused; deprecated foo",
            ]
        )
        return (response, pdfBytes)
    }

    let client = makeTestClient()
    let result = try await client.compileTypst(source: "= Hello\n\nBody.")
    #expect(result.pdfData == pdfBytes)
    #expect(result.pageCount == 3)
    #expect(result.compileMs == 142)
    #expect(result.warnings == ["unused", "deprecated foo"])
}

@Test func compileSendsExpectedJSONBody() async throws {
    var capturedBody: Data?
    MockURLProtocol.handler = { request in
        // URLProtocol gives us the raw body via httpBodyStream sometimes;
        // for ephemeral configs httpBody is set directly.
        capturedBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, capturedBody?.isEmpty ?? true {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            capturedBody = data
        }
        let response = httpResponse(
            url: request.url!,
            status: 200,
            headers: ["X-Imprint-Page-Count": "1"]
        )
        return (response, Data("%PDF".utf8))
    }
    let client = makeTestClient()
    _ = try await client.compileTypst(
        source: "= Hi",
        options: ImprintCompileOptions(pageSize: .letter, fontSize: 12)
    )
    let json = try #require((try? JSONSerialization.jsonObject(with: capturedBody ?? Data())) as? [String: Any])
    #expect(json["source"] as? String == "= Hi")
    #expect(json["page_size"] as? String == "letter")
    let fontSize = (json["font_size"] as? Double) ?? (json["font_size"] as? Int).map(Double.init)
    #expect(fontSize == 12.0)
}

// MARK: - Failure modes

@Test func compileMapsConnectionRefusedToUnreachable() async throws {
    MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
    let client = makeTestClient()
    do {
        _ = try await client.compileTypst(source: "= Hi")
        Issue.record("expected unreachable error")
    } catch let ImprintCompileError.unreachable(_, _) {
        // pass
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func unreachableErrorIsDeferrable() {
    let err = ImprintCompileError.unreachable(
        URL(string: "http://x")!,
        underlying: URLError(.cannotConnectToHost)
    )
    #expect(err.isDeferrable)
}

@Test func compileMaps422ToCompileError() async throws {
    MockURLProtocol.handler = { request in
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "error",
            "error": "expected closing brace at line 12, col 4",
            "warnings": ["unused symbol foo"],
            "compile_ms": 142,
        ] as [String: Any])
        return (httpResponse(url: request.url!, status: 422), body)
    }
    let client = makeTestClient()
    do {
        _ = try await client.compileTypst(source: "= broken")
        Issue.record("expected compileError")
    } catch let ImprintCompileError.compileError(message, warnings, compileMs) {
        #expect(message.contains("closing brace"))
        #expect(warnings == ["unused symbol foo"])
        #expect(compileMs == 142)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func compileErrorIsNotDeferrable() {
    let err = ImprintCompileError.compileError(message: "x", warnings: [], compileMs: 0)
    #expect(!err.isDeferrable)
}

@Test func compileMaps500ToImprintError() async throws {
    MockURLProtocol.handler = { request in
        return (httpResponse(url: request.url!, status: 500), Data("compiler crash".utf8))
    }
    let client = makeTestClient()
    do {
        _ = try await client.compileTypst(source: "= x")
        Issue.record("expected imprintError")
    } catch let ImprintCompileError.imprintError(status, body) {
        #expect(status == 500)
        #expect(body.contains("compiler crash"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func compileTreats200WithEmptyBodyAsMalformed() async throws {
    MockURLProtocol.handler = { request in
        return (httpResponse(url: request.url!, status: 200), Data())
    }
    let client = makeTestClient()
    do {
        _ = try await client.compileTypst(source: "= x")
        Issue.record("expected malformedResponse")
    } catch let ImprintCompileError.malformedResponse(msg) {
        #expect(msg.contains("empty"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Ping

@Test func pingReturnsTrueOn200() async {
    MockURLProtocol.handler = { request in
        return (httpResponse(url: request.url!, status: 200), Data("{}".utf8))
    }
    let client = makeTestClient()
    let alive = await client.ping()
    #expect(alive == true)
}

@Test func pingReturnsFalseOnConnectionRefused() async {
    MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
    let client = makeTestClient()
    let alive = await client.ping()
    #expect(alive == false)
}

// MARK: - Bundle compile (Phase 8.10)

@Test func compileBundleReturnsPDFBytesAndHeadersOnSuccess() async throws {
    let pdfBytes = Data("%PDF-1.4\n…fake bundle pdf…".utf8)
    MockURLProtocol.handler = { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/compile/bundle")
        let response = httpResponse(
            url: request.url!,
            status: 200,
            headers: [
                "Content-Type":             "application/pdf",
                "X-Imprint-Compile-Status": "ok",
                "X-Imprint-Page-Count":     "5",
                "X-Imprint-Compile-Ms":     "237",
            ]
        )
        return (response, pdfBytes)
    }
    let client = makeTestClient()
    let result = try await client.compileBundle(
        bundleSHA256: String(repeating: "ab", count: 32),
        mainFile: "paper.typ",
        engine: "typst"
    )
    #expect(result.pdfData == pdfBytes)
    #expect(result.pageCount == 5)
    #expect(result.compileMs == 237)
}

@Test func compileBundleSendsExpectedJSONBody() async throws {
    var capturedBody: Data?
    MockURLProtocol.handler = { request in
        capturedBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, capturedBody?.isEmpty ?? true {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            capturedBody = data
        }
        return (httpResponse(url: request.url!, status: 200, headers: ["X-Imprint-Page-Count": "1"]), Data("%PDF".utf8))
    }
    let client = makeTestClient()
    let sha = String(repeating: "cd", count: 32)
    _ = try await client.compileBundle(
        bundleSHA256: sha,
        mainFile: "paper.tex",
        engine: "pdflatex"
    )
    let json = try #require((try? JSONSerialization.jsonObject(with: capturedBody ?? Data())) as? [String: Any])
    #expect(json["bundle_sha256"] as? String == sha)
    #expect(json["main"] as? String == "paper.tex")
    #expect(json["engine"] as? String == "pdflatex")
}

@Test func compileBundleMapsConnectionRefusedToUnreachable() async {
    MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
    let client = makeTestClient()
    do {
        _ = try await client.compileBundle(
            bundleSHA256: String(repeating: "f", count: 64),
            mainFile: "x.typ",
            engine: "typst"
        )
        Issue.record("expected unreachable")
    } catch let ImprintCompileError.unreachable(_, _) {
        // pass
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func compileBundleMaps422ToCompileError() async {
    MockURLProtocol.handler = { request in
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "error",
            "error": "main file paper.tex not present in bundle",
            "warnings": [],
            "compile_ms": 12,
        ] as [String: Any])
        return (httpResponse(url: request.url!, status: 422), body)
    }
    let client = makeTestClient()
    do {
        _ = try await client.compileBundle(
            bundleSHA256: String(repeating: "ab", count: 32),
            mainFile: "paper.tex",
            engine: "pdflatex"
        )
        Issue.record("expected compileError")
    } catch let ImprintCompileError.compileError(message, _, _) {
        #expect(message.contains("paper.tex"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func compileBundleMaps503ToEngineUnavailable() async {
    MockURLProtocol.handler = { request in
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "error",
            "error": "LaTeX engine xelatex not installed (no TeX distribution detected)",
        ] as [String: Any])
        return (httpResponse(url: request.url!, status: 503), body)
    }
    let client = makeTestClient()
    do {
        _ = try await client.compileBundle(
            bundleSHA256: String(repeating: "ab", count: 32),
            mainFile: "paper.tex",
            engine: "xelatex"
        )
        Issue.record("expected engineUnavailable")
    } catch let ImprintCompileError.engineUnavailable(msg) {
        #expect(msg.contains("xelatex"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func engineUnavailableIsDeferrable() {
    let err = ImprintCompileError.engineUnavailable(message: "x")
    #expect(err.isDeferrable)
}

@Test func compileBundleMaps404ToMalformedResponse() async {
    MockURLProtocol.handler = { request in
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "error",
            "error": "bundle archive not found in blob store: abcdef…",
        ] as [String: Any])
        return (httpResponse(url: request.url!, status: 404), body)
    }
    let client = makeTestClient()
    do {
        _ = try await client.compileBundle(
            bundleSHA256: String(repeating: "ab", count: 32),
            mainFile: "x.typ",
            engine: "typst"
        )
        Issue.record("expected malformedResponse")
    } catch let ImprintCompileError.malformedResponse(msg) {
        #expect(msg.contains("bundle missing"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

}  // end @Suite(.serialized)
