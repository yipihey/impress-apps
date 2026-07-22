//
//  TokenGating.swift
//  PublicationManagerCoreTests
//
//  Token gate for GENUINE live integration tests (ScixLiveIntegrationTests):
//  tests that drive the real Rust FFI → real SciX/ADS API → conversion pipeline
//  end-to-end. They need a real token, so they XCTSkip cleanly when none is set
//  (CI/tokenless shells stay green) and run when SCIX_API_TOKEN/ADS_API_TOKEN is
//  present. This is deliberately NOT used to prop up mock-based unit tests — the
//  deterministic parsing/mapping logic is covered token-free by
//  ScixConversionsTests.
//

import XCTest

/// A live ADS/SciX API token from the environment, if present.
enum TokenGate {
    static var apiToken: String? {
        ProcessInfo.processInfo.environment["SCIX_API_TOKEN"]
            ?? ProcessInfo.processInfo.environment["ADS_API_TOKEN"]
    }
}

extension XCTestCase {
    /// Skip the current test when no live token is available, otherwise return
    /// it. Use at the top of a live integration test:
    /// `let token = try requireLiveToken()`.
    func requireLiveToken(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTSkipIf(
            TokenGate.apiToken == nil,
            "Live integration test — set SCIX_API_TOKEN or ADS_API_TOKEN to run",
            file: file, line: line)
        return TokenGate.apiToken!
    }
}
