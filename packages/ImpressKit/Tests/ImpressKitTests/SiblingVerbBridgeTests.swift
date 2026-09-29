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

    func testExternalSearchUsesGeneratedVerbAndPreservesImportIdentifier() async throws {
        let bridge = makeBridge { request in
            XCTAssertEqual(request.url?.path, "/api/verb/imbib-app-service_search-sources")
            let body = try requestObject(request)
            XCTAssertEqual(body["query"] as? String, "dark matter")
            XCTAssertEqual(body["sources"] as? String, "arxiv")
            XCTAssertEqual(body["limit"] as? Int, 10)
            return (200, Data("""
                [{"title":"A paper","identifier":"arXiv:2601.00001","authors":["Doe, Jane"],"year":2026,"venue":"ApJ","doi":"10.1234/example","arxiv_id":"2601.00001","bibcode":"2026ApJ...","abstract_text":"Abstract","source":"arxiv"}]
                """.utf8))
        }

        let results = try await ImbibBridge.searchExternal(
            query: "dark matter", source: "arxiv", limit: 10, using: bridge)
        let paper = try XCTUnwrap(results.first)
        XCTAssertEqual(paper.identifier, "arXiv:2601.00001")
        XCTAssertEqual(paper.abstract, "Abstract")
        XCTAssertEqual(paper.sourceID, "arxiv")
        XCTAssertEqual(paper.authors, "Doe, Jane")
    }

    func testIdentifierImportUsesGeneratedVerbAndPreservesOutcomesAndPaperFields() async throws {
        let library = try XCTUnwrap(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        let collection = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        let bridge = makeBridge { request in
            XCTAssertEqual(request.url?.path, "/api/verb/imbib-library-service_import-identifiers")
            let body = try requestObject(request)
            XCTAssertEqual(body["identifiers"] as? [String], ["10.1234/new", "arXiv:2601.00001"])
            XCTAssertEqual(body["library_id"] as? String, library.uuidString)
            XCTAssertEqual(body["collection_id"] as? String, collection.uuidString)
            XCTAssertEqual(body["download_pdfs"] as? Bool, true)
            return (200, Data("""
                {"added":[{"id":"paper-1","citeKey":"Doe2026","title":"Imported","authors":["Doe, Jane"],"year":2026,"bibtex":"@article{Doe2026}","tags":["reviewed"],"customMetadata":{"source":"crossref"}}],"duplicates":["Existing2025"],"failed":{"unsupported-id":"No provider recognized this identifier"}}
                """.utf8))
        }

        let result = try await ImbibBridge.addPapers(
            identifiers: ["10.1234/new", "arXiv:2601.00001"],
            library: library,
            collection: collection,
            downloadPDFs: true,
            using: bridge)
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.added.first?.bibtex, "@article{Doe2026}")
        guard case .object(let added)? = result.rawAddedRecords.first else {
            return XCTFail("expected the complete imported paper dictionary")
        }
        XCTAssertEqual(added["customMetadata"], .object(["source": .string("crossref")]))
    }

    func testStructuredResolveUsesGeneratedVerbAndPreservesRankedCandidates() async throws {
        let library = try XCTUnwrap(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        let input = ImbibCitationInput(authors: ["Doe, Jane"], title: "A cited paper", year: 2026, doi: "10.1234/cite")
        let bridge = makeBridge { request in
            XCTAssertEqual(request.url?.path, "/api/verb/imbib-app-service_resolve-citation")
            let body = try requestObject(request)
            XCTAssertNil(body["query"] as? String)
            XCTAssertNil(body["bibtex"] as? String)
            XCTAssertEqual(body["library_id"] as? String, library.uuidString)
            XCTAssertEqual(body["download_pdfs"] as? Bool, false)
            let citation = try XCTUnwrap(body["citation"] as? [String: Any])
            XCTAssertNil(citation["rawBibtex"])
            XCTAssertNil(citation["preferredDatabase"])
            XCTAssertEqual(citation["doi"] as? String, "10.1234/cite")
            return (200, Data("""
                {"via":"ads-candidates","candidates":[{"title":"Candidate","authors":["Doe, Jane"],"year":2026,"sourceID":"ads","identifier":"10.1234/candidate","abstract":"Candidate abstract","confidence":0.97,"rankMetadata":{"position":1}}]}
                """.utf8))
        }

        let response = try await ImbibBridge.resolveCitation(
            input, library: library, downloadPDFs: false, using: bridge)
        XCTAssertEqual(response.via, "ads-candidates")
        XCTAssertEqual(response.candidates?.first?.identifier, "10.1234/candidate")
        XCTAssertEqual(response.candidates?.first?.confidence, 0.97)
        guard case .object(let candidate)? = response.rawCandidates?.first else {
            return XCTFail("expected the complete ranked candidate dictionary")
        }
        XCTAssertEqual(candidate["rankMetadata"], .object(["position": .integer(1)]))
    }

    func testResolveResponseRetainsOpenPaperFields() throws {
        let response = try JSONDecoder().decode(
            ImbibResolveResponse.self,
            from: Data("""
                {"via":"local-identifier","paper":{"id":"paper-1","citeKey":"Doe2026","title":"Paper","authors":["Doe, Jane"],"bibtex":"@article{Doe2026}","customMetadata":{"origin":"resolver"}}}
                """.utf8))
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.paper?.bibtex, "@article{Doe2026}")
        guard case .object(let paper)? = response.rawPaper else {
            return XCTFail("expected the complete resolved paper dictionary")
        }
        XCTAssertEqual(paper["customMetadata"], .object(["origin": .string("resolver")]))
    }

    private func makeBridge(
        handler: @escaping (URLRequest) throws -> (Int, Data)
    ) -> SiblingBridge {
        VerbRequestProtocol.respond { request in
            do { return try handler(request) }
            catch { return (500, Data("{}".utf8)) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerbRequestProtocol.self]
        return SiblingBridge(
            session: URLSession(configuration: configuration),
            tokenProvider: { _ in "scratch-token" })
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
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
            data = bytes
        } else {
            throw SiblingBridgeError.invalidResponse
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
