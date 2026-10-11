//
//  KoineWebRoutes.swift
//  ImpressAutomation
//
//  `GET /ui/*`: the koine web frontend, served by every app's automation
//  server (koine `docs/plan-koine-web.md` D8, D9). The bundle is the Dioxus
//  build of `crates/koine-web` in the koine repository, copied into this
//  package's `Resources/koine-web/` by `scripts/build-koine-web.sh`; this
//  route only hands those files out. It is the first static route the server
//  has had — everything else answers JSON — and it decides nothing about the
//  page: the router inside the bundle owns `/ui/surface/<id>`, `/ui/layout`
//  and `/ui/style`, so any path under `/ui/` that is not a file in the
//  bundle answers `index.html` and lets the page route it.
//
//  THE TOKEN. A dispatch from the page is a POST, and a POST needs this
//  launch's loopback token (SEC-2). A page cannot read the token file, so
//  the one copy of `index.html` served to a LOOPBACK peer carries it as
//  `<meta name="koine-token" content="…">`. A remote peer (network access
//  on, a bearer presented) gets the same page without the meta: the loopback
//  token is for loopback, and the page then asks the person to paste one.
//  `HTTPRequest.peerIsLoopback` is set by `HTTPServer` from the connection,
//  never from a header.
//
//  Matching is on the RAW path, before `SharedAutomationRoutes.normalize`
//  lowercases it: a bundle file name keeps its case.
//

import Foundation

public enum KoineWebRoutes {

    /// The mount point. `paths` in `SharedAutomationRoutes` lists it.
    public static let prefix = "/ui"

    /// The folder the bundle is copied into (`Resources/koine-web`).
    static let resourceFolder = "koine-web"

    static func matches(_ rawPath: String) -> Bool {
        rawPath == prefix || rawPath.hasPrefix(prefix + "/")
    }

    /// Answer `request` if it is a `GET` under `/ui`; `nil` otherwise.
    public static func route(_ request: HTTPRequest) -> HTTPResponse? {
        guard matches(request.path) else { return nil }
        guard request.method.uppercased() == "GET" else {
            return .json(
                ["status": "error", "reason": "method not allowed", "allowed": "GET"],
                status: 405)
        }
        guard let root = bundleRoot() else { return missingBundle() }
        return serve(
            relativePath: String(request.path.dropFirst(prefix.count)),
            from: root,
            token: token(for: request))
    }

    // MARK: - Files

    /// One request against a bundle folder. Pure given the folder, so a test
    /// can point it at a temporary directory.
    static func serve(relativePath: String, from root: URL, token: String?) -> HTTPResponse {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/").map(String.init)
        // No `..`, no hidden files: the bundle is flat and public.
        if components.contains(where: { $0 == ".." || $0.hasPrefix(".") }) {
            return .json(["status": "error", "reason": "not found"], status: 404)
        }
        let index = root.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path) else { return missingBundle() }

        // A file in the bundle is served as itself. Anything else — `/ui`,
        // `/ui/`, `/ui/surface/<id>` — is the page, which routes it.
        if !components.isEmpty, let last = components.last, last.contains(".") {
            let file = root.appendingPathComponent(components.joined(separator: "/"))
            if let data = FileManager.default.contents(atPath: file.path) {
                return HTTPResponse(
                    status: 200,
                    statusText: "OK",
                    headers: [
                        "Content-Type": contentType(forExtension: file.pathExtension),
                        "Cache-Control": "no-cache",
                    ],
                    body: data)
            }
            return .json(["status": "error", "reason": "not found"], status: 404)
        }

        guard let html = FileManager.default.contents(atPath: index.path),
            let text = String(data: html, encoding: .utf8)
        else { return missingBundle() }
        return HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
            ],
            body: Data(inject(token: token, into: text).utf8))
    }

    /// `<meta name="koine-token" content="…">` before `</head>` (or at the
    /// start when the page has no head). `nil` leaves the page untouched.
    static func inject(token: String?, into html: String) -> String {
        guard let token, !token.isEmpty else { return html }
        let escaped =
            token
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let meta = "<meta name=\"koine-token\" content=\"\(escaped)\">"
        if let range = html.range(of: "</head>") {
            return html.replacingCharacters(in: range, with: meta + "</head>")
        }
        return meta + html
    }

    /// The loopback token for the port this request arrived on, for a
    /// loopback peer only; `nil` otherwise. Reads the file the server wrote
    /// at launch (`LoopbackToken.path(port:)`), one line.
    static func token(for request: HTTPRequest) -> String? {
        guard request.peerIsLoopback, let port = request.localPort else { return nil }
        guard let text = try? String(contentsOfFile: LoopbackToken.path(port: port), encoding: .utf8)
        else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? nil : line
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    static func bundleRoot() -> URL? {
        Bundle.module.url(forResource: resourceFolder, withExtension: nil)
    }

    static func missingBundle() -> HTTPResponse {
        .json(
            [
                "status": "error",
                "reason": "koine-web bundle is not in this build",
                "fix": "run scripts/build-koine-web.sh and rebuild the app",
            ],
            status: 503)
    }
}
