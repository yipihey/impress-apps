import Foundation
import ImpressAutomation
import XCTest
@testable import PublicationManagerCore

@MainActor
final class CollectionMembershipContractTests: XCTestCase {
    func testRetiredMembershipRoutesAndGeneratedVerbPreserveSeededOutcomes() async throws {
        guard ProcessInfo.processInfo.environment["IMPRESS_P5B_TRANSPORT_PROOF"] == "1" else {
            throw XCTSkip("Run the isolated native transport proof")
        }
        let settings = AutomationSettingsStore.shared
        let wasEnabled = await settings.isEnabled
        await settings.setEnabled(true)
        addTeardownBlock { await settings.setEnabled(wasEnabled) }

        let store = RustStoreAdapter.shared
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try XCTUnwrap(store.createLibrary(name: "P5c13 membership \(suffix)"))
        let verbCollection = try XCTUnwrap(
            store.createCollection(name: "P5c13 verb \(suffix)", libraryId: library.id))
        defer {
            store.deleteCollection(id: verbCollection.id)
            store.deleteLibrary(id: library.id)
        }

        let firstKey = "MembershipFirst\(suffix)"
        let secondKey = "MembershipSecond\(suffix)"
        let firstID = try XCTUnwrap(store.importBibTeX(
            "@article{\(firstKey), title={First member}, doi={10.1234/\(suffix.lowercased())}}",
            libraryId: library.id).first)
        let secondID = try XCTUnwrap(store.importBibTeX(
            "@article{\(secondKey), title={Second member}}", libraryId: library.id).first)
        let doi = "10.1234/\(suffix.lowercased())"
        let identifiers = [firstKey, "doi:\(doi)", secondID.uuidString, "Missing\(suffix)"]

        let router = HTTPAutomationRouter()
        try ImbibNativeVerbs.install(router: router)

        let retiredAdd = await router.route(HTTPRequest(
            method: "POST",
            path: "/api/collections/add-papers",
            body: try json(["collectionID": verbCollection.id.uuidString, "identifiers": identifiers])))
        XCTAssertEqual(retiredAdd.status, 404)

        let verbName = "imbib-library-service_update-collection-members"
        let versionBeforeVerbMutation = store.dataVersion
        let verbAdd = await router.route(HTTPRequest(
            method: "POST",
            path: "/api/verb/\(verbName)",
            body: try json([
                "collection_id": verbCollection.id.uuidString,
                "identifiers": identifiers,
                "action": "add",
            ])))
        XCTAssertEqual(verbAdd.status, 200, String(decoding: verbAdd.body, as: UTF8.self))
        let verbAddBody = try object(verbAdd)
        XCTAssertEqual(verbAddBody["assigned"] as? [String], [firstKey, doi, secondID.uuidString])
        XCTAssertEqual(verbAddBody["not_found"] as? [String], ["Missing\(suffix)"])
        XCTAssertGreaterThan(store.dataVersion, versionBeforeVerbMutation,
                             "the generated native write must notify imbib's store/display observers")
        XCTAssertEqual(Set(store.listCollectionMembers(collectionId: verbCollection.id).map(\.citeKey)),
                       Set([firstKey, secondKey]))
        let generatedMembers = await router.invokeNativeVerb(
            method: "list_collection_members",
            argsJSON: """
            {"collection_id":"\(verbCollection.id.uuidString)","sort_field":"title","ascending":true,"limit":50,"offset":0}
            """
        )
        XCTAssertEqual(generatedMembers.status, 200)
        let generatedMemberRows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(generatedMembers.bodyJson.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(generatedMemberRows.compactMap { $0["cite_key"] as? String }),
                       Set([firstKey, secondKey]))

        let retiredMembers = await router.route(HTTPRequest(
            method: "GET", path: "/api/collections/\(verbCollection.id.uuidString)/papers"))
        XCTAssertEqual(retiredMembers.status, 404)
        let retiredRemove = await router.route(HTTPRequest(
            method: "PUT",
            path: "/api/collections/\(verbCollection.id.uuidString)/papers",
            body: try json(["identifiers": identifiers, "action": "remove"])))
        XCTAssertEqual(retiredRemove.status, 404)

        let verbRemove = await router.route(HTTPRequest(
            method: "POST",
            path: "/api/verb/\(verbName)",
            body: try json([
                "collection_id": verbCollection.id.uuidString,
                "identifiers": identifiers,
                "action": "remove",
            ])))
        XCTAssertEqual(verbRemove.status, 200, String(decoding: verbRemove.body, as: UTF8.self))
        let verbRemoveBody = try object(verbRemove)
        XCTAssertEqual(verbRemoveBody["assigned"] as? [String], [firstKey, doi, secondID.uuidString])
        XCTAssertEqual(verbRemoveBody["not_found"] as? [String], ["Missing\(suffix)"])
        XCTAssertTrue(store.listCollectionMembers(collectionId: verbCollection.id).isEmpty)

        // A valid UUID that does not name a collection used to pass through
        // the route while RustStoreAdapter logged and swallowed the write error.
        let missingCollection = UUID()
        let missingLegacy = await router.route(HTTPRequest(
            method: "POST",
            path: "/api/collections/add-papers",
            body: try json(["collectionID": missingCollection.uuidString, "identifiers": [firstKey]])))
        XCTAssertEqual(missingLegacy.status, 404)
        let missingLegacyPut = await router.route(HTTPRequest(
            method: "PUT",
            path: "/api/collections/\(missingCollection.uuidString)/papers",
            body: try json(["identifiers": [firstKey], "action": "add"])))
        XCTAssertEqual(missingLegacyPut.status, 404)
        let missingVerb = await router.route(HTTPRequest(
            method: "POST",
            path: "/api/verb/\(verbName)",
            body: try json([
                "collection_id": missingCollection.uuidString,
                "identifiers": [firstKey],
                "action": "add",
            ])))
        XCTAssertEqual(missingVerb.status, 404)

        let invalidLegacyAction = await router.route(HTTPRequest(
            method: "PUT",
            path: "/api/collections/\(verbCollection.id.uuidString)/papers",
            body: try json(["identifiers": [firstKey], "action": "replace"])))
        XCTAssertEqual(invalidLegacyAction.status, 404)
        let invalidVerbAction = await router.route(HTTPRequest(
            method: "POST",
            path: "/api/verb/\(verbName)",
            body: try json([
                "collection_id": verbCollection.id.uuidString,
                "identifiers": [firstKey],
                "action": "replace",
            ])))
        XCTAssertEqual(invalidVerbAction.status, 400)
        XCTAssertTrue(store.listCollectionMembers(collectionId: verbCollection.id).isEmpty)
    }

    private func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func object(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
}
