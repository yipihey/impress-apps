//
//  HTTPAuthPolicy.swift
//  ImpressAutomation
//
//  Access policy for the automation HTTP server. Pure functions so the full
//  decision matrix is unit-testable.
//
//  Model (plan verb-pipeline P0, SEC-2..SEC-5):
//  - A loopback peer's GET/HEAD/OPTIONS passes without a token: the read-only
//    routes, so `curl localhost:23120/api/logs` is byte-identical to before.
//  - A loopback peer's ANY OTHER method must present this launch's loopback
//    token — `Authorization: Bearer <token>` where the token is the one the
//    server wrote at start (`LoopbackToken`, the Rust contract
//    `impress_core::loopback_token`). Loopback used to pass untouched, on
//    every route: any process on the machine, including a browser tab after
//    DNS rebinding, could mutate. It cannot now.
//  - A non-loopback peer is allowed only when network access is explicitly
//    enabled AND a network token is configured AND the request carries
//    exactly `Authorization: Bearer <network token>`.
//  - Everything else — indeterminate peers included — is DENIED. Mirrors the
//    Bearer parsing of impel-server's auth middleware; that middleware's old
//    fail-open arm is gone too (SEC-8).
//  - The `Host` header is checked BEFORE any of this, by `HTTPHostPolicy`.
//

import Foundation

public enum HTTPAuthDecision: Equatable, Sendable {
    case allow
    /// Denied: respond 401 with this reason (not echoed verbatim to remote
    /// callers beyond a generic message; reason is for logs).
    case deny(reason: String)
}

public enum HTTPAuthPolicy {

    /// The methods that never mutate and so never need the loopback token.
    public static let safeMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]

    /// Decide whether a request may proceed to routing.
    ///
    /// - Parameters:
    ///   - method: the request method (case-insensitive).
    ///   - peerIsLoopback: true only when the transport peer is positively
    ///     identified as loopback (127.0.0.0/8 or ::1). `nil`/unknown must be
    ///     passed as `false` — indeterminate peers are treated as remote.
    ///   - loopbackToken: this launch's loopback token, once installed. `nil`
    ///     (not installed yet, or the install failed) denies every loopback
    ///     mutation — fail closed, never open.
    ///   - allowNetworkAccess: the user's explicit opt-in toggle.
    ///   - authToken: the configured network bearer (nil = none configured).
    ///   - authorizationHeader: the request's `authorization` header, if any.
    public static func evaluate(
        method: String,
        peerIsLoopback: Bool,
        loopbackToken: String?,
        allowNetworkAccess: Bool,
        authToken: String?,
        authorizationHeader: String?
    ) -> HTTPAuthDecision {
        if peerIsLoopback {
            if safeMethods.contains(method.uppercased()) {
                return .allow
            }
            guard let expected = loopbackToken, !expected.isEmpty else {
                return .deny(reason: "no loopback token installed")
            }
            guard let presented = bearer(of: authorizationHeader) else {
                return .deny(reason: "missing loopback bearer")
            }
            return constantTimeEquals(presented, expected)
                ? .allow : .deny(reason: "invalid loopback token")
        }
        guard allowNetworkAccess else {
            // Defense in depth: with the toggle off the listener should be
            // loopback-bound anyway, so a remote peer here means the bind
            // and the policy disagree — deny.
            return .deny(reason: "network access disabled")
        }
        guard let token = authToken, !token.isEmpty else {
            return .deny(reason: "no auth token configured")
        }
        guard let presented = bearer(of: authorizationHeader) else {
            return .deny(reason: "missing bearer authorization")
        }
        guard constantTimeEquals(presented, token) else {
            return .deny(reason: "invalid token")
        }
        return .allow
    }

    /// The token in `Bearer <token>` (scheme case-insensitive, surrounding
    /// whitespace ignored), or nil for any other shape including an empty
    /// token.
    static func bearer(of header: String?) -> String? {
        guard let header, header.count >= 7, header.prefix(7).lowercased() == "bearer " else {
            return nil
        }
        let presented = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        return presented.isEmpty ? nil : presented
    }

    /// Constant-time string equality — comparison cost independent of where
    /// the first mismatch occurs (timing-attack hygiene).
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }

    /// Generate a fresh network-access token: `<prefix>-` + 32 random bytes
    /// hex-encoded (length > 40, prefix-scoped). The default prefix is the
    /// suite's; an app may pass its own.
    public static func generateToken(prefix: String = "impress-net") -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes essentially cannot fail on Apple platforms;
            // fall back to SystemRandomNumberGenerator rather than crash.
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hex)"
    }
}

/// The `Host` header check (P0, SEC-3), run before auth and before routing.
///
/// A web page cannot set `Host`; the browser writes the name the page
/// dialled. After DNS rebinding that name resolves to 127.0.0.1 but the
/// header still says `attacker.example`, so refusing every `Host` that is not
/// a spelling of this machine is what stops a rebound page from driving the
/// server at all — the token then only has to hold against a process that
/// can already read the token file.
public enum HTTPHostPolicy {

    /// The names a caller on this machine legitimately dials.
    static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// Whether `hostHeader` names this server. `bindAddress` is the
    /// explicit address of network mode, accepted alongside the loopback
    /// names. A missing or empty header is refused: every client that
    /// speaks HTTP/1.1 sends one.
    public static func isAllowed(hostHeader: String?, bindAddress: String?) -> Bool {
        guard let name = hostName(of: hostHeader) else { return false }
        if loopbackNames.contains(name) { return true }
        if let bound = bindAddress?.trimmingCharacters(in: .whitespaces), !bound.isEmpty {
            return name == normalized(bound)
        }
        return false
    }

    /// The host part of a `Host` header, lowercased, port stripped, an IPv6
    /// literal kept in its brackets. Nil for an empty or unparsable value.
    static func hostName(of header: String?) -> String? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty
        else { return nil }
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]") else { return nil }
            let literal = String(raw[...close])
            let rest = raw[raw.index(after: close)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && rest.dropFirst().allSatisfy(\.isNumber))
            else { return nil }
            return literal
        }
        // A bare IPv6 (two or more colons) is not a valid Host; refuse it.
        let colons = raw.filter { $0 == ":" }.count
        if colons > 1 { return nil }
        if let colon = raw.firstIndex(of: ":") {
            let port = raw[raw.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            return String(raw[..<colon])
        }
        return raw
    }

    /// A configured bind address in the form a `Host` header carries it.
    static func normalized(_ address: String) -> String {
        let lower = address.lowercased()
        if lower.contains(":"), !lower.hasPrefix("[") { return "[\(lower)]" }
        return lower
    }
}
