#if os(macOS)
import Foundation
import ImpressAutomation
import ImpressKit
import ImpressRustCore
import PublicationManagerCore
import XCTest

@testable import impress

/// Opt-in, hosted proof of native person calls -> audit -> editable scenario -> Tier B replay.
/// The test host and every subprocess must use the same per-process scratch file.
final class ScenarioRecordingProofTests: XCTestCase {
    @MainActor
    func testNativeTriageTraceRecordsAndReplays() async throws {
        guard let context = try await proofContext() else { return }
        let store = context.store
        let cli = context.cli
        let output = context.output
        let port = context.port

        let runID = UUID().uuidString.lowercased()
        let traceID = "s3-proof-\(runID)"
        let papers = (0..<3).map { _ in UUID().uuidString.lowercased() }
        let tag = "s3-proof/\(runID)"
        for (index, id) in papers.enumerated() {
            let payload = try Self.jsonString(["title": "S3 proof paper \(index + 1) \(runID)"])
            try store.upsertItem(id: id, schemaRef: "imbib/bibliography-entry", payloadJson: payload)
        }

        // dispatchVerb is the app's trusted native-person entrypoint. Its
        // caller JSON is constructed here, never accepted from an HTTP body.
        let caller = try Self.jsonString(["kind": "person", "trace_id": traceID])
        let actions: [(String, [String: Any])] = [
            ("triage-service_set-starred", ["id": papers[0], "starred": true]),
            ("triage-service_add-tag", ["id": papers[0], "tag": tag]),
            ("triage-service_set-flag", ["id": papers[1], "color": "blue"]),
            ("triage-service_set-starred", ["id": papers[2], "starred": true]),
        ]
        var nativeResults = [[String: Any]]()
        for (name, args) in actions {
            let result = dispatchVerb(name: name, argsJson: try Self.jsonString(args), callerJson: caller)
            let body = try Self.object(Data(result.bodyJson.utf8))
            XCTAssertEqual(result.status, 200, "\(name): \(result.bodyJson)")
            XCTAssertEqual(body["ok"] as? Bool, true, "\(name): \(result.bodyJson)")
            XCTAssertEqual(body["id"] as? String, args["id"] as? String)
            nativeResults.append(body)
            try await Task.sleep(for: .milliseconds(5))
        }

        var history = [String: Any]()
        for _ in 0..<40 {
            history = try await cli.call("calls", ["calls", "--trace-id", traceID, "--limit", "20"])
            if (history["calls"] as? [[String: Any]])?.count == 4 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let calls = try XCTUnwrap(history["calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.compactMap { $0["verb"] as? String }.count, 4)
        XCTAssertEqual(Set(calls.compactMap { $0["verb"] as? String }), Set(actions.map { $0.0 }))
        XCTAssertTrue(calls.allSatisfy { ($0["caller"] as? [String: Any])?["kind"] as? String == "human" })

        let recorded = try await cli.call("record", ["scenario-record", "--trace-id", traceID])
        XCTAssertEqual(recorded["ok"] as? Bool, true)
        XCTAssertEqual(recorded["selected"] as? Int, 4)
        XCTAssertEqual((recorded["skipped"] as? [Any])?.count, 0)
        let recordedID = try XCTUnwrap(recorded["scenario_id"] as? String)
        let recordedSpec = try XCTUnwrap(recorded["spec"] as? [String: Any])
        let recordedSteps = try XCTUnwrap(recordedSpec["steps"] as? [[String: Any]])
        XCTAssertEqual(recordedSteps.count, 4)
        XCTAssertTrue(recordedSteps.allSatisfy { $0["as"] as? String == "person" })
        let firstCapture = try XCTUnwrap(recordedSteps[0]["capture"] as? [String: String])
        XCTAssertTrue(firstCapture.values.contains("$.id"))
        let secondArgs = try XCTUnwrap(recordedSteps[1]["args"] as? [String: Any])
        XCTAssertTrue((secondArgs["id"] as? String)?.hasPrefix("{{state.") == true)

        let fetched = try await cli.call("get-recorded", ["scenario-get", "--id", recordedID])
        XCTAssertEqual(fetched["ok"] as? Bool, true)
        XCTAssertEqual(try Self.canonicalJSON(fetched["spec"]), try Self.canonicalJSON(recordedSpec))

        // Edit the returned document once: a new stable ID and assertions
        // about each result's echoed item ID. The recorded document stays
        // untouched and remains inspectable through scenario-get.
        var editedSpec = recordedSpec
        let editedID = "s3.proof.\(runID)"
        editedSpec["id"] = editedID
        var editedSteps = recordedSteps
        for index in editedSteps.indices {
            var expect = editedSteps[index]["expect"] as? [String: Any] ?? [:]
            let id = try XCTUnwrap(actions[index].1["id"] as? String)
            expect["fields"] = [["path": "$.id", "equals": id]]
            editedSteps[index]["expect"] = expect
        }
        editedSpec["steps"] = editedSteps
        let created = try await cli.call("create", ["scenario-create", "--spec", try Self.jsonString(editedSpec)])
        XCTAssertEqual(created["ok"] as? Bool, true)
        XCTAssertEqual(created["scenario_id"] as? String, editedID)

        // Reset outside the selected trace so passing the replay proves a
        // mutation, not merely the first run's state surviving.
        try store.setStarred(id: papers[0], isStarred: false)
        try store.removeTag(id: papers[0], tag: tag)
        try store.setFlag(id: papers[1], color: nil, style: nil, length: nil)
        try store.setStarred(id: papers[2], isStarred: false)
        let before = try papers.map { try XCTUnwrap(store.getItem(id: $0)) }
        XCTAssertFalse(before[0].isStarred)
        XCTAssertFalse(before[0].tags.contains(tag))
        XCTAssertNil(before[1].flagColor)
        XCTAssertFalse(before[2].isStarred)

        let report = try await cli.call("run", [
            "scenario-run", "--scenario-id", editedID, "--tier", "b",
            "--base-url", "http://127.0.0.1:\(port)",
        ])
        XCTAssertEqual(report["ok"] as? Bool, true)
        XCTAssertEqual(report["total"] as? Int, 1)
        XCTAssertEqual(report["passed"] as? Int, 1)
        XCTAssertEqual(report["failed"] as? Int, 0)
        XCTAssertEqual(report["skipped"] as? Int, 0)
        let results = try XCTUnwrap(report["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["pass"] as? Bool, true)

        let after = try papers.map { try XCTUnwrap(store.getItem(id: $0)) }
        XCTAssertTrue(after[0].isStarred)
        XCTAssertTrue(after[0].tags.contains(tag))
        XCTAssertEqual(after[1].flagColor, "blue")
        XCTAssertTrue(after[2].isStarred)

        let logsURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/logs?limit=200&category=verb"))
        let (logData, logResponse) = try await URLSession.shared.data(from: logsURL)
        XCTAssertEqual((logResponse as? HTTPURLResponse)?.statusCode, 200)
        try logData.write(to: output.appendingPathComponent("app-verb-logs-\(runID).json"), options: .atomic)

        var replayCalls = [String: Any]()
        for _ in 0..<40 {
            replayCalls = try await cli.call("replay-calls", ["calls", "--verb", "triage-service_set-starred", "--limit", "20"])
            if (replayCalls["calls"] as? [[String: Any]])?.count ?? 0 >= 4 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue((replayCalls["calls"] as? [[String: Any]])?.count ?? 0 >= 4)
        try Self.writeJSON(["trace_id": traceID, "papers": papers, "native_results": nativeResults,
                            "history": history, "recorded": recorded, "get": fetched,
                            "created": created, "report": report, "replay_calls": replayCalls],
                           to: output.appendingPathComponent("s3-record-proof-\(runID).json"))
    }

    /// `SurfacePaneModel.dispatch` calls this same native method with actor
    /// "human". This drives its event path directly; it does not synthesize a
    /// SwiftUI click or claim that the ordinary publication-list menu uses it.
    @MainActor
    func testNativeSurfaceTriageEventsRecordAndReplay() async throws {
        guard let context = try await proofContext() else { return }
        let store = context.store
        let cli = context.cli
        let runID = UUID().uuidString.lowercased()
        let papers = (0..<3).map { _ in UUID().uuidString.lowercased() }
        let tag = "s3-surface/\(runID)"
        for (index, id) in papers.enumerated() {
            let payload = try Self.jsonString(["title": "S3 surface paper \(index + 1) \(runID)"])
            try store.upsertItem(id: id, schemaRef: "imbib/bibliography-entry", payloadJson: payload)
        }

        let actions: [(widget: String, verb: String, args: [String: Any])] = [
            ("star-paper", "triage-service_set-starred", ["id": papers[0], "starred": true]),
            ("flag-paper", "triage-service_set-flag", ["id": papers[1], "color": "blue"]),
            ("tag-paper", "triage-service_add-tag", ["id": papers[2], "tag": tag]),
        ]
        let buttons: [[String: Any]] = actions.map { action in
            ["id": action.widget,
             "button": ["label": action.widget,
                        "on_click": [["call": ["verb": action.verb, "args": action.args]]]]]
        }
        let spec: [String: Any] = [
            "surface": "1.0", "name": "S3 native surface proof \(runID)",
            "state": [:], "root": ["column": buttons],
        ]
        let surface = SharedSurface.open(store: store, host: "", appId: "impress")
        let creation = await surface.surfaceHttp(
            method: "POST", path: "/api/surface", body: try Self.jsonString(spec))
        XCTAssertEqual(creation.status, 200, creation.body)
        let createdSurface = try Self.object(Data(creation.body.utf8))
        XCTAssertEqual(createdSurface["ok"] as? Bool, true, creation.body)
        let surfaceID = try XCTUnwrap(createdSurface["id"] as? String)
        let rendered = try Self.object(Data(try await surface.render(surfaceId: surfaceID, pane: nil).utf8))
        XCTAssertEqual(rendered["ok"] as? Bool, true)

        let since = Self.timestamp(Date().addingTimeInterval(-1))
        var nativeReplies = [[String: Any]]()
        for action in actions {
            let event = try Self.jsonString(["widget": action.widget, "kind": "click", "value": NSNull()])
            let replyJSON = try await surface.dispatch(
                surfaceId: surfaceID, pane: nil, eventJson: event, actor: "human")
            let reply = try Self.object(Data(replyJSON.utf8))
            XCTAssertEqual(reply["ok"] as? Bool, true, replyJSON)
            XCTAssertEqual(reply["effects_failed"] as? Int, 0, replyJSON)
            nativeReplies.append(reply)
        }
        let until = Self.timestamp(Date().addingTimeInterval(1))
        let selection = ["--since", since, "--until", until, "--as", "person"]
        var history = [String: Any]()
        for _ in 0..<40 {
            history = try await cli.call("surface-history", [
                "calls", "--since", since, "--until", until, "--caller", "human", "--limit", "20",
            ])
            if (history["calls"] as? [[String: Any]])?.count == 6 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let calls = try XCTUnwrap(history["calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 6, "three surface parents and three triage children")
        XCTAssertTrue(calls.allSatisfy {
            ($0["caller"] as? [String: Any])?["kind"] as? String == "human"
        })
        let parents = calls.filter { $0["verb"] as? String == "impress-surface-service_surface-dispatch" }
        let children = calls.filter { $0["verb"] as? String != "impress-surface-service_surface-dispatch" }
        XCTAssertEqual(parents.count, 3)
        XCTAssertEqual(Set(children.compactMap { $0["verb"] as? String }), Set(actions.map { $0.verb }))
        XCTAssertEqual(children.count, 3)
        let parentIDs = Set(parents.compactMap { $0["call_id"] as? String })
        XCTAssertEqual(parentIDs.count, 3)
        XCTAssertTrue(children.allSatisfy {
            guard let parent = $0["parent_call"] as? String else { return false }
            return parentIDs.contains(parent)
        }, "every triage call must be nested under a native surface dispatch")
        for id in parentIDs {
            XCTAssertEqual(children.filter { $0["parent_call"] as? String == id }.count, 1)
        }

        let recorded = try await cli.call("surface-record", ["scenario-record"] + selection)
        XCTAssertEqual(recorded["ok"] as? Bool, true, "\(recorded)")
        XCTAssertEqual(recorded["selected"] as? Int, 6)
        let skipped = try XCTUnwrap(recorded["skipped"] as? [[String: Any]])
        XCTAssertEqual(skipped.count, 3, "each child is replayed by its retained surface parent")
        let recordedID = try XCTUnwrap(recorded["scenario_id"] as? String)
        let recordedSpec = try XCTUnwrap(recorded["spec"] as? [String: Any])
        let recordedSteps = try XCTUnwrap(recordedSpec["steps"] as? [[String: Any]])
        XCTAssertEqual(recordedSteps.count, 3)
        XCTAssertTrue(recordedSteps.allSatisfy {
            $0["call"] as? String == "impress-surface-service_surface-dispatch"
                && $0["as"] as? String == "person"
        })
        let fetched = try await cli.call("surface-get", ["scenario-get", "--id", recordedID])
        XCTAssertEqual(try Self.canonicalJSON(fetched["spec"]), try Self.canonicalJSON(recordedSpec))

        // One review edit adds the result assertion the automatic recording
        // intentionally does not infer, then the Tier B run must restore the
        // three paper changes after a direct-store reset.
        var editedSpec = recordedSpec
        let editedID = "s3.surface.\(runID)"
        editedSpec["id"] = editedID
        var editedSteps = recordedSteps
        for index in editedSteps.indices {
            var expect = editedSteps[index]["expect"] as? [String: Any] ?? [:]
            expect["fields"] = [["path": "$.effects_failed", "equals": 0]]
            editedSteps[index]["expect"] = expect
        }
        editedSpec["steps"] = editedSteps
        let saved = try await cli.call("surface-create", [
            "scenario-create", "--spec", try Self.jsonString(editedSpec),
        ])
        XCTAssertEqual(saved["ok"] as? Bool, true, "\(saved)")
        XCTAssertEqual(saved["scenario_id"] as? String, editedID)

        try store.setStarred(id: papers[0], isStarred: false)
        try store.setFlag(id: papers[1], color: nil, style: nil, length: nil)
        try store.removeTag(id: papers[2], tag: tag)
        let before = try papers.map { try XCTUnwrap(store.getItem(id: $0)) }
        XCTAssertFalse(before[0].isStarred)
        XCTAssertNil(before[1].flagColor)
        XCTAssertFalse(before[2].tags.contains(tag))

        let report = try await cli.call("surface-run", [
            "scenario-run", "--scenario-id", editedID, "--tier", "b",
            "--base-url", "http://127.0.0.1:\(context.port)",
        ])
        XCTAssertEqual(report["ok"] as? Bool, true, "\(report)")
        XCTAssertEqual(report["passed"] as? Int, 1, "\(report)")
        XCTAssertEqual(report["failed"] as? Int, 0, "\(report)")
        let after = try papers.map { try XCTUnwrap(store.getItem(id: $0)) }
        XCTAssertTrue(after[0].isStarred)
        XCTAssertEqual(after[1].flagColor, "blue")
        XCTAssertTrue(after[2].tags.contains(tag))
        try Self.writeJSON(
            ["surface_id": surfaceID, "papers": papers, "native_replies": nativeReplies,
             "history": history, "recorded": recorded, "get": fetched,
             "created": saved, "report": report],
            to: context.output.appendingPathComponent("s3-surface-proof-\(runID).json"))
    }

    @MainActor
    private func proofContext() async throws -> ProofContext? {
        let env = ProcessInfo.processInfo.environment
        guard env["IMPRESS_S3_PROOF"] == "1" else {
            throw XCTSkip("Set IMPRESS_S3_PROOF=1 to run the isolated hosted proof")
        }
        XCTAssertTrue(ProcessInfo.processInfo.arguments.contains("--ui-testing"))
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return nil }
        let port = try XCTUnwrap(env["IMPRESS_S3_PROOF_PORT"].flatMap { UInt16($0) })
        XCTAssertEqual(port, ImpressHTTPServer.configuredPort)
        guard port == ImpressHTTPServer.configuredPort else { return nil }
        let deviceID = try XCTUnwrap(env["IMPRESS_DEVICE_ID"])
        XCTAssertFalse(deviceID.isEmpty)
        XCTAssertNotEqual(deviceID, "default")
        let cliPath = try XCTUnwrap(env["IMPRESS_S3_CLI_PATH"])
        let cliIsAbsoluteExecutable = cliPath.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: cliPath)
        XCTAssertTrue(cliIsAbsoluteExecutable)
        guard cliIsAbsoluteExecutable else { return nil }
        let proofRootPath = try XCTUnwrap(env["IMPRESS_S3_PROOF_ROOT"])
        let proofRoot = URL(fileURLWithPath: proofRootPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let outputPath = try XCTUnwrap(env["IMPRESS_S3_PROOF_OUTPUT"])
        let outputBase = URL(fileURLWithPath: outputPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()

        // A hosted XCTest chooses impress-unit-tests-<pid>; a UI-test app
        // chooses impress-ui-tests-<pid>. Both are accepted only under macOS
        // temporaryDirectory, and only when every store path agrees exactly.
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let posixTmp = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        let ownedRoot = [tmp, posixTmp].contains { proofRoot.path.hasPrefix($0.path + "/") }
            && proofRoot.lastPathComponent.hasPrefix("impress-s3-proof-")
        let bootstrapDB = try XCTUnwrap(env["IMPRESS_STORE_PATH"])
        let bootstrapWorkspace = try XCTUnwrap(env["IMPRESS_WORKSPACE"])
        let bootstrapURL = URL(fileURLWithPath: bootstrapDB).standardizedFileURL.resolvingSymlinksInPath()
        let bootstrapWorkspaceURL = URL(fileURLWithPath: bootstrapWorkspace, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let bootstrapIsOwned = ownedRoot
            && bootstrapURL.path.hasPrefix(proofRoot.path + "/")
            && bootstrapURL.lastPathComponent == "impress.sqlite"
            && bootstrapWorkspaceURL.path == bootstrapURL.deletingLastPathComponent().path
            && env["IMBIB_STORE_PATH"] == bootstrapDB
            && outputBase.path.hasPrefix(proofRoot.path + "/")
        XCTAssertTrue(bootstrapIsOwned, "Launch paths must remain inside IMPRESS_S3_PROOF_ROOT")
        guard bootstrapIsOwned else { return nil }
        let output = outputBase.appendingPathComponent("host-\(pid)", isDirectory: true)
        let roots = ["impress-unit-tests-\(pid)", "impress-ui-tests-\(pid)"].map {
            FileManager.default.temporaryDirectory.appendingPathComponent($0, isDirectory: true)
                .standardizedFileURL
        }
        let db = try XCTUnwrap(RustStoreAdapter.shared.databaseLocation)
        let dbURL = URL(fileURLWithPath: db).standardizedFileURL
        let root = try XCTUnwrap(roots.first { dbURL.path == $0.appendingPathComponent("workspace/impress.sqlite").path })
        XCTAssertEqual(dbURL.path, SharedWorkspace.databasePath)
        XCTAssertTrue(dbURL.resolvingSymlinksInPath().path.hasPrefix(tmp.path + "/"))
        XCTAssertFalse(dbURL.path.localizedCaseInsensitiveContains("Group Containers"))
        guard dbURL.path == SharedWorkspace.databasePath,
              dbURL.resolvingSymlinksInPath().path.hasPrefix(tmp.path + "/"),
              !dbURL.path.localizedCaseInsensitiveContains("Group Containers") else { return nil }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The server mints a per-launch token under the same isolated root.
        // A headless CLI otherwise looks in the real App Group container.
        let tokenPath = LoopbackToken.path(port: port)
        XCTAssertTrue(tokenPath.hasPrefix(root.path + "/"))
        guard tokenPath.hasPrefix(root.path + "/") else { return nil }
        var token: String?
        for _ in 0..<30 {
            if await ImpressHTTPServer.shared.running,
               let value = try? String(contentsOfFile: tokenPath, encoding: .utf8),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = value.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let bearer = try XCTUnwrap(token, "Isolated impress HTTP server did not publish its token")

        var childEnv = env
        childEnv["IMPRESS_STORE_PATH"] = dbURL.path
        childEnv["IMBIB_STORE_PATH"] = dbURL.path
        childEnv["IMPRESS_WORKSPACE"] = root.appendingPathComponent("workspace").path
        childEnv["IMPRESS_DEVICE_ID"] = deviceID
        childEnv["IMPRESS_APP_TOKEN"] = bearer
        let cli = ProofCLI(executable: cliPath, storePath: dbURL.path, environment: childEnv, output: output)
        return ProofContext(store: try XCTUnwrap(RustStoreAdapter.shared.layoutSharedStore()),
                            cli: cli, output: output, port: port)
    }

    private static func jsonString(_ value: Any) throws -> String {
        try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func canonicalJSON(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: try XCTUnwrap(value), options: [.sortedKeys])
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func writeJSON(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: path, options: .atomic)
    }
}

private struct ProofContext {
    let store: SharedStore
    let cli: ProofCLI
    let output: URL
    let port: UInt16
}

private struct ProofCLI {
    let executable: String
    let storePath: String
    let environment: [String: String]
    let output: URL

    func call(_ label: String, _ arguments: [String]) async throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--store-path", storePath] + arguments
        process.environment = environment
        let callID = UUID().uuidString.lowercased()
        let stdout = output.appendingPathComponent("cli-\(label)-\(callID).json")
        let stderr = output.appendingPathComponent("cli-\(label)-\(callID).log")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: stdout)
        let errHandle = try FileHandle(forWritingTo: stderr)
        process.standardOutput = outHandle
        process.standardError = errHandle
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let data = try Data(contentsOf: stdout)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   "\(arguments.first ?? label) wrote no JSON; see \(stderr.path)")
        XCTAssertEqual(status, 0, "\(arguments.first ?? label): \(result); see \(stderr.path)")
        return result
    }
}
#endif
