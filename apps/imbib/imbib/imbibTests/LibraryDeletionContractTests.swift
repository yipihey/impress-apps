import Foundation
import ImpressAutomation
import XCTest
@testable import PublicationManagerCore

@MainActor
final class LibraryDeletionContractTests: XCTestCase {
    func testLibraryFileDeletionUsesScratchContainersAndUnlinkOnlyKeepsFiles() async throws {
        guard ProcessInfo.processInfo.environment["IMPRESS_P5B_TRANSPORT_PROOF"] == "1" else {
            throw XCTSkip("Run the isolated native transport proof")
        }
        let settings = AutomationSettingsStore.shared
        let wasEnabled = await settings.isEnabled
        await settings.setEnabled(true)
        do {
            let store = RustStoreAdapter.shared
            let suffix = UUID().uuidString
            let unlinkLibrary = try XCTUnwrap(store.createLibrary(name: "Unlink-only \(suffix)"))
            let unlinkContainers = LibraryManager.allContainerURLs(for: unlinkLibrary.id)
            defer {
                for url in unlinkContainers { try? FileManager.default.removeItem(at: url) }
            }
            for directory in unlinkContainers {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("scratch".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            }

            let router = HTTPAutomationRouter()
            try ImbibNativeVerbs.install(router: router)
            let unlink = await router.route(HTTPRequest(
                method: "DELETE",
                path: "/api/libraries/\(unlinkLibrary.id.uuidString)",
                queryParams: ["deleteFiles": "false"]
            ))
            XCTAssertTrue(unlink.status == 200)
            XCTAssertNil(store.getLibrary(id: unlinkLibrary.id),
                         "unlink-only deletion removes the library row")
            XCTAssertTrue(unlinkContainers.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

            let cleanupLibrary = try XCTUnwrap(store.createLibrary(name: "Cleanup-only \(suffix)"))
            let cleanupContainers = LibraryManager.allContainerURLs(for: cleanupLibrary.id)
            defer {
                for url in cleanupContainers { try? FileManager.default.removeItem(at: url) }
            }
            for directory in cleanupContainers {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("scratch".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            }
            let cleaned = await router.route(HTTPRequest(
                method: "POST", path: "/api/verb/imbib-library-service_delete-library-undoable",
                body: "{\"id\":\"\(cleanupLibrary.id.uuidString)\",\"delete_files\":true}"
            ))
            XCTAssertTrue(cleaned.status == 200)
            let cleanedResult = try XCTUnwrap(JSONSerialization.jsonObject(with: cleaned.body) as? [String: Any])
            XCTAssertEqual(cleanedResult["ok"] as? Bool, true)
            XCTAssertEqual(cleanedResult["affected_count"] as? Int, 1)
            XCTAssertTrue(cleanupContainers.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertTrue(store.getLibrary(id: cleanupLibrary.id) == nil)

            let batchLibraries = try (0..<2).map { index in
                try XCTUnwrap(store.createLibrary(name: "Batch cleanup \(index) \(suffix)"))
            }
            let batchContainers = batchLibraries.flatMap { LibraryManager.allContainerURLs(for: $0.id) }
            defer {
                for url in batchContainers { try? FileManager.default.removeItem(at: url) }
            }
            for directory in batchContainers {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("scratch".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            }
            let ids = (batchLibraries + [batchLibraries[0]])
                .map { "\"\($0.id.uuidString)\"" }
                .joined(separator: ",")
            let batch = await router.route(HTTPRequest(
                method: "POST", path: "/api/verb/imbib-library-service_delete-libraries",
                body: "{\"ids\":[\(ids)],\"delete_files\":true}"
            ))
            XCTAssertTrue(batch.status == 200)
            XCTAssertEqual(String(decoding: batch.body, as: UTF8.self), "2")
            XCTAssertTrue(batchContainers.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertTrue(batchLibraries.allSatisfy { store.getLibrary(id: $0.id) == nil })

            let preflightLibrary = try XCTUnwrap(store.createLibrary(name: "Batch preflight \(suffix)"))
            let preflightContainers = LibraryManager.allContainerURLs(for: preflightLibrary.id)
            defer {
                for url in preflightContainers { try? FileManager.default.removeItem(at: url) }
            }
            for directory in preflightContainers {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("scratch".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            }
            let preflight = await router.route(HTTPRequest(
                method: "POST", path: "/api/verb/imbib-library-service_delete-libraries",
                body: "{\"ids\":[\"\(preflightLibrary.id.uuidString)\",\"\(UUID().uuidString)\"],\"delete_files\":true}"
            ))
            XCTAssertEqual(preflight.status, 404, String(decoding: preflight.body, as: UTF8.self))
            XCTAssertTrue(store.getLibrary(id: preflightLibrary.id) != nil)
            XCTAssertTrue(preflightContainers.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        } catch {
            await settings.setEnabled(wasEnabled)
            throw error
        }
        await settings.setEnabled(wasEnabled)
    }

}
