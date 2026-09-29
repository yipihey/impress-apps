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

private func verbArguments(_ request: URLRequest) -> [String: Any]? {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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

    func testImbibContainerBridgePreservesLibraryRowsAndComposesAllCollections() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerbRequestProtocol.self]
        let session = URLSession(configuration: config)
        let librariesJSON = """
        [{"id":"library-a","name":"A","is_default":true,"is_inbox":false,"publication_count":5,"collection_count":2,"can_edit":true},{"id":"library-b","name":"B","is_default":false,"is_inbox":true,"publication_count":3,"collection_count":1,"can_edit":true}]
        """
        VerbRequestProtocol.respond { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scratch-token")
            switch request.url?.path {
            case "/api/verb/imbib-library-service_list-libraries":
                return (200, Data(librariesJSON.utf8))
            case "/api/verb/imbib-library-service_list-collections":
                let arguments = verbArguments(request)
                switch arguments?["library_id"] as? String {
                case "library-a":
                    return (200, Data("""
                    [{"id":"collection-a1","name":"A one","library_id":"library-a","is_smart":false,"publication_count":4},{"id":"collection-a2","name":"A smart","library_id":"library-a","is_smart":true,"publication_count":2}]
                    """.utf8))
                case "library-b":
                    return (200, Data("""
                    [{"id":"collection-b1","name":"B one","library_id":"library-b","is_smart":false,"publication_count":1}]
                    """.utf8))
                default:
                    XCTFail("Unexpected library scope: \(String(describing: arguments?["library_id"]))")
                    return (400, Data())
                }
            default:
                XCTFail("Unexpected request path: \(String(describing: request.url?.path))")
                return (404, Data())
            }
        }
        let bridge = ImbibContainerVerbBridge(
            bridge: SiblingBridge(session: session, tokenProvider: { _ in "scratch-token" }))

        let libraries = try await bridge.listLibraries()
        XCTAssertEqual(libraries.map(\.name), ["A", "B"])
        XCTAssertEqual(libraries.map(\.paperCount), [5, 3])
        XCTAssertEqual(libraries.map(\.collectionCount), [2, 1])
        XCTAssertEqual(libraries.first?.isDefault, true)
        XCTAssertEqual(libraries.last?.isInbox, true)

        let collections = try await bridge.listCollections()
        XCTAssertEqual(collections.map(\.id), ["collection-a1", "collection-a2", "collection-b1"])
        XCTAssertEqual(collections.map(\.libraryID), ["library-a", "library-a", "library-b"])
        XCTAssertEqual(collections.map(\.libraryName), ["A", "A", "B"])
        XCTAssertEqual(collections.map(\.isSmartCollection), [false, true, false])
        XCTAssertEqual(collections.map(\.paperCount), [4, 2, 1])
    }
}
