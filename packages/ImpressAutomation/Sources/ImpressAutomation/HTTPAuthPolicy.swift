//
//  HTTPAuthPolicy.swift
//  ImpressAutomation
//
//  Access policy for the automation HTTP server when network (non-loopback)
//  access is enabled — the "Mac Claude Code drives the phone over Tailscale"
//  feature. Pure function so the full decision matrix is unit-testable.
//
//  Model:
//  - Loopback peers are always allowed WITHOUT a token: existing localhost
//    MCP/curl workflows are byte-identical to before this feature existed.
//  - Non-loopback peers are allowed only when network access is explicitly
//    enabled AND a token is configured AND the request carries exactly
//    `Authorization: Bearer <token>` (constant-time compare).
//  - Everything else — indeterminate peers included — is DENIED. Mirrors the
//    Bearer parsing of impel-server's auth middleware but deliberately NOT
//    its fail-open development arm.
//

import Foundation

public enum HTTPAuthDecision: Equatable, Sendable {
    case allow
    /// Denied: respond 401 with this reason (not echoed verbatim to remote
    /// callers beyond a generic message; reason is for logs).
    case deny(reason: String)
}

public enum HTTPAuthPolicy {

    /// Decide whether a request may proceed to routing.
    ///
    /// - Parameters:
    ///   - peerIsLoopback: true only when the transport peer is positively
    ///     identified as loopback (127.0.0.0/8 or ::1). `nil`/unknown must be
    ///     passed as `false` — indeterminate peers are treated as remote.
    ///   - allowNetworkAccess: the user's explicit opt-in toggle.
    ///   - authToken: the configured bearer token (nil = none configured).
    ///   - authorizationHeader: the request's `authorization` header, if any.
    public static func evaluate(
        peerIsLoopback: Bool,
        allowNetworkAccess: Bool,
        authToken: String?,
        authorizationHeader: String?
    ) -> HTTPAuthDecision {
        if peerIsLoopback {
            return .allow
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
        guard let header = authorizationHeader,
              header.count >= 7,
              header.prefix(7).lowercased() == "bearer "
        else {
            return .deny(reason: "missing bearer authorization")
        }
        let presented = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        guard constantTimeEquals(presented, token) else {
            return .deny(reason: "invalid token")
        }
        return .allow
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

    /// Generate a fresh network-access token: `imbib-net-` + 32 random bytes
    /// hex-encoded (length > 40, prefix-scoped, mirroring the impel token
    /// format conventions).
    public static func generateToken(prefix: String = "imbib-net") -> String {
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
