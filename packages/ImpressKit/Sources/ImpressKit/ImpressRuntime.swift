import Foundation

/// Process-environment introspection shared across the impress suite.
public enum ImpressRuntime {

    /// True when running inside an XCTest host (swift test / xctest worker),
    /// as opposed to a real app process.
    ///
    /// The load-bearing check is `NSClassFromString("XCTestCase")` — the
    /// XCTest runtime is linked into every test process but never into a
    /// shipping app. The env vars are a fast path only: SPM's `swift test`
    /// runner does NOT reliably set them (observed empty under Xcode 17).
    ///
    /// Why this matters: an xctest worker has no App Group entitlement, and
    /// merely `open()`ing a path inside the shared group container can block
    /// FOREVER in the kernel's authorization check (same failure class as
    /// the imprint launch TCC hang). Unit tests must therefore never touch
    /// the production container — see `SharedContainer.rootDirectory`.
    ///
    /// XCUITest is unaffected: it launches the real app process (no XCTest
    /// runtime there), which opts into test stores via `--ui-testing`.
    public static let isUnitTestProcess: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()
}
