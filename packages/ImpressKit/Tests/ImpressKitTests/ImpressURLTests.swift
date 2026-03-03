import Testing
import Foundation
@testable import ImpressKit

@Suite("ImpressURL")
struct ImpressURLTests {

    // MARK: - URL construction

    @Test("Simple URL with action only")
    func simpleURL() {
        let impressURL = ImpressURL(app: .imbib, action: "search")
        let url = impressURL.url
        #expect(url != nil)
        #expect(url?.scheme == "imbib")
        #expect(url?.host == "search")
    }

    @Test("URL with resource type and ID")
    func urlWithResource() {
        let impressURL = ImpressURL(app: .imbib, action: "open", resourceType: "paper", resourceID: "Einstein2005")
        let url = impressURL.url
        #expect(url != nil)
        #expect(url?.host == "open")
        #expect(url?.path.contains("paper") == true)
        #expect(url?.path.contains("Einstein2005") == true)
    }

    @Test("URL with query parameters")
    func urlWithParams() {
        let impressURL = ImpressURL(app: .imbib, action: "search", parameters: ["query": "gravity"])
        let url = impressURL.url
        #expect(url != nil)
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let queryValue = components?.queryItems?.first(where: { $0.name == "query" })?.value
        #expect(queryValue == "gravity")
    }

    // MARK: - Parsing

    @Test("Parse valid imbib URL")
    func parseImbib() {
        let url = URL(string: "imbib://open/paper/Einstein2005")!
        let parsed = ImpressURL.parse(url)
        #expect(parsed != nil)
        #expect(parsed?.app == .imbib)
        #expect(parsed?.action == "open")
        #expect(parsed?.resourceType == "paper")
        #expect(parsed?.resourceID == "Einstein2005")
    }

    @Test("Parse URL with query params")
    func parseWithParams() {
        let url = URL(string: "impart://compose?to=alice@example.com&subject=Hello")!
        let parsed = ImpressURL.parse(url)
        #expect(parsed?.app == .impart)
        #expect(parsed?.action == "compose")
        #expect(parsed?.parameters["to"] == "alice@example.com")
        #expect(parsed?.parameters["subject"] == "Hello")
    }

    @Test("Parse unknown scheme returns nil")
    func parseUnknownScheme() {
        let url = URL(string: "https://example.com")!
        #expect(ImpressURL.parse(url) == nil)
    }

    // MARK: - Round-trip

    @Test("Build → URL → parse round-trip preserves data")
    func roundTrip() {
        let original = ImpressURL.openPaper(citeKey: "Hawking1974")
        guard let url = original.url else {
            Issue.record("Failed to build URL")
            return
        }
        let parsed = ImpressURL.parse(url)
        #expect(parsed?.app == original.app)
        #expect(parsed?.action == original.action)
        #expect(parsed?.resourceType == original.resourceType)
        #expect(parsed?.resourceID == original.resourceID)
    }

    // MARK: - Convenience builders

    @Test("openPaper builds correct URL")
    func openPaper() {
        let url = ImpressURL.openPaper(citeKey: "Test2024")
        #expect(url.app == .imbib)
        #expect(url.action == "open")
        #expect(url.resourceType == "paper")
        #expect(url.resourceID == "Test2024")
    }

    @Test("searchPapers builds correct URL with query")
    func searchPapers() {
        let url = ImpressURL.searchPapers(query: "dark matter")
        #expect(url.app == .imbib)
        #expect(url.action == "search")
        #expect(url.parameters["query"] == "dark matter")
    }

    @Test("compose builds correct URL with optional subject")
    func compose() {
        let withSubject = ImpressURL.compose(to: "a@b.com", subject: "Hi")
        #expect(withSubject.parameters["to"] == "a@b.com")
        #expect(withSubject.parameters["subject"] == "Hi")

        let withoutSubject = ImpressURL.compose(to: "a@b.com")
        #expect(withoutSubject.parameters["subject"] == nil)
    }

    @Test("openDocument targets imprint")
    func openDocument() {
        let id = UUID()
        let url = ImpressURL.openDocument(id: id)
        #expect(url.app == .imprint)
        #expect(url.resourceID == id.uuidString)
    }

    @Test("exportFigure includes format parameter")
    func exportFigure() {
        let id = UUID()
        let url = ImpressURL.exportFigure(id: id, format: "svg")
        #expect(url.app == .implore)
        #expect(url.parameters["format"] == "svg")
    }
}
