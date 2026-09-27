import Foundation
import XCTest
@testable import ImpressAutomation

final class LaunchOverrideTests: XCTestCase {
    func testLaunchPortOverridesLegacyRecordWithoutSavingIt() {
        let name = "com.impress.launch-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.setVolatileDomain([
            AutomationServerSettings.Keys.port: "23331",
            AutomationServerSettings.Keys.enabled: "YES"
        ], forName: UserDefaults.argumentDomain)
        let saved = AutomationServerSettings(
            httpEnabled: false, port: 23120, logRequests: false,
            allowNetworkAccess: true, networkAuthToken: "fixture", networkBindAddress: "100.64.0.1")
        let effective = saved.applyingLaunchOverrides(from: defaults)
        XCTAssertEqual(effective.port, 23331)
        XCTAssertTrue(effective.httpEnabled)
        XCTAssertFalse(effective.logRequests)
        XCTAssertEqual(effective.networkAuthToken, saved.networkAuthToken)
        XCTAssertEqual(effective.networkBindAddress, saved.networkBindAddress)
        XCTAssertTrue(effective.allowNetworkAccess)
        XCTAssertNil(defaults.persistentDomain(forName: name)?[AutomationServerSettings.Keys.port])

        defaults.setVolatileDomain([
            AutomationServerSettings.Keys.port: "70000"
        ], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(saved.applyingLaunchOverrides(from: defaults), saved)
    }
}
