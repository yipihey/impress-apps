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

    func testCreateFigureForwardsAllRenderConfigurationAndMapsArtifact() async throws {
        let bridge = makeBridge()
        FigureRequestProtocol.respond { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/verb/implore-service_create-figure")
            let args = Self.arguments(request)
            XCTAssertEqual(args["dataset_id"] as? String, "inline")
            XCTAssertEqual(args["plot_type"] as? String, "scatter")
            XCTAssertEqual(args["x"] as? String, "time")
            XCTAssertEqual(args["y"] as? String, "flux")
            XCTAssertEqual(args["width"] as? Int, 640)
            XCTAssertEqual(args["height"] as? Int, 480)
            XCTAssertEqual(args["title"] as? String, "Flux")
            XCTAssertEqual(args["color_column"] as? String, "group")
            XCTAssertEqual(args["view_state"] as? String, #"{"legend":true}"#)
            let series = args["series"] as? [[String: Any]]
            XCTAssertEqual(series?.first?["label"] as? String, "run")
            XCTAssertTrue(args["spec"] is NSNull)
            return (200, Data(#"{"ok":true,"id":"figure-2","name":"Flux plot","dataset_id":"inline","figure_type":"scatter","title":"Flux","width":640,"height":480,"x_column":"time","y_column":"flux","color_column":"group","created_at":"2026-09-29T10:00:00Z","modified_at":"2026-09-29T10:00:00Z","artifact":{"data_hash":"deadbeef","format":"png","width":640,"height":480},"drawn_from":"series"}"#.utf8))
        }

        let result = try await ImploreBridge.createFigure(
            datasetID: "inline", plotType: "scatter", x: "time", y: "flux",
            name: "Flux plot", series: Data(#"[{"label":"run","x":[1,2],"y":[3,4]}]"#.utf8),
            spec: nil, width: 640, height: 480,
            title: "Flux", colorColumn: "group", viewState: #"{"legend":true}"#,
            using: bridge)
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.figure?.id, "figure-2")
        XCTAssertEqual(result.figure?.figureType, "scatter")
        XCTAssertEqual(result.artifact?.dataHash, "deadbeef")
        XCTAssertEqual(result.artifact?.width, 640)
        XCTAssertEqual(result.drawnFrom, "series")
    }

    func testUpdateRefusalAndDeleteFalseRemainStructured() async throws {
        let bridge = makeBridge()
        FigureRequestProtocol.respond { request in
            XCTAssertEqual(request.url?.path, "/api/verb/implore-service_update-figure")
            return (200, Data(#"{"ok":false,"error":"Figure not updated: render failed"}"#.utf8))
        }
        let refused = try await ImploreBridge.updateFigure(
            id: "figure-3", name: nil, plotType: nil, x: nil, y: nil, colorColumn: nil,
            title: "Updated", width: nil, height: nil, series: nil, spec: nil, svg: nil,
            viewState: nil, using: bridge)
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error, "Figure not updated: render failed")
        XCTAssertNil(refused.figure)

        FigureRequestProtocol.respond { request in
            XCTAssertEqual(request.url?.path, "/api/verb/implore-service_delete-figure")
            XCTAssertEqual(Self.arguments(request)["figure_id"] as? String, "figure-3")
            return (200, Data("false".utf8))
        }
        let deleted = try await ImploreBridge.deleteFigure(id: "figure-3", using: bridge)
        XCTAssertFalse(deleted)
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
            // Structured empty/refusal response is not a successful binary render.
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
