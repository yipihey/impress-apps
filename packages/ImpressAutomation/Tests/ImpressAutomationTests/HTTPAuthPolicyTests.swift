//
//  HTTPAuthPolicyTests.swift
//  ImpressAutomationTests
//
//  Full decision matrix for the network-access policy. This gate is what
//  keeps "Mac drives the phone over Tailscale" from ever meaning "anyone on
//  the network drives the phone."
//

import Testing
@testable import ImpressAutomation

@Suite("HTTP Auth Policy")
struct HTTPAuthPolicyTests {

    private let token = "imbib-net-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    @Test("Loopback peers always pass, token or not")
    func loopbackAlwaysAllowed() {
        for allow in [true, false] {
            for tok in [token, ""] {
                #expect(
                    HTTPAuthPolicy.evaluate(
                        peerIsLoopback: true,
                        allowNetworkAccess: allow,
                        authToken: tok.isEmpty ? nil : tok,
                        authorizationHeader: nil
                    ) == .allow
                )
            }
        }
    }

    @Test("Remote denied when network access is disabled")
    func remoteDeniedWhenDisabled() {
        let decision = HTTPAuthPolicy.evaluate(
            peerIsLoopback: false,
            allowNetworkAccess: false,
            authToken: token,
            authorizationHeader: "Bearer \(token)"
        )
        #expect(decision != .allow)
    }

    @Test("Remote denied without a configured token")
    func remoteDeniedWithoutToken() {
        for configured in [nil, ""] as [String?] {
            let decision = HTTPAuthPolicy.evaluate(
                peerIsLoopback: false,
                allowNetworkAccess: true,
                authToken: configured,
                authorizationHeader: "Bearer whatever"
            )
            #expect(decision != .allow)
        }
    }

    @Test("Remote denied with missing or malformed header")
    func remoteDeniedWithBadHeader() {
        for header in [nil, "", "Basic abc", "Bearer", "bearer"] as [String?] {
            let decision = HTTPAuthPolicy.evaluate(
                peerIsLoopback: false,
                allowNetworkAccess: true,
                authToken: token,
                authorizationHeader: header
            )
            #expect(decision != .allow, "header \(header ?? "nil") must be denied")
        }
    }

    @Test("Remote denied with wrong token")
    func remoteDeniedWithWrongToken() {
        let decision = HTTPAuthPolicy.evaluate(
            peerIsLoopback: false,
            allowNetworkAccess: true,
            authToken: token,
            authorizationHeader: "Bearer imbib-net-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        )
        #expect(decision != .allow)
    }

    @Test("Remote allowed with exact token, case-insensitive scheme")
    func remoteAllowedWithToken() {
        for scheme in ["Bearer", "bearer", "BEARER"] {
            let decision = HTTPAuthPolicy.evaluate(
                peerIsLoopback: false,
                allowNetworkAccess: true,
                authToken: token,
                authorizationHeader: "\(scheme) \(token)"
            )
            #expect(decision == .allow, "scheme \(scheme)")
        }
    }

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
        #expect(a.hasPrefix("imbib-net-"))
        #expect(a.count > 40)
        #expect(a != b)
    }
}
