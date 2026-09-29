#if os(macOS)
import Foundation
import ImploreCore
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
        // LibraryManager's test-mode persistence is under this same root.
        let libraryURL = root.appendingPathComponent("Application Support/implore/library.json")
        try requireIsolation(libraryURL.path.hasPrefix(root.path + "/"),
                             "Figure library must be scratch-owned")

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

        // Exercise the canonical figure verbs against real scratch library and
        // store writes. The two dataset IDs make a missing filter observable.
        let firstDataset = "p5b-figure-a-\(UUID().uuidString)"
        let secondDataset = "p5b-figure-b-\(UUID().uuidString)"
        let figureSeries: [[String: Any]] = [
            ["label": "proof", "x": [0.0, 1.0, 2.0], "y": [1.0, 2.0, 3.0]]
        ]
        func createFigure(datasetID: String, name: String) async throws -> String {
            let created = try await call("create-figure", [
                "dataset_id": datasetID, "plot_type": "scatter", "x": "time",
                "y": "value", "name": name, "series": figureSeries
            ], port: port, bearer: bearer)
            XCTAssertEqual(created.status, 200)
            let value = try XCTUnwrap(created.value as? [String: Any])
            XCTAssertEqual(value["ok"] as? Bool, true)
            XCTAssertEqual(value["dataset_id"] as? String, datasetID)
            return try XCTUnwrap(value["id"] as? String)
        }
        let firstID = try await createFigure(datasetID: firstDataset, name: "Figure A")
        let secondID = try await createFigure(datasetID: secondDataset, name: "Figure B")
        XCTAssertNotEqual(firstID, secondID)

        let listed = try await call("list-figures", ["dataset_id": firstDataset], port: port, bearer: bearer)
        XCTAssertEqual(listed.status, 200)
        let figures = try XCTUnwrap(listed.value as? [[String: Any]])
        XCTAssertEqual(figures.count, 1)
        XCTAssertEqual(figures.first?["id"] as? String, firstID)
        XCTAssertEqual(figures.first?["dataset_id"] as? String, firstDataset)
        XCTAssertFalse(figures.contains { $0["id"] as? String == secondID })

        let readback = try await call("get-figure", ["figure_id": firstID], port: port, bearer: bearer)
        XCTAssertEqual(readback.status, 200)
        let figure = try XCTUnwrap(readback.value as? [String: Any])
        XCTAssertEqual(figure["id"] as? String, firstID)
        XCTAssertEqual(figure["dataset_id"] as? String, firstDataset)
        let savedLibrary = try String(contentsOf: libraryURL, encoding: .utf8)
        XCTAssertTrue(savedLibrary.contains(firstID))
        XCTAssertTrue(savedLibrary.contains(secondID))
        XCTAssertEqual(RustStoreAdapter.shared.databaseLocation, SharedWorkspace.databasePath)

        let mutationDataset = "p5c8-mutation-\(UUID().uuidString)"
        let initialSeries: [[String: Any]] = [[
            "label": "initial", "x": [0.0, 1.0, 2.0], "y": [1.0, 2.0, 3.0]
        ]]
        let updatedSeries: [[String: Any]] = [[
            "label": "updated", "x": [0.0, 1.0, 2.0], "y": [3.0, 1.0, 4.0]
        ]]
        let initialViewState = #"{"title":"initial title","width":640,"height":400}"#
        func createByVerb() async throws -> (id: String, hash: String) {
            let result = try await call("create-figure", [
                "dataset_id": mutationDataset, "plot_type": "line", "x": "time",
                "y": "flux", "name": "Shared mutation figure", "title": "Shared plot",
                "color_column": "instrument", "width": 640, "height": 400,
                "view_state": initialViewState, "series": initialSeries
            ], port: port, bearer: bearer)
            XCTAssertEqual(result.status, 200)
            let value = try XCTUnwrap(result.value as? [String: Any])
            XCTAssertEqual(value["ok"] as? Bool, true)
            return (try XCTUnwrap(value["id"] as? String),
                    try XCTUnwrap((value["artifact"] as? [String: Any])?["data_hash"] as? String))
        }
        func createByHTTP() async throws -> (id: String, hash: String) {
            let result = try await request("POST", path: "/api/figures", args: [
                "datasetId": mutationDataset, "plotType": "line", "x": "time",
                "y": "flux", "name": "Shared mutation figure", "title": "Shared plot",
                "colorColumn": "instrument", "width": 640, "height": 400,
                "view_state": initialViewState, "series": initialSeries
            ], port: port, bearer: bearer)
            XCTAssertEqual(result.status, 201)
            let value = try XCTUnwrap(result.value as? [String: Any])
            return (try XCTUnwrap((value["figure"] as? [String: Any])?["id"] as? String),
                    try XCTUnwrap((value["artifact"] as? [String: Any])?["dataHash"] as? String))
        }

        let verbFigure = try await createByVerb()
        let httpFigure = try await createByHTTP()
        XCTAssertEqual(verbFigure.hash, httpFigure.hash)
        let oldBlob = ImploreStoreAdapter.shared.contentStoreDirectory
            .appendingPathComponent(verbFigure.hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldBlob.path))
        let initialBytes = try Data(contentsOf: oldBlob)
        XCTAssertEqual(Array(initialBytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])

        let updatedViewState = #"{"title":"updated title","width":800,"height":500}"#
        let updatedByVerb = try await call("update-figure", [
            "figure_id": verbFigure.id, "name": "Updated shared figure",
            "plot_type": "scatter", "x": "time", "y": "flux",
            "color_column": "instrument", "title": "Updated plot",
            "width": 800, "height": 500, "series": updatedSeries,
            "view_state": updatedViewState
        ], port: port, bearer: bearer)
        XCTAssertEqual(updatedByVerb.status, 200)
        let updatedVerbValue = try XCTUnwrap(updatedByVerb.value as? [String: Any])
        XCTAssertEqual(updatedVerbValue["ok"] as? Bool, true)
        let newHash = try XCTUnwrap(
            (updatedVerbValue["artifact"] as? [String: Any])?["data_hash"] as? String)
        XCTAssertNotEqual(newHash, verbFigure.hash)
        let newBlob = ImploreStoreAdapter.shared.contentStoreDirectory.appendingPathComponent(newHash)
        let updatedBytes = try Data(contentsOf: newBlob)
        XCTAssertEqual(Array(updatedBytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldBlob.path),
                      "the HTTP-created peer still references the original shared blob")

        let updatedByHTTP = try await request("PATCH", path: "/api/figures/\(httpFigure.id)", args: [
            "name": "Updated shared figure", "plotType": "scatter", "x": "time",
            "y": "flux", "colorColumn": "instrument", "title": "Updated plot",
            "width": 800, "height": 500, "series": updatedSeries,
            "view_state": updatedViewState
        ], port: port, bearer: bearer)
        XCTAssertEqual(updatedByHTTP.status, 200)
        let updatedHTTPValue = try XCTUnwrap(updatedByHTTP.value as? [String: Any])
        XCTAssertEqual((updatedHTTPValue["artifact"] as? [String: Any])?["dataHash"] as? String, newHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBlob.path),
                       "the old blob is released after its final figure reference changes")

        let exportByVerb = try await call("export-figure", [
            "figure_id": verbFigure.id, "format": "png"
        ], port: port, bearer: bearer)
        XCTAssertEqual(exportByVerb.status, 200)
        let verbExportPath = try XCTUnwrap(exportByVerb.value as? String)
        let exportByHTTP = try await request("POST", path: "/api/figures/\(httpFigure.id)/export",
                                             args: ["format": "png"], port: port, bearer: bearer)
        XCTAssertEqual(exportByHTTP.status, 200)
        let httpExportPath = try XCTUnwrap((exportByHTTP.value as? [String: Any])?["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: verbExportPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: httpExportPath))

        let deletedByVerb = try await call("delete-figure", ["figure_id": verbFigure.id],
                                           port: port, bearer: bearer)
        XCTAssertEqual(deletedByVerb.status, 200)
        XCTAssertEqual(deletedByVerb.value as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newBlob.path),
                      "the HTTP-created peer still references the updated blob")
        XCTAssertFalse(FileManager.default.fileExists(atPath: verbExportPath),
                       "delete removes the figure's exported files")
        let peerReadback = try await call("get-figure", ["figure_id": httpFigure.id],
                                          port: port, bearer: bearer)
        XCTAssertEqual(peerReadback.status, 200)
        let deletedByHTTP = try await request("DELETE", path: "/api/figures/\(httpFigure.id)",
                                               args: [:], port: port, bearer: bearer)
        XCTAssertEqual(deletedByHTTP.status, 200)
        XCTAssertEqual((deletedByHTTP.value as? [String: Any])?["deleted"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: httpExportPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newBlob.path),
                       "the final delete releases the unreferenced content blob")
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
        try await request("POST", path: "/api/verb/implore-service_\(method)", args: args,
                          port: port, bearer: bearer)
    }

    private func request(_ method: String, path: String, args: [String: Any],
                         port: UInt16, bearer: String) async throws -> (status: Int, value: Any) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: args)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
    }
}
#endif
