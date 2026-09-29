import Foundation
import ImpressAutomation
import Testing
@testable import PublicationManagerCore

@Suite("Imbib native verb callback")
struct ImbibNativeVerbsTests {
    @Test func manuscriptTemplatesReturnActualCatalogue() async throws {
        let router = HTTPAutomationRouter()
        let result = await router.invokeNativeVerb(method: "list_templates", argsJSON: "{}")
        #expect(result.status == 200)
        let data = Data(result.bodyJson.utf8)
        let templates = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(!templates.isEmpty)
        #expect(templates.allSatisfy { ($0["id"] as? String)?.isEmpty == false })
    }

    @Test func invalidNativeArgumentsRefuseWithoutOpeningAStore() async throws {
        let router = HTTPAutomationRouter()
        let malformed = await router.invokeNativeVerb(method: "get_notes", argsJSON: "{")
        #expect(malformed.status == 400)
        let missing = await router.invokeNativeVerb(
            method: "get_manuscript", argsJSON: #"{"manuscript_id":"not-a-uuid"}"#)
        #expect(missing.status == 400)
        let body = try #require(JSONSerialization.jsonObject(with: Data(missing.bodyJson.utf8)) as? [String: Any])
        #expect(body["code"] as? String == "invalid-args")
    }

    @MainActor
    @Test func recentActivityFiltersMembershipBeforeApplyingLimit() async throws {
        let store = RustStoreAdapter.shared // in-memory under XCTest
        let inside = try #require(store.createLibrary(name: "Recent inside \(UUID())"))
        let outside = try #require(store.createLibrary(name: "Recent outside \(UUID())"))
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let insideID = try #require(store.importBibTeX(
            "@article{Inside\(unique), title={Inside activity}}", libraryId: inside.id).first)
        let outsideID = try #require(store.importBibTeX(
            "@article{Outside\(unique), title={Outside activity}}", libraryId: outside.id).first)
        store.recordRecentView(id: insideID)
        try await Task.sleep(nanoseconds: 10_000_000)
        store.recordRecentView(id: outsideID)

        let router = HTTPAutomationRouter()
        let unfiltered = await router.invokeNativeVerb(
            method: "recent_activity", argsJSON: #"{"limit":1}"#)
        let global = try #require(JSONSerialization.jsonObject(with: Data(unfiltered.bodyJson.utf8)) as? [[String: Any]])
        #expect((global.first?["id"] as? String).flatMap(UUID.init(uuidString:)) == outsideID)

        let filtered = await router.invokeNativeVerb(
            method: "recent_activity",
            argsJSON: "{\"limit\":1,\"parent_id\":\"\(inside.id.uuidString)\"}")
        #expect(filtered.status == 200)
        let papers = try #require(JSONSerialization.jsonObject(with: Data(filtered.bodyJson.utf8)) as? [[String: Any]])
        #expect(papers.count == 1)
        #expect((papers.first?["id"] as? String).flatMap(UUID.init(uuidString:)) == insideID)

        let invalid = await router.invokeNativeVerb(
            method: "recent_activity", argsJSON: #"{"limit":1,"parent_id":"not-a-uuid"}"#)
        #expect(invalid.status == 400)
    }

    @Test func retiredImbibAliasesAreNotRouted() async {
        let router = HTTPAutomationRouter()
        let bibtex = await router.route(HTTPRequest(method: "GET", path: "/api/export",
                                                       queryParams: ["keys": "Key2026"]))
        #expect(bibtex.status == 404)
        let ris = await router.route(HTTPRequest(method: "GET", path: "/api/export",
                                                    queryParams: ["keys": "Key2026", "format": "ris"]))
        #expect(ris.status == 404)
        let retiredPaths: [(String, String)] = [
            ("GET", "/api/search"),
            ("GET", "/api/search/external"),
            ("GET", "/api/papers/Key2026"),
            ("GET", "/api/libraries"),
            ("GET", "/api/collections"),
            ("GET", "/api/collections/\(UUID())/papers"),
            ("GET", "/api/tags"),
            ("POST", "/api/papers/add"),
            ("POST", "/api/papers/resolve"),
            ("POST", "/api/collections"),
            ("POST", "/api/collections/add-papers"),
            ("PUT", "/api/collections/\(UUID())/papers"),
            ("DELETE", "/api/libraries"),
            ("DELETE", "/api/libraries/\(UUID())"),
        ]
        for (method, path) in retiredPaths {
            let result = await router.route(HTTPRequest(method: method, path: path))
            #expect(result.status == 404, "\(method) \(path) should be retired")
        }
        let library = await router.route(HTTPRequest(method: "POST", path: "/api/libraries",
                                                        body: #"{"name":"Retired alias"}"#))
        #expect(library.status == 404)
        let undo = await router.route(HTTPRequest(method: "GET", path: "/api/undo/recent"))
        #expect(undo.status == 404)
        let scix = await router.route(HTTPRequest(method: "GET", path: "/api/scix-libraries"))
        #expect(scix.status == 404)
        let scixMutation = await router.route(HTTPRequest(
            method: "POST", path: "/api/scix-libraries/\(UUID())/papers",
            body: #"{"publication_ids":[]}"#))
        #expect(scixMutation.status == 404)
    }

    @Test func resolverCandidatesRefuseInsteadOfBecomingCleanMiss() throws {
        let ambiguous = HTTPAutomationRouter.nativeResolveIdentifierResult(.json([
            "status": "ok", "via": "external-candidates",
            "candidates": [["title": "Candidate", "identifier": "doi:10.1/example"]]
        ]))
        #expect(ambiguous.status == 409)
        let refusal = try #require(JSONSerialization.jsonObject(with: Data(ambiguous.bodyJson.utf8)) as? [String: Any])
        #expect(refusal["code"] as? String == "ambiguous-identifier")

        let duplicate = HTTPAutomationRouter.nativeResolveIdentifierResult(.json([
            "status": "ok", "via": "duplicate", "duplicates": ["Existing2026"]
        ]))
        #expect(duplicate.status == 409)

        let miss = HTTPAutomationRouter.nativeResolveIdentifierResult(.json([
            "status": "ok", "via": "not-found", "reason": "no match"
        ]))
        #expect(miss.status == 200)
        #expect(miss.bodyJson == "null")

        let found = HTTPAutomationRouter.nativeResolveIdentifierResult(.json([
            "status": "ok", "via": "local-identifier", "paper": ["citeKey": "Found2026"]
        ]))
        #expect(found.status == 200)
        #expect(found.bodyJson == #""Found2026""#)
    }

    @Test func downloadedIDsBecomeCountAndMissingCountRefuses() {
        let downloaded = HTTPAutomationRouter.nativeDownloadPDFResult(.json([
            "status": "ok", "downloaded": ["paper-a", "paper-b"],
            "alreadyHad": ["paper-c"], "failed": [] as [String]
        ]))
        #expect(downloaded.status == 200)
        #expect(downloaded.bodyJson == "2")

        let missing = HTTPAutomationRouter.nativeDownloadPDFResult(.json(["status": "ok"]))
        #expect(missing.status == 500)
    }
}
