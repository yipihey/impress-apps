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

private func requestBodyData(_ request: URLRequest) -> Data {
    if let bytes = request.httpBody { return bytes }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        bytes.append(contentsOf: buffer.prefix(count))
    }
    return bytes
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
            let bodyData = requestBodyData(request)
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
                let arguments = try? JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any]
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
        guard let arguments = try? JSONSerialization.jsonObject(with: requestBodyData(request)) as? [String: Any] else {
            XCTFail("Generated verb request had no JSON argument object")
            return [:]
        }
        return arguments
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
        XCTAssertNil(figure.title)
        XCTAssertEqual(figure.name, "Figure one")
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
            let data = requestBodyData(request)
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
    func testExternalSearchUsesGeneratedVerbAndPreservesImportIdentifier() async throws {
        let bridge = makeBridge { request in
            XCTAssertEqual(request.url?.path, "/api/verb/imbib-app-service_search-sources")
            let body = try self.requestObject(request)
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
            let body = try self.requestObject(request)
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
            let body = try self.requestObject(request)
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
