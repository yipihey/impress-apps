import XCTest

/// Live ADS/SciX API token from the environment, if present.
enum TokenGate {
    static var apiToken: String? {
        ProcessInfo.processInfo.environment["SCIX_API_TOKEN"]
            ?? ProcessInfo.processInfo.environment["ADS_API_TOKEN"]
    }
}

extension XCTestCase {
    /// Skip a test that requires a live ADS/SciX API token + network. These
    /// tests were written against a retired URLSession-mock architecture; the
    /// sources now call the Rust FFI (real network), so they cannot run
    /// deterministically without a token. See the durable-rewrite note in the
    /// PMC test-suite cleanup.
    func skipIfNoToken() throws {
        try XCTSkipIf(TokenGate.apiToken == nil,
                      "Requires a live SCIX_API_TOKEN / ADS_API_TOKEN (network test)")
    }
}
