#if os(macOS)
import Darwin
import Foundation
import ImpressAutomation
import ImpressKit
import ImpressLayout
import ImpressRustCore
import ImpressSurface
import PublicationManagerCore
import XCTest

@testable import impress

/// Opt-in hosted P8 proof. It drives the native pane model, not an AppKit click.
/// Every child and path belongs to this test's isolated app/test process.
final class RuntimeProviderProofTests: XCTestCase {
    @MainActor
    func testNativeProviderReviewAndLiveness() async throws {
        guard let context = try await proofContext() else { return }
        let providerID = "p8-proof-\(UUID().uuidString.lowercased())"
        let verb = "\(providerID)-service_echo"
        let hostToken = context.output.appendingPathComponent("mcp-host.token")
        let providerToken = context.output.appendingPathComponent("provider.token")
        try Data((UUID().uuidString + UUID().uuidString + "\n").utf8)
            .write(to: hostToken, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostToken.path)

        let mcp = try startChild(
            context.mcpPath,
            ["--http", "127.0.0.1:\(context.mcpPort)", "--token-file", hostToken.path,
             "--store-path", context.storePath],
            environment: context.childEnvironment, output: context.output, label: "mcp")
        defer { stopChild(mcp) }
        let hostURL = URL(string: "http://127.0.0.1:\(context.mcpPort)")!
        try await waitUntil("owned MCP host health", seconds: 20) {
            guard mcp.isRunning else { return false }
            return (try? await Self.http(hostURL.appendingPathComponent("healthz")).0) == 200
        }

        let python = try startChild(
            context.pythonPath,
            [context.providerScript, "--host", hostURL.absoluteString,
             "--host-token-file", hostToken.path, "--token-file", providerToken.path,
             "--provider-id", providerID, "--port", "0"],
            environment: context.childEnvironment, output: context.output, label: "python")
        defer { stopChild(python) }

        // The app installs ImpressProviderHost on this exact SharedStore at
        // startup. A second native Rust image restores the MCP registration
        // through its five-second health refresh; no test registry injection.
        var before = [String: Any]()
        try await waitUntil("native provider registration and health", seconds: 40) {
            guard python.isRunning else { return false }
            guard let list = try? Self.native("provider-service_list", [:]) else { return false }
            guard let row = Self.provider(providerID, in: list) else { return false }
            before = row
            return row["available"] as? Bool == true
        }
        XCTAssertEqual(before["trusted"] as? Bool, false)
        XCTAssertEqual(before["verbs"] as? [String], [verb])

        let catalogueBefore = try Self.metadata("capabilities-service_list-verbs", ["search": verb])
        let verbBefore = try XCTUnwrap(Self.catalogueVerb(verb, in: catalogueBefore))
        XCTAssertEqual(verbBefore["source"] as? String, "provider")
        XCTAssertEqual(verbBefore["declared_safety"] as? String, "read_only")
        XCTAssertEqual(verbBefore["effective_safety"] as? String, "external")

        // Keep this exact pane subscribed across liveness loss. The
        // generated catalogue binds its search to state.query (the widget
        // has id "search"), and its table is a live inventory source.
        var catalogueSpec = try Self.metadata("capabilities-service_catalogue-surface", [:])
        var catalogueState = try XCTUnwrap(catalogueSpec["state"] as? [String: Any])
        catalogueState["query"] = verb
        catalogueState["group"] = "\(providerID)-service"
        catalogueSpec["state"] = catalogueState
        let catalogueSurface = SharedSurface.open(store: context.store, host: "", appId: "impress")
        let catalogueID = try await Self.createSurface(catalogueSpec, on: catalogueSurface)
        let cataloguePane = SurfacePaneModel(surface: catalogueSurface, surfaceID: catalogueID, pane: nil)
        defer { cataloguePane.stop() }
        cataloguePane.start()
        var cataloguePaneBefore = [String: Any]()
        try await waitUntil("native catalogue available row", seconds: 20) {
            guard let row = try? Self.catalogueRow(cataloguePane.tree, named: verb),
                  row["available"] as? Bool == true else { return false }
            cataloguePaneBefore = row
            return true
        }
        XCTAssertEqual(cataloguePaneBefore["name"] as? String, verb)

        let agent = try Self.native(
            "provider-service_set-trusted", ["provider_id": providerID, "trusted": true],
            caller: ["kind": "agent", "name": "p8-proof-agent"], requireSuccess: false)
        XCTAssertEqual(agent["ok"] as? Bool, false)
        XCTAssertTrue(["forbidden", "review-pending"].contains(agent["code"] as? String ?? ""), "\(agent)")
        XCTAssertEqual(Self.provider(providerID, in: try Self.native("provider-service_list", [:]))?["trusted"] as? Bool, false)

        let surface = SharedSurface.open(store: context.store, host: "", appId: "impress")
        let trustSpec = try Self.generatedSpec("provider-service_set-trusted")
        var reviewedSpec = trustSpec
        var trustState = try XCTUnwrap(reviewedSpec["state"] as? [String: Any])
        trustState["provider_id"] = providerID
        trustState["trusted"] = true
        reviewedSpec["state"] = trustState
        let trustID = try await Self.createSurface(reviewedSpec, on: surface)
        let trustPane = SurfacePaneModel(surface: surface, surfaceID: trustID, pane: nil)
        defer { trustPane.stop() }
        trustPane.start()
        try await waitUntil("native trust form render", seconds: 10) { trustPane.tree != nil }
        XCTAssertTrue(try Self.containsRun(reviewedSpec))
        trustPane.dispatch(SurfaceEvent(widget: "run", kind: .click))
        try await waitUntil("person surface trust persistence", seconds: 20) {
            guard let list = try? Self.native("provider-service_list", [:]),
                  let state = try? await Self.surfaceState(trustID, on: surface),
                  let result = state["result"] as? [String: Any] else { return false }
            return Self.provider(providerID, in: list)?["trusted"] as? Bool == true
                && result["trusted"] as? Bool == true
        }
        XCTAssertNil(trustPane.effectFailure)
        trustPane.stop()
        let trustedRow = try XCTUnwrap(Self.provider(providerID, in: Self.native("provider-service_list", [:])))

        // The separate CLI image must restore the persisted Person decision;
        // no direct SQLite fixture writes or in-process-only trust assertion.
        let cli = try await runChild(
            context.cliPath, ["--store-path", context.storePath, "echo", "--text", "hello"],
            environment: context.childEnvironment, output: context.output, label: "cli-echo")
        XCTAssertEqual(cli.status, 0, "see \(cli.stderr.path)")
        let cliBody = try Self.object(Data(contentsOf: cli.stdout))
        XCTAssertEqual(cliBody["echo"] as? String, "hello")

        try await waitUntil("metadata host sees persisted Person trust", seconds: 20) {
            guard let list = try? Self.metadata("capabilities-service_list-verbs", ["search": verb]) else { return false }
            return Self.catalogueVerb(verb, in: list)?["effective_safety"] as? String == "read_only"
        }
        let echoSpec = try Self.generatedSpec(verb)
        XCTAssertTrue(try Self.containsRun(echoSpec))
        let echoID = try await Self.createSurface(echoSpec, on: surface)
        let echoPane = SurfacePaneModel(surface: surface, surfaceID: echoID, pane: nil)
        defer { echoPane.stop() }
        echoPane.start()
        try await waitUntil("native provider form render", seconds: 10) { echoPane.tree != nil }
        echoPane.dispatch(SurfaceEvent(widget: "run", kind: .click))
        try await waitUntil("provider result persisted by pane dispatch", seconds: 20) {
            guard let state = try? await Self.surfaceState(echoID, on: surface),
                  let result = state["result"] as? [String: Any] else { return false }
            return result["echo"] as? String == "hello"
        }
        XCTAssertNil(echoPane.effectFailure)
        echoPane.stop()

        stopChild(python)
        var unavailable = [String: Any]()
        try await waitUntil("provider health cycle marks unavailable", seconds: 25) {
            guard let list = try? Self.native("provider-service_list", [:]),
                  let row = Self.provider(providerID, in: list) else { return false }
            unavailable = row
            return row["available"] as? Bool == false
        }
        XCTAssertEqual(unavailable["trusted"] as? Bool, true)
        XCTAssertEqual(unavailable["verbs"] as? [String], [verb])
        var cataloguePaneAfter = [String: Any]()
        try await waitUntil("same native catalogue pane shows unavailable row", seconds: 120) {
            guard let row = try? Self.catalogueRow(cataloguePane.tree, named: verb),
                  row["available"] as? Bool == false else { return false }
            cataloguePaneAfter = row
            return true
        }
        XCTAssertEqual(cataloguePaneAfter["name"] as? String, verb)
        let offlineSpec = try Self.generatedSpec(verb)
        XCTAssertFalse(try Self.containsRun(offlineSpec))
        XCTAssertTrue(try Self.jsonString(offlineSpec).contains("provider-unavailable"))

        // A live source still names the retained provider verb, so rendering
        // after its process exits must refuse with the host-unavailable code.
        let sourceSpec: [String: Any] = [
            "surface": "1.0", "name": "P8 offline source \(providerID)", "state": [:],
            "sources": ["echo": ["verb": verb, "args": ["text": "hello"]]],
            "root": ["id": "source", "text": "{{source.echo}}"],
        ]
        let sourceID = try await Self.createSurface(sourceSpec, on: surface)
        let sourceReply = try Self.object(Data(try await surface.render(surfaceId: sourceID, pane: nil).utf8))
        let errors = try XCTUnwrap(sourceReply["source_errors"] as? [[String: Any]], "\(sourceReply)")
        XCTAssertEqual(errors.first?["name"] as? String, "echo")
        XCTAssertFalse((errors.first?["message"] as? String ?? "").isEmpty)
        let unavailableCall = try Self.native(verb, ["text": "hello"], requireSuccess: false)
        XCTAssertEqual(unavailableCall["code"] as? String, "host-unavailable")

        let appLogs = try await Self.http(
            URL(string: "http://127.0.0.1:\(context.appPort)/api/logs?limit=100")!,
            bearer: context.appToken)
        XCTAssertEqual(appLogs.0, 200)
        let evidence: [String: Any] = [
            "provider_id": providerID, "verb": verb, "store_path": context.storePath,
            "before": before, "agent_refusal": agent, "catalogue_before": verbBefore,
            "catalogue_pane_before": cataloguePaneBefore,
            "catalogue_pane_after": cataloguePaneAfter,
            "trust_after": trustedRow,
            "cli_echo": cliBody, "provider_state": try await Self.surfaceState(echoID, on: surface),
            "unavailable": unavailable, "offline_spec": offlineSpec,
            "source_render": sourceReply, "unavailable_call": unavailableCall,
            "app_logs_status": appLogs.0,
            "app_logs": String(data: appLogs.1, encoding: .utf8) ?? "",
            "note": "SurfacePaneModel dispatch; no physical UI click asserted",
        ]
        try Self.writeJSON(evidence, to: context.output.appendingPathComponent("proof.json"))
    }

    @MainActor
    private func proofContext() async throws -> Context? {
        let env = ProcessInfo.processInfo.environment
        guard env["IMPRESS_P8_PROOF"] == "1" else {
            throw XCTSkip("Set IMPRESS_P8_PROOF=1 for the isolated hosted provider proof")
        }
        let uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        XCTAssertTrue(uiTesting)
        guard uiTesting else { return nil }
        let appPort = try XCTUnwrap(env["IMPRESS_P8_PROOF_PORT"].flatMap(UInt16.init))
        let mcpPort = try XCTUnwrap(env["IMPRESS_P8_MCP_PORT"].flatMap(UInt16.init))
        XCTAssertEqual(appPort, ImpressHTTPServer.configuredPort)
        XCTAssertNotEqual(appPort, mcpPort)
        guard appPort == ImpressHTTPServer.configuredPort, appPort != mcpPort,
              appPort > 1024, mcpPort > 1024 else { return nil }
        let device = try XCTUnwrap(env["IMPRESS_DEVICE_ID"])
        XCTAssertTrue(device.hasPrefix("codex-p8-"))
        guard device.hasPrefix("codex-p8-") else { return nil }
        let root = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_P8_PROOF_ROOT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let outputBase = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_P8_PROOF_OUTPUT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let posixTmp = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        let owned = (root.path.hasPrefix(tmp.path + "/") || root.path.hasPrefix(posixTmp.path + "/"))
            && root.lastPathComponent.hasPrefix("impress-p8-")
            && outputBase.path.hasPrefix(root.path + "/")
        XCTAssertTrue(owned, "P8 paths must be under the owned /tmp proof root")
        guard owned else { return nil }
        let bootstrap = try XCTUnwrap(env["IMPRESS_STORE_PATH"])
        let bootstrapWorkspace = try XCTUnwrap(env["IMPRESS_WORKSPACE"])
        // The bootstrap file need not exist: XCTest uses the PID-owned
        // database instead. Resolve its existing parent before appending the
        // filename, so Foundation treats /tmp and /private/tmp consistently.
        let bootstrapInput = URL(fileURLWithPath: bootstrap)
        let bootstrapParent = bootstrapInput.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let bootstrapURL = bootstrapParent.appendingPathComponent(bootstrapInput.lastPathComponent)
        let bootstrapWorkspaceURL = URL(fileURLWithPath: bootstrapWorkspace, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertTrue(bootstrapURL.path.hasPrefix(root.path + "/"))
        XCTAssertEqual(env["IMBIB_STORE_PATH"], bootstrap)
        XCTAssertEqual(bootstrapURL.deletingLastPathComponent().path, bootstrapWorkspaceURL.path)
        guard bootstrapURL.path.hasPrefix(root.path + "/"), env["IMBIB_STORE_PATH"] == bootstrap,
              bootstrapURL.deletingLastPathComponent().path == bootstrapWorkspaceURL.path else { return nil }

        let pid = ProcessInfo.processInfo.processIdentifier
        let actual = try XCTUnwrap(RustStoreAdapter.shared.databaseLocation)
        let actualURL = URL(fileURLWithPath: actual).standardizedFileURL.resolvingSymlinksInPath()
        let expected = ["impress-unit-tests-\(pid)", "impress-ui-tests-\(pid)"].map {
            tmp.appendingPathComponent($0).appendingPathComponent("workspace/impress.sqlite").path
        }
        XCTAssertTrue(expected.contains(actualURL.path))
        let sharedDB = URL(fileURLWithPath: SharedWorkspace.databasePath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(actualURL.path, sharedDB)
        XCTAssertFalse(actualURL.path.localizedCaseInsensitiveContains("Group Containers"))
        guard expected.contains(actualURL.path), actualURL.path == sharedDB,
              !actualURL.path.localizedCaseInsensitiveContains("Group Containers") else { return nil }
        let store = try XCTUnwrap(RustStoreAdapter.shared.layoutSharedStore())
        let providerDB = URL(fileURLWithPath: try store.providerStorePath())
            .standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(providerDB, actualURL.path)
        guard providerDB == actualURL.path else { return nil }
        let output = outputBase.appendingPathComponent("host-\(pid)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        func executable(_ key: String) throws -> String {
            let path = try XCTUnwrap(env[key])
            XCTAssertTrue(path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path))
            return path
        }
        let mcpPath = try executable("IMPRESS_P8_MCP_PATH")
        let cliPath = try executable("IMPRESS_P8_CLI_PATH")
        let pythonPath = env["IMPRESS_P8_PYTHON"] ?? "/usr/bin/python3"
        XCTAssertTrue(pythonPath.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: pythonPath))
        let providerScript = try XCTUnwrap(env["IMPRESS_P8_PROVIDER_SCRIPT"])
        XCTAssertTrue(providerScript.hasPrefix("/") && FileManager.default.fileExists(atPath: providerScript))
        guard providerScript.hasPrefix("/") && FileManager.default.fileExists(atPath: providerScript) else { return nil }
        for key in ["IMBIB_BACKEND", "IMPRINT_BACKEND", "IMPLORE_BACKEND", "IMPART_BACKEND"] {
            XCTAssertEqual(env[key], "off", "\(key) must be off for this proof")
            guard env[key] == "off" else { return nil }
        }
        var childEnv = env
        childEnv["IMPRESS_STORE_PATH"] = actualURL.path
        childEnv["IMBIB_STORE_PATH"] = actualURL.path
        childEnv["IMPRESS_WORKSPACE"] = actualURL.deletingLastPathComponent().path
        childEnv["IMPRESS_DEVICE_ID"] = device
        childEnv["IMPRINT_COMPILE_CACHE_DIR"] = output.appendingPathComponent("compile-cache").path
        for key in ["IMBIB_BACKEND", "IMPRINT_BACKEND", "IMPLORE_BACKEND", "IMPART_BACKEND"] {
            childEnv[key] = "off"
        }
        try FileManager.default.createDirectory(
            atPath: childEnv["IMPRINT_COMPILE_CACHE_DIR"]!, withIntermediateDirectories: true)
        try await waitUntil("owned app HTTP startup", seconds: 10) { await ImpressHTTPServer.shared.running }
        let tokenPath = LoopbackToken.path(port: appPort)
        let canonicalTokenPath = URL(fileURLWithPath: tokenPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let pidRoot = actualURL.deletingLastPathComponent().deletingLastPathComponent().path
        XCTAssertTrue(canonicalTokenPath.hasPrefix(pidRoot + "/"))
        guard canonicalTokenPath.hasPrefix(pidRoot + "/") else { return nil }
        var appToken: String?
        try await waitUntil("owned app HTTP token", seconds: 10) {
            appToken = try? String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return appToken?.isEmpty == false
        }
        return Context(store: store, storePath: actualURL.path, output: output,
                       appPort: appPort, mcpPort: mcpPort, mcpPath: mcpPath,
                       cliPath: cliPath, pythonPath: pythonPath,
                       providerScript: providerScript, appToken: try XCTUnwrap(appToken),
                       childEnvironment: childEnv)
    }

    private static func native(
        _ name: String, _ args: [String: Any],
        caller: [String: Any] = ["kind": "person"], requireSuccess: Bool = true
    ) throws -> [String: Any] {
        let result = dispatchVerb(name: name, argsJson: try jsonString(args), callerJson: try jsonString(caller))
        let body = try object(Data(result.bodyJson.utf8))
        if requireSuccess {
            XCTAssertEqual(result.status, 200, "\(name): \(result.bodyJson)")
            XCTAssertNotEqual(body["ok"] as? Bool, false, "\(name): \(result.bodyJson)")
        }
        return body
    }

    // capabilities-service is deliberately outside the store's kit image.
    // Native surface sources reach it through this same full-inventory host.
    private static func metadata(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        try object(Data(ImpelToolsVerbHost().callVerb(
            name: name, argsJson: jsonString(args), contextJson: "").utf8))
    }

    private static func provider(_ id: String, in list: [String: Any]) -> [String: Any]? {
        (list["providers"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    private static func catalogueVerb(_ name: String, in list: [String: Any]) -> [String: Any]? {
        (list["verbs"] as? [[String: Any]])?.first { $0["name"] as? String == name }
    }

    private static func catalogueRow(_ tree: RenderTree?, named name: String) throws -> [String: Any]? {
        guard let tree else { return nil }
        let encoded = try JSONEncoder().encode(tree)
        let document = try JSONSerialization.jsonObject(with: encoded)
        func find(_ value: Any) -> [String: Any]? {
            if let row = value as? [String: Any] {
                if row["name"] as? String == name, row["available"] is Bool { return row }
                for child in row.values {
                    if let found = find(child) { return found }
                }
            } else if let rows = value as? [Any] {
                for child in rows {
                    if let found = find(child) { return found }
                }
            }
            return nil
        }
        return find(document)
    }

    private static func generatedSpec(_ verb: String) throws -> [String: Any] {
        let reply = try metadata("capabilities-service_verb-surface", ["verb": verb])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return try XCTUnwrap(reply["spec"] as? [String: Any])
    }

    private static func containsRun(_ spec: [String: Any]) throws -> Bool {
        try jsonString(spec).contains("\"id\":\"run\"")
    }

    private static func createSurface(_ spec: [String: Any], on surface: SharedSurface) async throws -> String {
        let reply = await surface.surfaceHttp(method: "POST", path: "/api/surface", body: try jsonString(spec))
        XCTAssertEqual(reply.status, 200, reply.body)
        let body = try object(Data(reply.body.utf8))
        XCTAssertEqual(body["ok"] as? Bool, true, reply.body)
        return try XCTUnwrap(body["id"] as? String)
    }

    private static func surfaceState(_ id: String, on surface: SharedSurface) async throws -> [String: Any] {
        let reply = await surface.surfaceHttp(method: "GET", path: "/api/surface/\(id)/state", body: "")
        XCTAssertEqual(reply.status, 200, reply.body)
        let body = try object(Data(reply.body.utf8))
        return try XCTUnwrap(body["state"] as? [String: Any])
    }

    private static func http(_ url: URL, bearer: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @MainActor
    private func waitUntil(
        _ description: String, seconds: TimeInterval,
        condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out waiting for \(description)")
        throw ProofError.timeout(description)
    }

    private func startChild(
        _ executable: String, _ arguments: [String], environment: [String: String],
        output: URL, label: String
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let out = output.appendingPathComponent("\(label).out")
        let err = output.appendingPathComponent("\(label).log")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        do {
            try process.run()
        } catch {
            try? (process.standardOutput as? FileHandle)?.close()
            try? (process.standardError as? FileHandle)?.close()
            throw error
        }
        return process
    }

    private func runChild(
        _ executable: String, _ arguments: [String], environment: [String: String],
        output: URL, label: String
    ) async throws -> ChildResult {
        let process = try startChild(executable, arguments, environment: environment, output: output, label: label)
        defer { stopChild(process) }
        try await waitUntil("\(label) exit", seconds: 15) { !process.isRunning }
        process.waitUntilExit()
        return ChildResult(status: process.terminationStatus,
                           stdout: output.appendingPathComponent("\(label).out"),
                           stderr: output.appendingPathComponent("\(label).log"))
    }

    private func stopChild(_ process: Process) {
        if process.processIdentifier > 0 {
            if process.isRunning { process.terminate() }
            // Reap only this Process child; if its own shutdown sticks, bound it.
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? (process.standardOutput as? FileHandle)?.close()
        try? (process.standardError as? FileHandle)?.close()
    }

    private static func jsonString(_ value: Any) throws -> String {
        try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func writeJSON(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: path, options: .atomic)
    }
}

private struct Context {
    let store: SharedStore
    let storePath: String
    let output: URL
    let appPort: UInt16
    let mcpPort: UInt16
    let mcpPath: String
    let cliPath: String
    let pythonPath: String
    let providerScript: String
    let appToken: String
    let childEnvironment: [String: String]
}

private struct ChildResult {
    let status: Int32
    let stdout: URL
    let stderr: URL
}

private enum ProofError: Error { case timeout(String) }
#endif
