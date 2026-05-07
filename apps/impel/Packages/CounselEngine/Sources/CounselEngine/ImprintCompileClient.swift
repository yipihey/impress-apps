//
//  ImprintCompileClient.swift
//  CounselEngine
//
//  Phase 6 of the impress journal pipeline (per docs/plan-imprint-compile.md).
//
//  Cross-app HTTP client for imprint's stateless compile route. Used by
//  JournalSnapshotJob (Archivist) to convert manuscript-revision source
//  bytes into real PDF artifacts.
//
//  Per the source-of-truth principle in the spec: imprint owns the compile
//  pipeline. impel does NOT link Typst dependencies. The boundary is HTTP,
//  the contract is documented at apps/imprint/Shared/Services/
//  ImprintHTTPRouter.swift `handleStatelessCompile`.
//

import Foundation
import OSLog

private let clientLog = Logger(subsystem: "com.impress.impel", category: "imprint-compile-client")

// MARK: - Errors

public enum ImprintCompileError: Error, LocalizedError {
    /// imprint isn't running / not reachable on the configured port.
    case unreachable(URL, underlying: Error)
    /// Source-level compile failure (HTTP 422). Carries the compiler error message.
    case compileError(message: String, warnings: [String], compileMs: Int)
    /// imprint's compile route exploded (HTTP 500).
    case imprintError(status: Int, body: String)
    /// Response was malformed in some other way (e.g., 200 but empty body).
    case malformedResponse(String)
    /// The compile engine is not installed (HTTP 503). Phase 8 bundle
    /// compile: e.g. LaTeX engines need a TeX distribution that isn't
    /// available. Treated as deferrable so the journal pipeline records
    /// `compile_status: "engine-unavailable"` and keeps working.
    case engineUnavailable(message: String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let url, let err):
            return "imprint not reachable at \(url.absoluteString): \(err.localizedDescription)"
        case .compileError(let msg, _, _):
            return "Typst compile error: \(msg)"
        case .imprintError(let status, let body):
            return "imprint returned HTTP \(status): \(body.prefix(200))"
        case .malformedResponse(let msg):
            return "imprint response was malformed: \(msg)"
        case .engineUnavailable(let msg):
            return "compile engine unavailable: \(msg)"
        }
    }

    /// True if this is a "deferred" failure (imprint isn't reachable, or
    /// the requested engine isn't installed). The snapshot job keeps
    /// working with a placeholder PDF and retries later, rather than
    /// treating the snapshot itself as failed.
    public var isDeferrable: Bool {
        switch self {
        case .unreachable, .engineUnavailable: return true
        default: return false
        }
    }
}

// MARK: - Result

public struct ImprintCompileResult: Sendable {
    public let pdfData: Data
    public let pageCount: Int
    public let compileMs: Int
    public let warnings: [String]

    public init(pdfData: Data, pageCount: Int, compileMs: Int, warnings: [String]) {
        self.pdfData = pdfData
        self.pageCount = pageCount
        self.compileMs = compileMs
        self.warnings = warnings
    }
}

// MARK: - Options (mirror the HTTP route's accepted shape)

public struct ImprintCompileOptions: Sendable {
    public enum PageSize: String, Sendable {
        case a4, letter, a5
    }
    public let pageSize: PageSize
    public let fontSize: Double
    public let marginTop: Double
    public let marginRight: Double
    public let marginBottom: Double
    public let marginLeft: Double

    public init(
        pageSize: PageSize = .a4,
        fontSize: Double = 11.0,
        marginTop: Double = 72.0,
        marginRight: Double = 72.0,
        marginBottom: Double = 72.0,
        marginLeft: Double = 72.0
    ) {
        self.pageSize = pageSize
        self.fontSize = fontSize
        self.marginTop = marginTop
        self.marginRight = marginRight
        self.marginBottom = marginBottom
        self.marginLeft = marginLeft
    }

    public static let `default` = ImprintCompileOptions()

    fileprivate var asJSON: [String: Any] {
        [
            "page_size": pageSize.rawValue,
            "font_size": fontSize,
            "margins": [
                "top": marginTop, "right": marginRight,
                "bottom": marginBottom, "left": marginLeft,
            ],
        ]
    }
}

// MARK: - Client

/// Cross-app HTTP client for imprint's `POST /api/compile/typst` route.
///
/// Owns a single URLSession (configurable for tests via DI). Stateless —
/// each `compile(...)` call is one HTTP request. The session's timeout
/// distinguishes "imprint isn't running" (fast connection-refused) from
/// "imprint is taking too long" (we wait up to 30s by default — Typst
/// compiles for non-trivial papers can take a few seconds on a cold cache).
public actor ImprintCompileClient {

    public static let shared = ImprintCompileClient()

    private let baseURL: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// Default init: production. imprint is expected at 127.0.0.1:23121.
    public init() {
        self.baseURL = URL(string: "http://127.0.0.1:23121")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.requestTimeout = 30
    }

    /// Test/DI init: explicit base URL + session (typically
    /// `URLSession(configuration: ephemeralWith(MockURLProtocol))`).
    public init(baseURL: URL, session: URLSession, requestTimeout: TimeInterval = 5) {
        self.baseURL = baseURL
        self.session = session
        self.requestTimeout = requestTimeout
    }

    // MARK: - Compile

    /// Compile Typst source via imprint's stateless route.
    ///
    /// - Returns: `ImprintCompileResult` with PDF bytes + page count + warnings.
    /// - Throws: `ImprintCompileError`. Callers should inspect `.isDeferrable`
    ///   to decide whether to retry later (imprint not running) or treat the
    ///   error as terminal (source compile error).
    public func compileTypst(
        source: String,
        options: ImprintCompileOptions = .default
    ) async throws -> ImprintCompileResult {
        let url = baseURL.appendingPathComponent("api/compile/typst")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body = options.asJSON
        body["source"] = source
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ImprintCompileError.malformedResponse(
                "could not encode request body: \(error.localizedDescription)"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Connection failures, timeouts, and refused connections all
            // surface here. Treat as deferrable: imprint isn't reachable.
            clientLog.info(
                "compileTypst: imprint unreachable at \(url.absoluteString) — \(error.localizedDescription)"
            )
            throw ImprintCompileError.unreachable(url, underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ImprintCompileError.malformedResponse("response was not HTTP")
        }

        switch http.statusCode {
        case 200:
            return try Self.decodeSuccess(http: http, data: data)
        case 422:
            throw try Self.decodeCompileError(data: data)
        default:
            let body = String(data: data, encoding: .utf8) ?? "(non-UTF-8 body)"
            throw ImprintCompileError.imprintError(status: http.statusCode, body: body)
        }
    }

    /// Compile a manuscript bundle via imprint's `POST /api/compile/bundle`.
    ///
    /// The bundle archive is identified by its SHA-256 in the local
    /// content-addressed blob root; imprint reads the archive directly
    /// from disk (the two apps share the filesystem). This avoids the
    /// overhead of base64-encoding the archive in HTTP.
    ///
    /// - Parameters:
    ///   - bundleSHA256: The 64-character SHA-256 hex of the .tar.zst.
    ///   - mainFile: Relative path of the main source inside the bundle.
    ///   - engine: One of `typst | pdflatex | xelatex | lualatex | latexmk`.
    /// - Throws: `ImprintCompileError`. Inspect `.isDeferrable` to know
    ///   whether to retry later. `engine = none` is rejected at the route.
    public func compileBundle(
        bundleSHA256: String,
        mainFile: String,
        engine: String
    ) async throws -> ImprintCompileResult {
        let url = baseURL.appendingPathComponent("api/compile/bundle")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Bundle compiles can take longer than single-source ones (e.g.,
        // LaTeX with biber), so allow more time on the wire.
        req.timeoutInterval = max(requestTimeout, 60)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "bundle_sha256": bundleSHA256,
            "main": mainFile,
            "engine": engine,
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ImprintCompileError.malformedResponse(
                "could not encode request body: \(error.localizedDescription)"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            clientLog.info(
                "compileBundle: imprint unreachable at \(url.absoluteString) — \(error.localizedDescription)"
            )
            throw ImprintCompileError.unreachable(url, underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ImprintCompileError.malformedResponse("response was not HTTP")
        }

        switch http.statusCode {
        case 200:
            return try Self.decodeSuccess(http: http, data: data)
        case 422:
            throw try Self.decodeCompileError(data: data)
        case 404:
            // Bundle not found in the blob root — surface as a malformed-
            // response error so the journal pipeline records a clear
            // "bundle missing" status rather than retrying forever.
            let msg = (try? Self.parseJSONError(data: data)) ?? "bundle not found"
            throw ImprintCompileError.malformedResponse("bundle missing: \(msg)")
        case 503:
            let msg = (try? Self.parseJSONError(data: data)) ?? "engine not installed"
            throw ImprintCompileError.engineUnavailable(message: msg)
        default:
            let body = String(data: data, encoding: .utf8) ?? "(non-UTF-8 body)"
            throw ImprintCompileError.imprintError(status: http.statusCode, body: body)
        }
    }

    /// Quick check: is imprint reachable? Used by the journal pipeline's
    /// retry logic to gate compile attempts.
    public func ping() async -> Bool {
        let url = baseURL.appendingPathComponent("api/status")
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    nonisolated private static func decodeSuccess(
        http: HTTPURLResponse,
        data: Data
    ) throws -> ImprintCompileResult {
        guard !data.isEmpty else {
            throw ImprintCompileError.malformedResponse("200 response had empty body")
        }
        let pageCount = (http.value(forHTTPHeaderField: "X-Imprint-Page-Count"))
            .flatMap { Int($0) } ?? 0
        let compileMs = (http.value(forHTTPHeaderField: "X-Imprint-Compile-Ms"))
            .flatMap { Int($0) } ?? 0
        let warnings: [String] = (http.value(forHTTPHeaderField: "X-Imprint-Warnings"))
            .map { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
            ?? []
        return ImprintCompileResult(
            pdfData: data,
            pageCount: pageCount,
            compileMs: compileMs,
            warnings: warnings
        )
    }

    nonisolated private static func decodeCompileError(data: Data) throws -> Error {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImprintCompileError.malformedResponse(
                "422 response body was not JSON: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
            )
        }
        let msg = (obj["error"] as? String) ?? "unknown compile error"
        let warnings = (obj["warnings"] as? [String]) ?? []
        let compileMs = (obj["compile_ms"] as? Int) ?? 0
        return ImprintCompileError.compileError(
            message: msg,
            warnings: warnings,
            compileMs: compileMs
        )
    }

    nonisolated private static func parseJSONError(data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["error"] as? String
        else {
            return String(data: data, encoding: .utf8)?.prefix(200).description ?? "(unknown)"
        }
        return msg
    }
}
