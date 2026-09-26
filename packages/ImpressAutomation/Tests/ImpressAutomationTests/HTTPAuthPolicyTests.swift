//
//  HTTPAuthPolicyTests.swift
//  ImpressAutomationTests
//
//  Full decision matrix for the access policy. Two gates: the network one
//  keeps "Mac drives the phone over Tailscale" from ever meaning "anyone on
//  the network drives the phone"; the loopback one (P0, SEC-2) keeps "any
//  process on this Mac" from meaning "any process can mutate".
//

import Testing
@testable import ImpressAutomation

@Suite("HTTP Auth Policy")
struct HTTPAuthPolicyTests {

    private let token = "imbib-net-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let loopback = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func loopbackDecision(
        _ method: String, loopbackToken: String?, header: String?
    ) -> HTTPAuthDecision {
        HTTPAuthPolicy.evaluate(
            method: method,
            peerIsLoopback: true,
            loopbackToken: loopbackToken,
            allowNetworkAccess: false,
            authToken: nil,
            authorizationHeader: header)
    }

    private func remoteDecision(
        allow: Bool = true, authToken: String?, header: String?
    ) -> HTTPAuthDecision {
        HTTPAuthPolicy.evaluate(
            method: "POST",
            peerIsLoopback: false,
            loopbackToken: loopback,
            allowNetworkAccess: allow,
            authToken: authToken,
            authorizationHeader: header)
    }

    // MARK: - Loopback

    @Test("Loopback GET, HEAD and OPTIONS pass with no token, installed or not")
    func loopbackReadsAreTokenFree() {
        for method in ["GET", "get", "HEAD", "OPTIONS"] {
            for installed in [loopback, nil] {
                #expect(loopbackDecision(method, loopbackToken: installed, header: nil) == .allow)
            }
        }
    }

    @Test("Loopback non-GET without the token is denied")
    func loopbackMutationNeedsToken() {
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            for header in [nil, "", "Basic abc", "Bearer", "Bearer "] as [String?] {
                #expect(
                    loopbackDecision(method, loopbackToken: loopback, header: header) != .allow,
                    "\(method) with header \(header ?? "nil") must be denied")
            }
        }
    }

    @Test("Loopback non-GET with the token passes, case-insensitive scheme")
    func loopbackMutationWithToken() {
        for scheme in ["Bearer", "bearer", "BEARER"] {
            #expect(
                loopbackDecision("POST", loopbackToken: loopback, header: "\(scheme) \(loopback)")
                    == .allow)
        }
    }

    @Test("Loopback non-GET with the wrong token, or the network token, is denied")
    func loopbackMutationWrongToken() {
        #expect(loopbackDecision("POST", loopbackToken: loopback, header: "Bearer \(loopback)x") != .allow)
        #expect(loopbackDecision("POST", loopbackToken: loopback, header: "Bearer \(token)") != .allow)
    }

    @Test("No loopback token installed fails CLOSED for every mutation")
    func loopbackNoTokenInstalledFailsClosed() {
        for installed in [nil, ""] as [String?] {
            #expect(
                loopbackDecision("POST", loopbackToken: installed, header: "Bearer \(loopback)")
                    != .allow)
        }
    }

    // MARK: - Remote

    @Test("Remote denied when network access is disabled")
    func remoteDeniedWhenDisabled() {
        #expect(remoteDecision(allow: false, authToken: token, header: "Bearer \(token)") != .allow)
    }

    @Test("Remote denied without a configured token")
    func remoteDeniedWithoutToken() {
        for configured in [nil, ""] as [String?] {
            #expect(remoteDecision(authToken: configured, header: "Bearer whatever") != .allow)
        }
    }

    @Test("Remote denied with missing or malformed header")
    func remoteDeniedWithBadHeader() {
        for header in [nil, "", "Basic abc", "Bearer", "bearer"] as [String?] {
            #expect(remoteDecision(authToken: token, header: header) != .allow, "header \(header ?? "nil") must be denied")
        }
    }

    @Test("Remote denied with wrong token, and with the loopback token")
    func remoteDeniedWithWrongToken() {
        #expect(
            remoteDecision(
                authToken: token,
                header: "Bearer imbib-net-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
                != .allow)
        #expect(remoteDecision(authToken: token, header: "Bearer \(loopback)") != .allow)
    }

    @Test("Remote allowed with exact token, case-insensitive scheme")
    func remoteAllowedWithToken() {
        for scheme in ["Bearer", "bearer", "BEARER"] {
            #expect(remoteDecision(authToken: token, header: "\(scheme) \(token)") == .allow, "scheme \(scheme)")
        }
    }

    @Test("A remote GET still needs the network bearer")
    func remoteGetNeedsBearer() {
        let decision = HTTPAuthPolicy.evaluate(
            method: "GET", peerIsLoopback: false, loopbackToken: loopback,
            allowNetworkAccess: true, authToken: token, authorizationHeader: nil)
        #expect(decision != .allow)
    }

    // MARK: - Helpers

    @Test("Constant-time compare correctness")
    func constantTimeCompare() {
        #expect(HTTPAuthPolicy.constantTimeEquals("abc", "abc"))
        #expect(!HTTPAuthPolicy.constantTimeEquals("abc", "abd"))
        #expect(!HTTPAuthPolicy.constantTimeEquals("abc", "abcd"))
        #expect(!HTTPAuthPolicy.constantTimeEquals("", "a"))
        #expect(HTTPAuthPolicy.constantTimeEquals("", ""))
    }

    @Test("Generated tokens are long, prefixed, and unique")
    func tokenGeneration() {
        let a = HTTPAuthPolicy.generateToken()
        let b = HTTPAuthPolicy.generateToken()
        #expect(a.hasPrefix("impress-net-"))
        #expect(a.count > 40)
        #expect(a != b)
        #expect(HTTPAuthPolicy.generateToken(prefix: "imbib-net").hasPrefix("imbib-net-"))
    }

    @Test("Network mode refuses without a token or a bind address")
    func networkModeRefusals() {
        let base = HTTPServerConfiguration(port: 1, loggerSubsystem: "t")
        #expect(base.networkModeRefusal == nil)
        #expect(
            HTTPServerConfiguration(port: 1, loggerSubsystem: "t", allowNetworkAccess: true)
                .networkModeRefusal != nil)
        #expect(
            HTTPServerConfiguration(
                port: 1, loggerSubsystem: "t", allowNetworkAccess: true, authToken: token)
                .networkModeRefusal != nil)
        #expect(
            HTTPServerConfiguration(
                port: 1, loggerSubsystem: "t", allowNetworkAccess: true, authToken: token,
                bindAddress: "  ")
                .networkModeRefusal != nil)
        #expect(
            HTTPServerConfiguration(
                port: 1, loggerSubsystem: "t", allowNetworkAccess: true, authToken: token,
                bindAddress: "100.64.0.7")
                .networkModeRefusal == nil)
    }
}

@Suite("HTTP Host Policy")
struct HTTPHostPolicyTests {

    @Test("The loopback names pass, with or without a port")
    func loopbackNames() {
        for host in [
            "localhost", "localhost:23120", "127.0.0.1", "127.0.0.1:23261", "[::1]", "[::1]:23125",
            "LOCALHOST:1", " localhost ",
        ] {
            #expect(HTTPHostPolicy.isAllowed(hostHeader: host, bindAddress: nil), "\(host)")
        }
    }

    @Test("A rebound or foreign Host is refused")
    func foreignHosts() {
        for host in [
            "attacker", "attacker.example:23120", "127.0.0.1.evil.example", "localhost.evil",
            "evil.example", "::1", "127.0.0.1:abc", "[::1", "", "   ",
        ] {
            #expect(!HTTPHostPolicy.isAllowed(hostHeader: host, bindAddress: nil), "\(host)")
        }
        #expect(!HTTPHostPolicy.isAllowed(hostHeader: nil, bindAddress: nil))
    }

    @Test("The bound network address is admitted only when configured")
    func boundAddress() {
        #expect(HTTPHostPolicy.isAllowed(hostHeader: "100.64.0.7:23120", bindAddress: "100.64.0.7"))
        #expect(HTTPHostPolicy.isAllowed(hostHeader: "[fd7a::7]:23120", bindAddress: "fd7a::7"))
        #expect(!HTTPHostPolicy.isAllowed(hostHeader: "100.64.0.7:23120", bindAddress: nil))
        #expect(!HTTPHostPolicy.isAllowed(hostHeader: "100.64.0.8:23120", bindAddress: "100.64.0.7"))
    }
}
