import XCTest
import SwiftUI
import ImpressRustCore
@testable import ImpressKit

/// The registry as Swift sees it (ADR-0036 D5, plan R1): a value comes from
/// the registry, a legacy `UserDefaults` value is copied in once and never
/// removed (D-R5), a misspelt key is an error rather than a default, and the
/// port defaults the registry declares are the suite's one port table.
@MainActor
final class SettingsRegistryTests: XCTestCase {

    private var scratch: URL!
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-settings-\(UUID().uuidString)")
        suiteName = "impress-settings-tests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        ImpressSettings.shared._resetForTesting()
        ImpressSettings.shared.workspaceDirectory = scratch
        ImpressSettings.shared.legacyStores = [suite]
    }

    override func tearDown() async throws {
        ImpressSettings.shared._resetForTesting()
        ImpressSettings.shared.workspaceDirectory = SharedWorkspace.workspaceDirectory
        ImpressSettings.shared.legacyStores = [.standard, SharedDefaults.suite]
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
    }

    func testDefaultComesFromTheRegistryAndSetWritesTheScopeFile() throws {
        XCTAssertEqual(ImpressSettings.shared.value("imbib.retention.inbox_days", as: Int.self), 30)
        XCTAssertEqual(ImpressSettings.shared.record("imbib.retention.inbox_days")?.source, "default")

        ImpressSettings.shared.set("imbib.retention.inbox_days", 7)
        XCTAssertEqual(ImpressSettings.shared.value("imbib.retention.inbox_days", as: Int.self), 7)
        let file = scratch.appendingPathComponent("settings/device.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"imbib.retention.inbox_days\": 7"), text)

        ImpressSettings.shared.reset("imbib.retention.inbox_days")
        XCTAssertEqual(ImpressSettings.shared.value("imbib.retention.inbox_days", as: Int.self), 30)
    }

    /// The migration test the plan names: seed `UserDefaults` in a scratch
    /// suite, read through the wrapper, assert the file value AND that the
    /// old key is still there.
    func testLegacyValueIsCopiedOnFirstReadAndNeverRemoved() throws {
        suite.set(90, forKey: "inbox.retentionDays")
        suite.set(true, forKey: "inbox.autoRemoveRead")

        struct Probe {
            @ImpressSetting("imbib.retention.inbox_days") var days: Int
            @ImpressSetting("imbib.retention.auto_remove_read") var autoRemove: Bool
        }
        let probe = Probe()
        XCTAssertEqual(probe.days, 90)
        XCTAssertTrue(probe.autoRemove)

        let text = try String(
            contentsOf: scratch.appendingPathComponent("settings/device.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"imbib.retention.inbox_days\": 90"), text)
        XCTAssertTrue(text.contains("\"imbib.retention.auto_remove_read\": true"), text)
        XCTAssertEqual(suite.integer(forKey: "inbox.retentionDays"), 90, "D-R5: never removed")
        XCTAssertNotNil(suite.object(forKey: "inbox.autoRemoveRead"), "D-R5: never removed")

        // A stored value is never overridden by the legacy one again.
        probe.days = 14
        suite.set(3, forKey: "inbox.retentionDays")
        ImpressSettings.shared._resetForTesting()
        ImpressSettings.shared.workspaceDirectory = scratch
        ImpressSettings.shared.legacyStores = [suite]
        XCTAssertEqual(Probe().days, 14)
    }

    func testAMisspeltKeyIsAnErrorNotADefault() {
        XCTAssertFalse(ImpressSettings.shared.knownKeys.contains("imbib.retention.inboxDays"))
        XCTAssertNil(ImpressSettings.shared.record("imbib.retention.inboxDays"))
        XCTAssertEqual(ImpressSettings.shared.value("imbib.retention.inboxDays", as: Int.self), 0)
        // The declared type wins over the property's: a Bool read of an
        // integer key answers zero, and nothing is written.
        XCTAssertFalse(ImpressSettings.shared.value("imbib.retention.inbox_days", as: Bool.self))
        XCTAssertEqual(ImpressSettings.shared.record("imbib.retention.inbox_days")?.source, "default")
    }

    /// `impress_settings::registry::APP_PORTS` transcribes the ONE port
    /// table (`SiblingApp.descriptors`); this is what keeps the copy honest.
    func testAutomationPortDefaultsAreTheSuitePortTable() {
        for descriptor in SiblingApp.descriptors {
            let key = "\(descriptor.id.rawValue).automation.http_port"
            let record = ImpressSettings.shared.record(key)
            XCTAssertEqual(
                record?.defaultJson, String(descriptor.httpPort),
                "\(key): the registry default must equal SiblingApp.descriptors")
            XCTAssertEqual(record?.scope, "app:\(descriptor.id.rawValue)")
        }
    }

    /// Every legacy key the registry names for the automation section is one
    /// the shared settings section actually writes — the census, pinned.
    func testAutomationLegacyKeysAreTheOnesTheAppsWrite() {
        let expected: [String: String] = [
            "http_enabled": "httpAutomationEnabled",
            "http_port": "httpAutomationPort",
            "log_requests": "httpAutomationLogRequests",
            "allow_network_access": "httpAutomationAllowNetworkAccess",
            "network_bind_address": "httpAutomationNetworkBindAddress",
        ]
        for (suffix, legacy) in expected {
            let record = ImpressSettings.shared.record("imbib.automation.\(suffix)")
            XCTAssertEqual(record?.legacy, [legacy], suffix)
        }
    }

    func testLaunchArgumentOverridesDoNotMigrateIntoTheRegistry() throws {
        let portKey = "httpAutomationPort"
        let enabledKey = "httpAutomationEnabled"
        suite.set(23199, forKey: portKey)
        suite.set(false, forKey: enabledKey)
        suite.setVolatileDomain([
            portKey: "23331",
            enabledKey: "YES",
        ], forName: UserDefaults.argumentDomain)
        defer { suite.setVolatileDomain([:], forName: UserDefaults.argumentDomain) }

        XCTAssertEqual(ImpressSettings.shared.value("imprint.automation.http_port", as: Int.self),
                       Int(SiblingApp.imprint.httpPort))
        XCTAssertTrue(ImpressSettings.shared.value("imprint.automation.http_enabled", as: Bool.self))
        XCTAssertNil(try? String(contentsOf: scratch.appendingPathComponent("settings/app-imprint.json"),
                                 encoding: .utf8))
        XCTAssertEqual(suite.integer(forKey: portKey), 23331)

        suite.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        ImpressSettings.shared._resetForTesting()
        XCTAssertEqual(ImpressSettings.shared.value("imprint.automation.http_port", as: Int.self), 23199)
        XCTAssertFalse(ImpressSettings.shared.value("imprint.automation.http_enabled", as: Bool.self))
        XCTAssertEqual(suite.integer(forKey: portKey), 23199,
                       "the old persistent value must remain for older builds")
    }

    func testExternalSettingWriteNotifiesOpenRegistry() async throws {
        XCTAssertEqual(ImpressSettings.shared.value("imprint.automation.http_port", as: Int.self),
                       Int(SiblingApp.imprint.httpPort))
        let changed = expectation(description: "external settings file reached the open pane/runtime feed")
        let observer = NotificationCenter.default.addObserver(
            forName: ImpressSettings.didChange, object: nil, queue: .main
        ) { _ in changed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        // The Rust file cursor uses millisecond timestamps; establish a
        // distinct tick before simulating the CLI's separate handle.
        try await Task.sleep(for: .milliseconds(2))
        let external = try SharedSettings.open(workspacePath: scratch.path)
        _ = try external.setJson(key: "imprint.automation.http_port", valueJson: "23456")
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(ImpressSettings.shared.value("imprint.automation.http_port", as: Int.self), 23456)
    }
}
