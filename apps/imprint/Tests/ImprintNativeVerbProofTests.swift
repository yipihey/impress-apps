import Foundation
import ImpressAutomation
import ImpressKit
import PublicationManagerCore
import XCTest
@testable import imprint

/// Hosted proof only. The test host's SharedWorkspace is PID-owned scratch;
/// the production App Group path must never be opened by this fixture.
@MainActor
final class ImprintNativeVerbProofTests: XCTestCase {
    func testNativeGenericRouteAndAppRefusalUseTheScratchWorkspace() async throws {
        guard ProcessInfo.processInfo.environment["IMPRINT_P5B_PROOF"] == "1" else {
            throw XCTSkip("Set IMPRINT_P5B_PROOF=1 for the isolated native proof")
        }
        let env = ProcessInfo.processInfo.environment
        let port = try XCTUnwrap(env["IMPRINT_P5B_PROOF_PORT"].flatMap(UInt16.init))
        let path = SharedWorkspace.databasePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-unit-tests-\(pid)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try requireIsolation(ImpressRuntime.isUnitTestProcess && ImpressRuntime.isUITestingProcess,
                             "Host must be a UI-testing XCTest process")
        try requireIsolation(
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                == root.appendingPathComponent("workspace/impress.sqlite"),
            "Workspace database must be PID-owned scratch")
        try requireIsolation(RustStoreAdapter.shared.databaseLocation == path,
                             "Rust store must use the same scratch database")
        try requireIsolation(UserDefaults.standard.integer(forKey: "httpAutomationPort") == Int(port),
                             "HTTP port must be the proof port")
        try requireIsolation(env["IMPRESS_DEVICE_ID"]?.hasPrefix("codex-p5b-") == true,
                             "Device ID must be proof-owned")
        try ImprintNativeVerbs.install()

        let router = ImprintHTTPRouter()
        let status = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-app-service_status", body: "{}"))
        XCTAssertEqual(status.status, 200, String(data: status.body, encoding: .utf8) ?? "")
        let statusBody = try XCTUnwrap(JSONSerialization.jsonObject(with: status.body) as? [String: Any])
        XCTAssertNotEqual(statusBody["code"] as? String, "not-found")

        let outline = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-manuscript-service_document-outline",
            body: #"{"source":"= Title\n== Section"}"#))
        XCTAssertEqual(outline.status, 200, String(data: outline.body, encoding: .utf8) ?? "")
        let outlineBody = try XCTUnwrap(JSONSerialization.jsonObject(with: outline.body) as? [String: Any])
        XCTAssertNotEqual(outlineBody["code"] as? String, "not-found")

        let compileCache = root.appendingPathComponent("compile-cache")
        setenv("IMPRINT_COMPILE_CACHE_DIR", compileCache.path, 1)
        let compileArgs: [String: Any] = [
            "source": "= Native proof\n\nA short PDF.\n",
            "options": ["page_size": "A4", "font_size": 11.0,
                        "margin_top": 72.0, "margin_right": 72.0,
                        "margin_bottom": 72.0, "margin_left": 72.0],
        ]
        let compileBytes = try JSONSerialization.data(withJSONObject: compileArgs)
        let compiled = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-manuscript-service_compile-typst",
            body: String(decoding: compileBytes, as: UTF8.self)))
        XCTAssertEqual(compiled.status, 200, String(decoding: compiled.body, as: UTF8.self))
        let compileValue = try XCTUnwrap(JSONSerialization.jsonObject(with: compiled.body) as? [String: Any])
        XCTAssertTrue(compileValue["error"] is NSNull)
        let pdfPath = try XCTUnwrap(compileValue["pdf_path"] as? String)
        try requireIsolation(pdfPath.hasPrefix(compileCache.path + "/"),
                             "Compiled PDF must remain in the PID-owned cache")
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: pdfPath)).starts(with: Data("%PDF".utf8)))

        let refused = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-app-service_get-content",
            body: #"{"document_id":"not-a-uuid"}"#))
        XCTAssertEqual(refused.status, 400, String(data: refused.body, encoding: .utf8) ?? "")
        let refusedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: refused.body) as? [String: Any])
        XCTAssertNotEqual(refusedBody["code"] as? String, "not-found")

        func call(_ verb: String, _ args: [String: Any]) async throws -> HTTPResponse {
            let data = try JSONSerialization.data(withJSONObject: args)
            return await router.route(HTTPRequest(
                method: "POST", path: "/api/verb/imprint-app-service_\(verb)",
                body: String(decoding: data, as: UTF8.self)))
        }
        func value(_ response: HTTPResponse) throws -> Any {
            try JSONSerialization.jsonObject(with: response.body, options: .fragmentsAllowed)
        }
        let created = try await call("create-document", ["title": "Created by generic verb", "format": "typst"])
        XCTAssertEqual(created.status, 200, String(decoding: created.body, as: UTF8.self))
        let createdID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(value(created) as? String)))
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: createdID)?.title, "Created by generic verb")
        let createdContent = try await call("get-content", ["document_id": createdID.uuidString])
        XCTAssertEqual(createdContent.status, 200)
        XCTAssertEqual(try value(createdContent) as? String, "")

        let id = try ManuscriptStoreAdapter.shared.createManuscript(
            title: "Native proof", format: .typst, body: "alpha beta alpha")
        let replaced = try await call("replace", [
            "document_id": id.uuidString, "find": "alpha", "replace": "gamma"])
        XCTAssertEqual(replaced.status, 200, String(data: replaced.body, encoding: .utf8) ?? "")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, "gamma beta gamma")
        XCTAssertEqual(ManuscriptSessionRegistry.shared.session(for: id)?.source, "gamma beta gamma")
        let afterReplace = try await call("get-content", ["document_id": id.uuidString])
        XCTAssertEqual(afterReplace.status, 200)
        XCTAssertEqual(try value(afterReplace) as? String, "gamma beta gamma")

        let inserted = try await call("insert-text", [
            "document_id": id.uuidString, "offset": 0, "text": "= "])
        XCTAssertEqual(inserted.status, 200, String(data: inserted.body, encoding: .utf8) ?? "")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, "= gamma beta gamma")

        let deleted = try await call("delete-text", [
            "document_id": id.uuidString, "offset": 0, "length": 2])
        XCTAssertEqual(deleted.status, 200, String(data: deleted.body, encoding: .utf8) ?? "")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, "gamma beta gamma")
        let afterDelete = try await call("get-content", ["document_id": id.uuidString])
        XCTAssertEqual(afterDelete.status, 200)
        XCTAssertEqual(try value(afterDelete) as? String, "gamma beta gamma")

        let renamed = try await call("update-document", [
            "document_id": id.uuidString, "title": "Renamed proof"])
        XCTAssertEqual(renamed.status, 200, String(data: renamed.body, encoding: .utf8) ?? "")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.title, "Renamed proof")

        let metadata = try await call("update-metadata", [
            "document_id": id.uuidString,
            "metadata_json": #"{"status":"in-review","authors":["Human Author"]}"#])
        XCTAssertEqual(metadata.status, 200, String(decoding: metadata.body, as: UTF8.self))
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.status, "in-review")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.authors, ["Human Author"])

        // A local editor change has not yet passed its debounce. Native insert
        // must derive from that live buffer, not the older stored body. The
        // offset is an editor UTF-16 position, after the two-unit emoji.
        let session = try XCTUnwrap(ManuscriptSessionRegistry.shared.session(for: id))
        session.source = "human 😀 gamma beta gamma"
        let merged = try await call("insert-text", [
            "document_id": id.uuidString, "offset": 9, "text": "agent "])
        XCTAssertEqual(merged.status, 200, String(decoding: merged.body, as: UTF8.self))
        XCTAssertEqual(session.source, "human 😀 agent gamma beta gamma")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, session.source)
        let finalContent = try await call("get-content", ["document_id": id.uuidString])
        XCTAssertEqual(finalContent.status, 200)
        XCTAssertEqual(try value(finalContent) as? String, session.source)
    }

    private func requireIsolation(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "ImpressP5bProofIsolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
