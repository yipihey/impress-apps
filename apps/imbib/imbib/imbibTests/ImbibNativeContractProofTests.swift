import Foundation
import ImpressAutomation
import XCTest
@testable import PublicationManagerCore

@MainActor
final class ImbibNativeContractProofTests: XCTestCase {
    func testIdentifierImportPreservesDuplicateAndUnsupportedPerPaperOutcomes() async throws {
        guard ProcessInfo.processInfo.environment["IMPRESS_P5B_TRANSPORT_PROOF"] == "1" else {
            throw XCTSkip("Run the isolated native transport proof")
        }
        let settings = AutomationSettingsStore.shared
        let wasEnabled = await settings.isEnabled
        await settings.setEnabled(true)
        do {
            let store = RustStoreAdapter.shared
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
            let citeKey = "NativeImport\(suffix)"
            let library = try XCTUnwrap(store.createLibrary(name: "Native import \(suffix)"))
            let paperIDs = store.importBibTeX(
                "@article{\(citeKey), title={Native import fixture}, author={Doe, Jane}, year={2026}}",
                libraryId: library.id)
            XCTAssertTrue(paperIDs.count == 1)
            let paperID = try XCTUnwrap(paperIDs.first)
            let collection = try XCTUnwrap(store.createCollection(name: "Import target \(suffix)", libraryId: library.id))

            let router = HTTPAutomationRouter()
            let retiredIdentifierImport = await router.route(HTTPRequest(
                method: "POST", path: "/api/papers/add",
                body: "{\"identifiers\":[\"\(citeKey)\"],\"library\":\"\(library.id)\"}"
            ))
            XCTAssertEqual(retiredIdentifierImport.status, 404)
            let result = await router.invokeNativeVerb(
                method: "import_identifiers",
                argsJSON: """
                {"identifiers":["\(citeKey)","unsupported-\(suffix)"],"library_id":"\(library.id)","collection_id":"\(collection.id)","download_pdfs":false}
                """
            )
            XCTAssertTrue(result.status == 200)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.bodyJson.utf8)) as? [String: Any])
            XCTAssertTrue((body["added"] as? [Any])?.isEmpty == true)
            XCTAssertTrue(body["duplicates"] as? [String] == [citeKey])
            let failed = try XCTUnwrap(body["failed"] as? [String: String])
            XCTAssertTrue(failed["unsupported-\(suffix)"]?.isEmpty == false)
            XCTAssertTrue(store.listCollections(forPublication: paperID).contains { $0.id == collection.id })
        } catch {
            await settings.setEnabled(wasEnabled)
            throw error
        }
        await settings.setEnabled(wasEnabled)
    }

}
