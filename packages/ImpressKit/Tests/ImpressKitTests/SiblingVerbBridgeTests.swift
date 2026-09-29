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

    func testImprintReadDTOMapsSnakeCaseAndKeepsAbsentLinksAbsent() throws {
        let data = Data(#"{"id":"62000000-0000-4000-8000-000000000002","title":"Methods","format":"typst","authors":["A. Researcher"],"status":"draft","word_count":12,"last_modified":"2026-09-28T11:15:00Z","created_at":"2026-09-20T08:00:00Z","linked_imbib_manuscript_id":null,"linked_imbib_library_id":null}"#.utf8)
        let record = try JSONDecoder().decode(VerbDocumentSummary.self, from: data)
        let listed = DocumentInfo(record: record)
        let content = DocumentContent(record: record, source: "one two\nthree")

        XCTAssertEqual(listed.id, record.id)
        XCTAssertEqual(listed.wordCount, 12)
        XCTAssertEqual(listed.authors, ["A. Researcher"])
        XCTAssertNotNil(listed.lastModified)
        XCTAssertNil(listed.linkedImbibManuscriptId)
        XCTAssertNil(listed.linkedImbibLibraryId)
        XCTAssertEqual(content.wordCount, 3)
        XCTAssertEqual(content.source, "one two\nthree")
        XCTAssertNil(content.linkedImbibManuscriptId)
    }

    func testImprintReadDTOKeepsMissingDatesAbsent() throws {
        let data = Data(#"{"id":"62000000-0000-4000-8000-000000000003","title":"Undated","format":"typst","authors":[],"status":"draft","word_count":0,"last_modified":null,"linked_imbib_manuscript_id":null}"#.utf8)
        let record = try JSONDecoder().decode(VerbDocumentSummary.self, from: data)
        let info = DocumentInfo(record: record)
        XCTAssertNil(info.lastModified)
        XCTAssertNil(info.createdAt)
        XCTAssertNil(info.linkedImbibManuscriptId)
    }

    func testImploreReadDTOPreservesRouteAbsentMetadataAsNil() throws {
        let data = Data(#"{"id":"fig-1","name":"Figure one","dataset_id":"data-1","figure_type":"scatter","width":800,"height":600,"x_column":"time","created_at":"2026-09-28T11:15:00Z","modified_at":null,"tags":[],"folder_id":null}"#.utf8)
        let record = try JSONDecoder().decode(VerbFigureRecord.self, from: data)
        let figure = FigureInfo(record: record)

        XCTAssertEqual(figure.id, "fig-1")
        XCTAssertEqual(figure.title, "Figure one")
        XCTAssertEqual(figure.figureType, "scatter")
        XCTAssertEqual(figure.width, 800)
        XCTAssertEqual(figure.xColumn, "time")
        XCTAssertNotNil(figure.createdAt)
        XCTAssertNil(figure.modifiedAt)
        XCTAssertNil(figure.datasetName)
        XCTAssertNil(figure.format)
        XCTAssertNil(figure.folderId)
        XCTAssertNil(figure.tags)
    }

    func testImpartReadDTOMapsPageAndConversationDetail() throws {
        let data = Data(#"{"count":1,"total":4,"offset":2,"limit":1,"include_archived":false,"query":"results","conversations":[{"id":"5b000000-0000-4000-8000-000000000011","title":"Fixture thread","summary":"summary","message_count":2,"created_at":"2026-09-20T08:00:00Z","updated_at":null,"archived":false,"participants":["human","counsel"],"tags":["analysis"],"parent_conversation_id":null,"last_activity_at":"2026-09-28T11:15:00Z","summary_text":"summary line","messages":[{"id":"m1","sequence":1,"sender_role":"human","sender_id":"researcher","model_used":null,"content_markdown":"Compare the results.","sent_at":"2026-09-28T11:15:00Z","token_count":4,"processing_duration_ms":null,"mentioned_artifact_uris":["impress://paper/key"]}],"statistics":{"message_count":2,"human_message_count":1,"counsel_message_count":1,"artifact_count":1,"paper_count":1,"repository_count":0,"total_tokens":4,"duration":1.5,"branch_count":0}}]}"#.utf8)
        let page = try JSONDecoder().decode(VerbConversationList.self, from: data)
        let mappedPage = ConversationListInfo(page: page)
        let detail = ConversationDetailInfo(record: try XCTUnwrap(page.conversations.first))

        XCTAssertEqual(mappedPage.count, 1)
        XCTAssertEqual(mappedPage.total, 4)
        XCTAssertEqual(mappedPage.offset, 2)
        XCTAssertEqual(mappedPage.limit, 1)
        XCTAssertEqual(mappedPage.query, "results")
        XCTAssertEqual(mappedPage.conversations.first?.subject, "Fixture thread")
        XCTAssertNil(mappedPage.conversations.first?.updatedAt)
        XCTAssertNil(mappedPage.conversations.first?.parentConversationId)
        XCTAssertEqual(detail.messages.first?.contentMarkdown, "Compare the results.")
        XCTAssertEqual(detail.messages.first?.mentionedArtifactUris, ["impress://paper/key"])
        XCTAssertEqual(detail.statistics?.paperCount, 1)
        XCTAssertEqual(detail.statistics?.totalTokens, 4)
    }

    func testConversationPageReadUsesCanonicalVerbAndPreservesArguments() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerbRequestProtocol.self]
        let bridge = SiblingBridge(
            session: URLSession(configuration: config), tokenProvider: { _ in "scratch-token" })
        VerbRequestProtocol.respond { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/verb/impart-service_list-conversations")
            let data = request.httpBody ?? Data()
            let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(args?["limit"] as? Int, 13)
            XCTAssertEqual(args?["offset"] as? Int, 7)
            XCTAssertEqual(args?["include_archived"] as? Bool, false)
            XCTAssertEqual(args?["query"] as? String, "climate")
            return (200, Data(#"{"conversations":[],"count":0,"total":0,"offset":7,"limit":13,"include_archived":false,"query":"climate"}"#.utf8))
        }
        let page: VerbConversationList = try await bridge.callVerb(
            "impart-service_list-conversations", on: .impart,
            arguments: ["limit": 13, "include_archived": false, "offset": 7, "query": "climate"])
        let mapped = ConversationListInfo(page: page)
        XCTAssertEqual(mapped.status, "ok")
        XCTAssertEqual(mapped.offset, 7)
        XCTAssertEqual(mapped.limit, 13)
        XCTAssertEqual(mapped.query, "climate")
    }
}
