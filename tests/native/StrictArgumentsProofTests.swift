#if os(macOS)
import Foundation
import ImpressAutomation
import ImpressKit
import PublicationManagerCore
import XCTest

/// One hosted Tier B proof compiled into each app. Opt-in because it needs
/// the matching CLI, an owned port, and an explicitly isolated test launch.
final class StrictArgumentsProofTests: XCTestCase {
    @MainActor
    func testStrictDefaultThroughNativeHTTP() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["IMPRESS_G5_PROOF"] == "1" else {
            throw XCTSkip("Run scripts/prove-strict-args.py with isolated native builds")
        }
        let app = try XCTUnwrap(env["IMPRESS_G5_APP"])
        let port = try XCTUnwrap(env["IMPRESS_G5_PORT"].flatMap(UInt16.init))
        let cliPath = try XCTUnwrap(env["IMPRESS_G5_CLI"])
        let output = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_G5_OUTPUT"]), isDirectory: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let root = SharedContainer.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let expectedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-unit-tests-\(pid)")
            .standardizedFileURL.resolvingSymlinksInPath()
        let db = SharedWorkspace.databaseURL.standardizedFileURL.resolvingSymlinksInPath()
        let tokenPath = LoopbackToken.path(port: port)
        let proofRoot = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_G5_ROOT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()

        // Fail before requests/subprocesses unless both native handles and
        // the bearer file belong to this XCTest host, never the real suite.
        try require(ImpressRuntime.isUnitTestProcess && ImpressRuntime.isUITestingProcess, "test launch flags")
        try require(Bundle.main.bundleIdentifier == "com.impress.g5proof.\(app)", "distinct bundle")
        try require(root == expectedRoot, "PID-owned container")
        try require(db == root.appendingPathComponent("workspace/impress.sqlite"), "PID-owned store")
        try require(RustStoreAdapter.shared.databaseLocation == SharedWorkspace.databasePath, "native store agrees")
        try require(tokenPath.hasPrefix(root.path + "/"), "PID-owned bearer")
        try require(UserDefaults.standard.integer(forKey: "httpAutomationPort") == Int(port), "owned HTTP port")
        try require(env["IMPRESS_DEVICE_ID"]?.hasPrefix("codex-g5-") == true, "owned device")
        try require(proofRoot.path.hasPrefix(temporaryRoot.path + "/impress-g5-proof-"), "owned proof root")
        try require(output.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(proofRoot.path + "/"), "owned output")
        try require(cliPath.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: cliPath), "matching CLI")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var token: String?
        for _ in 0..<100 {
            if let value = try? String(contentsOfFile: tokenPath, encoding: .utf8),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = value.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let bearer = try XCTUnwrap(token, "The isolated HTTP server did not publish a bearer")
        let base = "http://127.0.0.1:\(port)"
        let verb = "surface-demo-service_series"
        let valid: [String: Any] = ["freq": 1.5, "n": 4]
        let invalid: [String: Any] = ["freq": 1.5, "n": 4, "g5_extra": true]
        let positive = try await request(base + "/api/verb/" + verb, body: valid, bearer: bearer)
        XCTAssertEqual(positive.status, 200)
        XCTAssertEqual((positive.body["x"] as? [Any])?.count, 4)
        XCTAssertEqual(positive.body["x"] as? [Double], [0.0, 0.25, 0.5, 0.75])
        XCTAssertEqual((positive.body["values"] as? [Any])?.count, 4)
        XCTAssertNil(positive.body["error"])
        let refused = try await request(base + "/api/verb/" + verb, body: invalid, bearer: bearer)
        XCTAssertEqual(refused.status, 400)
        XCTAssertEqual(refused.body["ok"] as? Bool, false)
        XCTAssertEqual(refused.body["code"] as? String, "invalid-argument")
        XCTAssertTrue((refused.body["message"] as? String)?.contains("g5_extra") == true)

        var childEnv = env
        childEnv["IMPRESS_STORE_PATH"] = db.path
        childEnv["IMBIB_STORE_PATH"] = db.path
        childEnv["IMPRESS_WORKSPACE"] = db.deletingLastPathComponent().path
        childEnv["IMPRESS_APP_TOKEN"] = bearer
        childEnv["IMPRESS_LAYOUT_SELFTEST_BASE_URL"] = base
        childEnv["IMPRESS_SURFACE_SELFTEST_BASE_URL"] = base
        let cli = StrictProofCLI(executable: cliPath, environment: childEnv, output: output, storePath: db.path)
        let scenarioID = "strict.\(app).\(UUID().uuidString.lowercased())"
        let spec: [String: Any] = [
            "wire_version": 1, "id": scenarioID, "tier": "b",
            "description": "Declared arguments work; unknown arguments are refused in \(app).",
            "requires": ["app": app],
            "steps": [
                ["call": verb, "args": valid, "expect": ["status": 200, "fields": [
                    // Foundation writes integral Doubles as JSON integers;
                    // these fractions retain their numeric representation.
                    ["path": "$.x.1", "equals": 0.25],
                    ["path": "$.x.3", "equals": 0.75],
                ]]],
                ["call": verb, "args": invalid, "expect": ["status": 400, "ok": false,
                    "code": "invalid-argument", "fields": [["path": "$.message", "contains": "g5_extra"]]]],
            ],
        ]
        let specJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: spec), encoding: .utf8))
        let created = try await cli.call("create", ["scenario-create", "--spec", specJSON])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let report = try await cli.call("scenario", ["scenario-run", "--scenario-id", scenarioID,
                                                      "--tier", "b", "--base-url", base])
        try assertPassed(report)

        // The shared surface catalogue is reachable in every shell. The
        // layout-tree catalogue applies to chassis shells; imbib still owns
        // its separate pre-chassis pane layout (its briefing documents why).
        let surface = try await cli.call("surface", ["surface-selftest-service_run-selftest", "--tier", "b"])
        try assertPassed(surface)
        var layout: [String: Any] = [:]
        if app != "imbib" {
            layout = try await cli.call("layout", ["layout-selftest-service_run-selftest", "--tier", "b"])
            try assertPassed(layout)
        }
        let logs = try await request(base + "/api/logs?limit=200", body: nil, bearer: bearer)
        XCTAssertEqual(logs.status, 200)
        try JSONSerialization.data(withJSONObject: [
            "app": app, "pid": pid, "store": db.path, "port": port,
            "positive": positive.body, "refused": refused.body, "scenario": report,
            "surface": surface, "layout": layout, "logs": logs.body,
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("proof.json"))
    }

    private func require(_ condition: Bool, _ message: String) throws {
        XCTAssertTrue(condition, message)
        if !condition { throw NSError(domain: "StrictArgumentsProof", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private func assertPassed(_ report: [String: Any]) throws {
        try require(report["ok"] as? Bool == true, "\(report)")
        XCTAssertEqual(report["failed"] as? Int, 0)
        XCTAssertEqual(report["skipped"] as? Int, 0)
        XCTAssertGreaterThan(report["passed"] as? Int ?? 0, 0)
    }

    private func request(_ url: String, body: [String: Any]?, bearer: String) async throws -> (status: Int, body: [String: Any]) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
        request.timeoutInterval = 30
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode,
                try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }
}

private struct StrictProofCLI {
    let executable: String
    let environment: [String: String]
    let output: URL
    let storePath: String

    func call(_ name: String, _ arguments: [String]) async throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--store-path", storePath] + arguments
        process.environment = environment
        let stdout = output.appendingPathComponent("\(name).json")
        let stderr = output.appendingPathComponent("\(name).log")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        process.standardOutput = out
        process.standardError = err
        defer { try? out.close(); try? err.close() }
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stdout)) as? [String: Any])
        XCTAssertEqual(status, 0, "\(name): \(result); see \(stderr.path)")
        return result
    }
}
#endif
