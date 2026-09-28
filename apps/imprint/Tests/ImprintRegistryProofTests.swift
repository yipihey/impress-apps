#if os(macOS)
import AppKit
import Darwin
import Foundation
import ImpressAutomation
import ImpressKeyboard
import ImpressKit
import ImpressLayout
import ImpressRustCore
import ImpressSurface
import PublicationManagerCore
import SwiftUI
import XCTest

@testable import imprint

/// Opt-in R3 hosted proof. It mounts the actual settings pane and observes
/// the same persisted surface row through a second native pane model. It does
/// not assert a physical click or introspect SwiftUI's private @State.
@MainActor
final class ImprintRegistryProofTests: XCTestCase {
    func testRegistryAndMountedAutomationPaneFollowCLI() async throws {
        guard let context = try await proofContext() else { return }

        let chords = KeymapRegistry.shared.entries(forApp: "imprint")
        XCTAssertEqual(chords.count, 60)
        XCTAssertEqual(Set(chords.map(\.target.id)).count, 60)
        XCTAssertEqual(KeymapRegistry.shared.entry(for: "imprint.file.new_typst")?.chord, "⌘N")
        XCTAssertEqual(KeymapRegistry.shared.entry(for: "imprint.edit.build_manuscript")?.chord, "⌥⌘B")
        try await waitUntil("native File and Edit menu installation", seconds: 10) {
            Self.menuItem("New Typst Manuscript") != nil && Self.menuItem("Build Manuscript") != nil
        }
        let newItem = try XCTUnwrap(Self.menuItem("New Typst Manuscript"))
        let buildItem = try XCTUnwrap(Self.menuItem("Build Manuscript"))
        XCTAssertEqual(newItem.keyEquivalent.lowercased(), "n")
        XCTAssertTrue(newItem.keyEquivalentModifierMask.contains(.command))
        XCTAssertEqual(buildItem.keyEquivalent.lowercased(), "b")
        XCTAssertTrue(buildItem.keyEquivalentModifierMask.contains([.command, .option]))

        // First-read D-R5 migration is exercised through the same GUI registry
        // that @ImpressSetting uses. The scratch legacy domain is never removed.
        let suiteName = "com.impress.r3-proof.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        legacy.removePersistentDomain(forName: suiteName)
        legacy.set(73, forKey: "autoSaveInterval")
        let originalStores = ImpressSettings.shared.legacyStores
        ImpressSettings.shared.legacyStores = [legacy]
        ImpressSettings.shared._resetForTesting()
        defer {
            ImpressSettings.shared.legacyStores = originalStores
            legacy.removePersistentDomain(forName: suiteName)
        }
        XCTAssertEqual(ImpressSettings.shared.value("imprint.general.auto_save_interval", as: Int.self), 73)
        XCTAssertEqual(ImpressSettings.shared.record("imprint.general.auto_save_interval")?.source, "stored")
        XCTAssertEqual(legacy.integer(forKey: "autoSaveInterval"), 73)
        let migrated = try await runCLI(context, "get", ["get", "--key",
                                                       "imprint.general.auto_save_interval"])
        XCTAssertEqual(Self.settingValue(migrated) as? Int, 73)

        // This hosted window makes SwiftUI execute SettingsSurfacePane's
        // install/subscribe path; the row and model below are its native
        // display contract, observed independently without test-only hooks.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "R3 owned settings proof"
        window.contentView = NSHostingView(rootView:
            SettingsSurfacePane(section: "imprint.automation", appID: "imprint"))
        window.orderFrontRegardless()
        defer { window.close() }
        let surface = SharedSurface.open(store: context.store, host: "", appId: "imprint")
        var surfaceID: String?
        try await waitUntil("mounted settings surface row", seconds: 20) {
            surfaceID = try surface.list().first {
                $0.tags.contains("settings:imprint.automation")
            }?.id
            return surfaceID != nil
        }
        let id = try XCTUnwrap(surfaceID)
        let model = SurfacePaneModel(surface: surface, surfaceID: id, pane: nil)
        defer { model.stop() }
        model.start()
        try await waitUntil("initial rendered automation field", seconds: 15) {
            Self.fieldValue(model.tree, id: "imprint.automation.log_requests") == .bool(true)
        }
        let initialToken = context.appToken
        let before = try await Self.http(context.statusURL, bearer: initialToken)
        XCTAssertEqual(before.0, 200)

        let changed = try await runCLI(context, "set", ["set", "--key",
                                                       "imprint.automation.log_requests", "--value", "false"])
        XCTAssertEqual(Self.settingValue(changed) as? Bool, false)
        try await waitUntil("CLI value reaches GUI registry", seconds: 10) {
            ImpressSettings.shared.value("imprint.automation.log_requests", as: Bool.self) == false
        }
        try await waitUntil("same mounted surface row and model show CLI value", seconds: 20) {
            guard let row = try? surface.list().first(where: {
                $0.tags.contains("settings:imprint.automation")
            }), row.id == id else { return false }
            return Self.fieldValue(model.tree, id: "imprint.automation.log_requests") == .bool(false)
        }

        // log_requests changes the listener configuration. The app delegate's
        // settings feed must restart the real server, rotating its loopback
        // token, while -httpAutomationPort stays a process-only override.
        var rotatedToken: String?
        try await waitUntil("runtime listener applied CLI configuration", seconds: 20) {
            guard await ImprintHTTPServer.shared.running,
                  let token = try? String(contentsOfFile: context.tokenPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty, token != initialToken else { return false }
            rotatedToken = token
            return (try? await Self.http(context.statusURL, bearer: token))?.0 == 200
        }
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "httpAutomationPort"), Int(context.appPort))
        let got = try await runCLI(context, "get-after-set", ["get", "--key",
                                                           "imprint.automation.log_requests"])
        XCTAssertEqual(Self.settingValue(got) as? Bool, false)

        let logs = try await Self.http(context.logsURL, bearer: try XCTUnwrap(rotatedToken))
        XCTAssertEqual(logs.0, 200)
        try Self.writeJSON([
            "store_path": context.storePath,
            "chord_count": chords.count,
            "menu_new": ["key": newItem.keyEquivalent, "modifiers": newItem.keyEquivalentModifierMask.rawValue],
            "menu_build": ["key": buildItem.keyEquivalent, "modifiers": buildItem.keyEquivalentModifierMask.rawValue],
            "legacy_migration": migrated,
            "surface_id": id,
            "rendered_log_requests": false,
            "cli_set": changed,
            "cli_get": got,
            "listener_rotated_token": rotatedToken != initialToken,
            "app_logs_status": logs.0,
            "app_logs": String(decoding: logs.1, as: UTF8.self),
            "note": "Mounted SettingsSurfacePane and observed its persisted row via a second SurfacePaneModel; no physical click asserted",
        ], to: context.output.appendingPathComponent("proof.json"))
    }

    private func proofContext() async throws -> ProofContext? {
        let env = ProcessInfo.processInfo.environment
        guard env["IMPRESS_R3_PROOF"] == "1" else {
            throw XCTSkip("Set IMPRESS_R3_PROOF=1 for the isolated hosted registry proof")
        }
        guard ImpressRuntime.isUnitTestProcess && ImpressRuntime.isUITestingProcess else {
            XCTFail("R3 requires a --ui-testing XCTest host")
            return nil
        }
        let port = try XCTUnwrap(env["IMPRESS_R3_PROOF_PORT"].flatMap(UInt16.init))
        let device = try XCTUnwrap(env["IMPRESS_DEVICE_ID"])
        let root = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_R3_PROOF_ROOT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let outputBase = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_R3_PROOF_OUTPUT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let posixTmp = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        let safeRoot = (root.path.hasPrefix(tmp.path + "/")
            || root.path.hasPrefix(posixTmp.path + "/"))
            && root.lastPathComponent.hasPrefix("impress-r3-proof-")
            && outputBase.path.hasPrefix(root.path + "/")
            && device.hasPrefix("codex-r3-") && port > 1024
        guard safeRoot else { XCTFail("R3 root, device, or port is not proof-owned"); return nil }
        let bootstrapInput = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_STORE_PATH"]))
        let bootstrap = bootstrapInput.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(bootstrapInput.lastPathComponent)
        let workspace = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_WORKSPACE"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard bootstrap.path.hasPrefix(root.path + "/"),
              bootstrap.deletingLastPathComponent() == workspace,
              env["IMBIB_STORE_PATH"] == env["IMPRESS_STORE_PATH"],
              UserDefaults.standard.integer(forKey: "httpAutomationPort") == Int(port),
              UserDefaults.standard.bool(forKey: "httpAutomationEnabled") else {
            XCTFail("R3 bootstrap paths or launch overrides are not isolated")
            return nil
        }
        for key in ["IMBIB_BACKEND", "IMPRINT_BACKEND", "IMPLORE_BACKEND", "IMPART_BACKEND"] {
            guard env[key] == "off" else { XCTFail("\(key) must be off"); return nil }
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let expected = tmp.appendingPathComponent("impress-unit-tests-\(pid)")
            .appendingPathComponent("workspace")
            .appendingPathComponent("impress.sqlite")
            .standardizedFileURL
        let shared = URL(fileURLWithPath: SharedWorkspace.databasePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard shared == expected,
              !shared.path.localizedCaseInsensitiveContains("Group Containers") else {
            XCTFail("R3 SharedWorkspace is not PID-owned scratch")
            return nil
        }
        let actual = URL(fileURLWithPath: try XCTUnwrap(RustStoreAdapter.shared.databaseLocation))
            .standardizedFileURL.resolvingSymlinksInPath()
        let settingsWorkspace = ImpressSettings.shared.workspaceDirectory
            .standardizedFileURL.resolvingSymlinksInPath()
        guard actual == expected, shared == actual,
              settingsWorkspace == actual.deletingLastPathComponent(),
              !actual.path.localizedCaseInsensitiveContains("Group Containers"),
              let store = RustStoreAdapter.shared.layoutSharedStore() else {
            XCTFail("R3 native store/settings handles are not PID-owned scratch")
            return nil
        }
        let storePath = URL(fileURLWithPath: try store.providerStorePath())
            .standardizedFileURL.resolvingSymlinksInPath()
        guard storePath == actual else { XCTFail("R3 FFI store differs from GUI store"); return nil }
        let tokenPath = LoopbackToken.path(port: port)
        let tokenURL = URL(fileURLWithPath: tokenPath).standardizedFileURL.resolvingSymlinksInPath()
        let tokenRoot = SharedContainer.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard tokenRoot == expected.deletingLastPathComponent().deletingLastPathComponent(),
              tokenURL.path.hasPrefix(tokenRoot.path + "/") else {
            XCTFail("R3 loopback token is outside the PID-owned root")
            return nil
        }
        let cli = try XCTUnwrap(env["IMPRESS_R3_CLI_PATH"])
        guard cli.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: cli) else {
            XCTFail("R3 CLI is not an owned built executable")
            return nil
        }
        let output = outputBase.appendingPathComponent("host-\(pid)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await waitUntil("owned imprint HTTP startup", seconds: 20) {
            await ImprintHTTPServer.shared.running
        }
        var token: String?
        try await waitUntil("owned imprint loopback token", seconds: 10) {
            token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token?.isEmpty == false
        }
        var childEnv = env
        childEnv["IMPRESS_STORE_PATH"] = actual.path
        childEnv["IMBIB_STORE_PATH"] = actual.path
        childEnv["IMPRESS_WORKSPACE"] = actual.deletingLastPathComponent().path
        childEnv["IMPRESS_DEVICE_ID"] = device
        return ProofContext(store: store, storePath: actual.path, output: output,
                            appPort: port, tokenPath: tokenPath, appToken: try XCTUnwrap(token),
                            cliPath: cli, childEnvironment: childEnv)
    }

    private func runCLI(_ context: ProofContext, _ label: String, _ args: [String]) async throws -> [String: Any] {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: context.cliPath)
        child.arguments = ["--store-path", context.storePath] + args
        child.environment = context.childEnvironment
        let stdout = context.output.appendingPathComponent("cli-\(label).json")
        let stderr = context.output.appendingPathComponent("cli-\(label).log")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        child.standardOutput = try FileHandle(forWritingTo: stdout)
        child.standardError = try FileHandle(forWritingTo: stderr)
        defer {
            if child.isRunning { child.terminate() }
            if child.processIdentifier > 0 {
                let deadline = Date().addingTimeInterval(3)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            try? (child.standardOutput as? FileHandle)?.close()
            try? (child.standardError as? FileHandle)?.close()
        }
        try child.run()
        try await waitUntil("owned CLI \(label) exit", seconds: 20) { !child.isRunning }
        child.waitUntilExit()
        guard child.terminationStatus == 0 else {
            XCTFail("CLI \(label) failed (\(child.terminationStatus)); see \(stderr.path)")
            throw ProofError.cli(label)
        }
        return try Self.object(Data(contentsOf: stdout))
    }

    private func waitUntil(_ label: String, seconds: TimeInterval,
                           condition: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out waiting for \(label)")
        throw ProofError.timeout(label)
    }

    private static func settingValue(_ reply: [String: Any]) -> Any? {
        (reply["setting"] as? [String: Any])?["value"]
    }

    private static func menuItem(_ title: String) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == title { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    private static func fieldValue(_ tree: RenderTree?, id: String) -> SurfaceJSONValue? {
        guard let tree else { return nil }
        func find(_ node: RenderNode) -> SurfaceJSONValue? {
            if node.id == id, case .field(_, _, let value) = node.node { return value }
            switch node.node {
            case .column(let children), .row(let children), .grid(_, let children):
                return children.lazy.compactMap(find).first
            case .section(_, _, let body): return find(body)
            case .tabs(let tabs): return tabs.lazy.compactMap { find($0.body) }.first
            default: return nil
            }
        }
        return find(tree.root)
    }

    private static func http(_ url: URL, bearer: String) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func writeJSON(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: path, options: .atomic)
    }
}

private struct ProofContext {
    let store: SharedStore
    let storePath: String
    let output: URL
    let appPort: UInt16
    let tokenPath: String
    let appToken: String
    let cliPath: String
    let childEnvironment: [String: String]

    var statusURL: URL { URL(string: "http://127.0.0.1:\(appPort)/api/status")! }
    var logsURL: URL { URL(string: "http://127.0.0.1:\(appPort)/api/logs?limit=100")! }
}

private enum ProofError: Error { case timeout(String), cli(String) }
#endif
