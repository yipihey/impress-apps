import Foundation
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
}
