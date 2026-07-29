//
//  KeychainAvailability.swift
//  PublicationManagerCoreTests
//
//  Suites that exercise the REAL login keychain (CredentialManager over
//  KeychainSwift) cannot run everywhere: under a launchd-run CI runner (the
//  self-hosted service) the unsigned test binary's keychain writes are denied
//  non-interactively and every such test fails with storageFailed. This probe
//  lets those suites skip honestly in that environment while running in full
//  from any interactive session.
//

import XCTest
@testable import PublicationManagerCore

/// Throws `XCTSkip` when the login keychain refuses writes in this
/// environment. Call from `setUp()` of any suite that stores real
/// credentials.
func XCTSkipUnlessKeychainAvailable() async throws {
    let probe = CredentialManager(keyPrefix: "test.keychain-probe.\(UUID().uuidString)")
    do {
        try await probe.store("probe", for: "keychain-probe", type: .apiKey)
        await probe.delete(for: "keychain-probe", type: .apiKey)
    } catch {
        throw XCTSkip("login keychain unavailable in this environment (\(error))")
    }
}
