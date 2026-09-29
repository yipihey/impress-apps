import Foundation
import XCTest
@testable import ImpressKit

private final class FigureRequestProtocol: URLProtocol {
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

final class ImploreFigureVerbBridgeTests: XCTestCase {
    func testBinaryExportUsesGeneratedVerbAndMapsBytesAndMetadata() async throws {
        let bridge = makeBridge()
        FigureRequestProtocol.respond { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/verb/implore-service_export-figure-data")
            let args = Self.arguments(request)
            XCTAssertEqual(args["figure_id"] as? String, "figure-1")
            XCTAssertEqual(args["format"] as? String, "svg")
            XCTAssertEqual(args["width"] as? Double, 640.5)
            XCTAssertEqual(args["height"] as? Double, 320.25)
            XCTAssertEqual(args["scale"] as? Double, 1.5)
            XCTAssertEqual(args["view_state"] as? String, #"{"type":"line"}"#)
            return (200, Data(#"{"path":"/scratch/figure-1.svg","sha256":"abc123","mime_type":"image/svg+xml","data":[60,115,118,103,62]}"#.utf8))
        }

        let result = try await ImploreBridge.exportFigureResult(
            id: "figure-1", format: "svg", width: 640.5, height: 320.25,
            scale: 1.5, viewState: #"{"type":"line"}"#, using: bridge)
        XCTAssertEqual(result.data, Data("<svg>".utf8))
        XCTAssertEqual(result.path, "/scratch/figure-1.svg")
        XCTAssertEqual(result.sha256, "abc123")
        XCTAssertEqual(result.mimeType, "image/svg+xml")
        XCTAssertEqual(result.byteCount, 5)
    }

    func testExportCannotReportEmptyRenderAsSuccess() async throws {
        let bridge = makeBridge()
        FigureRequestProtocol.respond { _ in
            (200, Data(#"{"path":"","sha256":"","mime_type":"","data":[]}"#.utf8))
        }
        do {
            _ = try await ImploreBridge.exportFigureResult(
                id: "figure-missing", format: "png", width: nil, height: nil,
                scale: nil, viewState: nil, using: bridge)
            XCTFail("empty renderer output must not be reported as an export")
        } catch SiblingBridgeError.invalidResponse {
            // An empty/refusal response is not a successful binary render.
        }
    }

    private func makeBridge() -> SiblingBridge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FigureRequestProtocol.self]
        return SiblingBridge(
            session: URLSession(configuration: config), tokenProvider: { _ in "scratch-token" })
    }

    private static func arguments(_ request: URLRequest) -> [String: Any] {
        let bodyData: Data
        if let body = request.httpBody {
            bodyData = body
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
        return (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
    }
}
