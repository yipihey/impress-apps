import Foundation
import XCTest
@testable import ImpressKit

private final class VerbRequestProtocol: URLProtocol {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) -> (Int, Data))?
    }
    private static let state = State()

    static func respond(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        state.lock.withLock { state.handler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.handler }
        guard let handler, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: SiblingBridgeError.invalidResponse)
            return
        }
        let (status, data) = handler(request)
        let actual = HTTPURLResponse(url: url, statusCode: status,
                                     httpVersion: nil, headerFields: nil) ?? response
        client?.urlProtocol(self, didReceive: actual, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SiblingVerbBridgeTests: XCTestCase {
    func testCanonicalVerbCarriesArgumentsAndLoopbackBearer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerbRequestProtocol.self]
        let session = URLSession(configuration: config)
        VerbRequestProtocol.respond { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/verb/imbib-library-service_export-bibtex")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scratch-token")
            let bodyData: Data
            if let bytes = request.httpBody {
                bodyData = bytes
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                bodyData = bytes
            } else {
                bodyData = Data()
            }
            let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            XCTAssertEqual(body?["ids"] as? [String], ["Key2026"])
            return (200, Data("\"@article{Key2026}\"".utf8))
        }
        let bridge = SiblingBridge(session: session, tokenProvider: { _ in "scratch-token" })
        let answer: String = try await bridge.callVerb(
            "imbib-library-service_export-bibtex", on: .imbib,
            arguments: ["ids": ["Key2026"]])
        XCTAssertEqual(answer, "@article{Key2026}")
    }

    func testImbibSearchUsesGeneratedFiltersAndHydratesRichPaperShape() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerbRequestProtocol.self]
        let bridge = SiblingBridge(
            session: URLSession(configuration: config),
            tokenProvider: { _ in "scratch-token" })
        VerbRequestProtocol.respond { request in
            guard let name = request.url?.lastPathComponent else { return (500, Data()) }
            let args = Self.arguments(request)
            switch name {
            case "imbib-library-service_search-publications":
                XCTAssertEqual(args["query"] as? String, "quantum")
                XCTAssertEqual(args["limit"] as? Int, 2)
                XCTAssertEqual(args["offset"] as? Int, 17)
                let filters = args["filters"] as? [String: Any]
                XCTAssertEqual(filters?["read"] as? Bool, true)
                XCTAssertEqual(filters?["collection"] as? String, "collection-id")
                XCTAssertEqual(filters?["library"] as? String, "library-id")
                XCTAssertEqual(filters?["tags"] as? [String], ["topic/one", "methods"])
                XCTAssertEqual(filters?["flag"] as? String, "red")
                XCTAssertEqual(filters?["added_after"] as? String, "2026-01-01T00:00:00Z")
                XCTAssertEqual(filters?["added_before"] as? String, "2026-12-31T23:59:59Z")
                return (200, Data(#"""
                [
                    {"id":"pub-1","cite_key":"First2026","title":"First title","authors":"Doe, Jane; Roe, John","year":2026,"venue":"Journal A","doi":"10.1/first","arxiv_id":"2601.00001","is_read":true,"is_starred":false,"has_pdf":true,"tags":["topic/one"]},
                    {"id":"pub-2","cite_key":"Second2026","title":"Second title","authors":"Smith, Alex","year":2025,"venue":null,"doi":null,"arxiv_id":null,"is_read":false,"is_starred":true,"has_pdf":false,"tags":[]}
                ]
                """#.utf8))
            case "imbib-library-service_get-publication-detail":
                let id = args["id"] as? String ?? ""
                let fields = id == "pub-1"
                    ? #"{"abstract":"First abstract","bibcode":"2026JrnA..1D","pmid":"12345","year":"2026"}"#
                    : #"{"abstract":"Second abstract","bibcode":"2025JrnB..2S","pmid":"67890","journal":"Journal B"}"#
                let key = id == "pub-1" ? "First2026" : "Second2026"
                return (200, Data("{\"id\":\"\(id)\",\"cite_key\":\"\(key)\",\"entry_type\":\"article\",\"fields\":\(fields)}".utf8))
            case "imbib-library-service_export-bibtex":
                let id = (args["ids"] as? [String])?.first
                let bib = id == "pub-1" ? "@article{First2026}" : "@article{Second2026}"
                return (200, Data("\"\(bib)\"".utf8))
            default:
                XCTFail("Unexpected generated verb: \(name)")
                return (500, Data())
            }
        }

        let papers = try await ImbibBridge.searchLibrary(
            query: "quantum",
            limit: 2,
            offset: 17,
            filters: ImbibPublicationSearchFilters(
                read: true,
                collection: "collection-id",
                library: "library-id",
                tags: ["topic/one", "methods"],
                flag: "red",
                addedAfter: "2026-01-01T00:00:00Z",
                addedBefore: "2026-12-31T23:59:59Z"),
            bridge: bridge)
        XCTAssertEqual(papers.map(\.citeKey), ["First2026", "Second2026"], "parallel hydration must preserve search order")
        XCTAssertEqual(papers[0].authors, "Doe, Jane; Roe, John")
        XCTAssertEqual(papers[0].abstract, "First abstract")
        XCTAssertEqual(papers[0].bibcode, "2026JrnA..1D")
        XCTAssertEqual(papers[0].pmid, "12345")
        XCTAssertEqual(papers[0].bibtex, "@article{First2026}")
        XCTAssertEqual(papers[0].hasPDF, true)
        XCTAssertEqual(papers[0].tags, ["topic/one"])
        XCTAssertEqual(papers[1].venue, "Journal B")
        XCTAssertEqual(papers[0].arxivID, "2601.00001")
        XCTAssertEqual(papers[1].bibtex, "@article{Second2026}")
    }

    func testImbibCiteKeyLookupIsExactAndHydratesOnlyTheResolvedPaper() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerbRequestProtocol.self]
        let bridge = SiblingBridge(
            session: URLSession(configuration: config),
            tokenProvider: { _ in "scratch-token" })
        VerbRequestProtocol.respond { request in
            guard let name = request.url?.lastPathComponent else { return (500, Data()) }
            let args = Self.arguments(request)
            switch name {
            case "imbib-search-service_find-by-cite-key":
                XCTAssertTrue(args["library_id"] is NSNull)
                let citeKey = args["cite_key"] as? String
                XCTAssertTrue(["Exact2026", "Absent2026"].contains(citeKey ?? ""))
                if citeKey == "Absent2026" { return (200, Data("null".utf8)) }
                return (200, Data(#"{"id":"pub-exact","cite_key":"Exact2026","title":"Exact","authors":"Doe, Jane","year":2026,"is_read":false,"is_starred":false,"has_pdf":false,"tags":[]}"#.utf8))
            case "imbib-library-service_get-publication-detail":
                XCTAssertEqual(args["id"] as? String, "pub-exact")
                return (200, Data(#"{"fields":{"abstract":"Resolved by exact key"}}"#.utf8))
            case "imbib-library-service_export-bibtex":
                XCTAssertEqual(args["ids"] as? [String], ["pub-exact"])
                return (200, Data(#""@article{Exact2026}""#.utf8))
            default:
                XCTFail("Unexpected generated verb: \(name)")
                return (500, Data())
            }
        }

        let paper = try await ImbibBridge.getPaper(citeKey: "Exact2026", bridge: bridge)
        XCTAssertEqual(paper?.id, "pub-exact")
        XCTAssertEqual(paper?.abstract, "Resolved by exact key")
        XCTAssertEqual(paper?.bibtex, "@article{Exact2026}")
        let missing = try await ImbibBridge.getPaper(citeKey: "Absent2026", bridge: bridge)
        XCTAssertNil(missing)
    }

    func testImbibRISExportUsesGeneratedVerbAndEmptyInputShortCircuits() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerbRequestProtocol.self]
        let bridge = SiblingBridge(
            session: URLSession(configuration: config),
            tokenProvider: { _ in "scratch-token" })
        VerbRequestProtocol.respond { request in
            XCTAssertEqual(request.url?.lastPathComponent, "imbib-library-service_export-ris")
            XCTAssertEqual(Self.arguments(request)["ids"] as? [String], ["First2026", "Second2026"])
            return (200, Data(#""TY  - JOUR\nID  - First2026\nER  - ""#.utf8))
        }

        let ris = try await ImbibBridge.exportRIS(
            citeKeys: ["First2026", "Second2026"], bridge: bridge)
        XCTAssertEqual(ris, "TY  - JOUR\nID  - First2026\nER  - ")
        let emptyRIS = try await ImbibBridge.exportRIS(citeKeys: [], bridge: bridge)
        XCTAssertEqual(emptyRIS, "")
    }

    private static func arguments(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        }
        guard let data,
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Generated verb request had no JSON argument object")
            return [:]
        }
        return arguments
    }
}
