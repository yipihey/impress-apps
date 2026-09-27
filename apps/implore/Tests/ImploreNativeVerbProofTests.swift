#if os(macOS)
import Foundation
import ImpressAutomation
import ImpressKit
import PublicationManagerCore
import XCTest
@testable import implore

/// Opt-in hosted proof for implore's in-process domain FFI. The app and bearer
/// must belong to a separate, PID-owned test launch; this never probes the
/// user's running implore instance.
final class ImploreNativeVerbProofTests: XCTestCase {
    @MainActor
    func testFiveFormerlyDeadVerbsUseLoadedViewer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["IMPRESS_P5B_IMPLORE_PROOF"] == "1" else {
            throw XCTSkip("Requires an isolated implore hosted test launch")
        }
        let port = try XCTUnwrap(env["IMPRESS_P5B_IMPLORE_PORT"].flatMap(UInt16.init))
        let pid = ProcessInfo.processInfo.processIdentifier
        let root = SharedContainer.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let expectedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-unit-tests-\(pid)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try requireIsolation(ImpressRuntime.isUnitTestProcess && ImpressRuntime.isUITestingProcess,
                             "Host must be a UI-testing XCTest process")
        try requireIsolation(root == expectedRoot, "Host root must be PID-owned scratch")
        try requireIsolation(
            SharedWorkspace.databaseURL.standardizedFileURL.resolvingSymlinksInPath()
                == root.appendingPathComponent("workspace/impress.sqlite"),
            "Workspace database must be under the PID-owned root")
        try requireIsolation(RustStoreAdapter.shared.databaseLocation == SharedWorkspace.databasePath,
                             "Rust store must use the same scratch database")
        try requireIsolation(UserDefaults.standard.integer(forKey: "httpAutomationPort") == Int(port),
                             "HTTP port must be the proof port")
        try requireIsolation(env["IMPRESS_DEVICE_ID"]?.hasPrefix("codex-p5b-") == true,
                             "Device ID must be proof-owned")
        let tokenPath = LoopbackToken.path(port: port)
        try requireIsolation(tokenPath.hasPrefix(root.path + "/"), "Token path must be scratch-owned")

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/rg-volume.npz")
        try requireIsolation(FileManager.default.fileExists(atPath: fixture.path),
                             "Proof fixture must exist before sending native requests")
        var token: String?
        for _ in 0..<100 {
            token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if token?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let bearer = try XCTUnwrap(token)

        let loaded = try await call("rg-load", ["path": fixture.path], port: port, bearer: bearer)
        XCTAssertEqual(loaded.status, 200)
        let loadValue = try XCTUnwrap(jsonStringValue(loaded.value))
        XCTAssertEqual(loadValue["status"] as? String, "ok")
        XCTAssertEqual(AppState.shared?.rgViewerState?.info.gridSize, 4)

        let series = try await call("plot-series", ["series": ["energy"], "title": "Energy"], port: port, bearer: bearer)
        XCTAssertEqual(series.status, 200)
        XCTAssertTrue((series.value as? String)?.contains("<svg") == true)
        let histogram = try await call("plot-histogram", ["quantity": "velocity_magnitude", "bins": 4], port: port, bearer: bearer)
        XCTAssertEqual(histogram.status, 200)
        XCTAssertTrue((histogram.value as? String)?.contains("<svg") == true)

        let params = "{\"quantity\":\"velocity_magnitude\",\"axis\":\"z\",\"position\":1}"
        let statistics = try await call("rg-statistics", ["params_json": params], port: port, bearer: bearer)
        XCTAssertEqual(statistics.status, 200)
        let stats = try XCTUnwrap(jsonStringValue(statistics.value))
        XCTAssertTrue((stats["mean"] as? Double)?.isFinite == true)
        XCTAssertEqual(stats["width"] as? Int, 4)

        let raw = try await call("rg-slice-raw", ["params_json": params], port: port, bearer: bearer)
        XCTAssertEqual(raw.status, 200)
        let rawValue = try XCTUnwrap(jsonStringValue(raw.value))
        XCTAssertEqual((rawValue["values"] as? [Double])?.count, 16)
        XCTAssertEqual(rawValue["width"] as? Int, 4)

        let png = try await call("rg-slice-png", ["format": "base64"], port: port, bearer: bearer)
        XCTAssertEqual(png.status, 200)
        let pngValue = try XCTUnwrap(jsonStringValue(png.value))
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(pngValue["png_base64"] as? String)))
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(pngValue["width"] as? Int, 4)
    }

    private func requireIsolation(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "ImpressP5bProofIsolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func jsonStringValue(_ value: Any) -> [String: Any]? {
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func call(_ method: String, _ args: [String: Any], port: UInt16, bearer: String) async throws -> (status: Int, value: Any) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/verb/implore-service_\(method)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: args)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
    }
}
#endif
