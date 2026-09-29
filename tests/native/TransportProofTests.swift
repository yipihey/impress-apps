#if os(macOS)
import Foundation
import ImpressAutomation
import ImpressKit
import ImpressRustCore
import PublicationManagerCore
import XCTest

/// Opt-in hosted proof of the native /api/verb transport in each app. Every
/// write is confined to the test host's PID-owned workspace.
@MainActor
final class TransportProofTests: XCTestCase {
    private var calls: [[String: Any]] = []
    private var callEvidenceURL: URL?
    private let traceID = UUID().uuidString
    private let parentCallID = UUID().uuidString

    func testNativeTransportPersistsAndReadsBack() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["IMPRESS_P5B_TRANSPORT_PROOF"] == "1" else {
            throw XCTSkip("Run scripts/prove-app-transport.py with an isolated hosted build")
        }
        let app = try XCTUnwrap(env["IMPRESS_P5B_APP"])
        let port = try XCTUnwrap(env["IMPRESS_P5B_PORT"].flatMap(UInt16.init))
        let output = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_P5B_OUTPUT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let proofRoot = URL(fileURLWithPath: try XCTUnwrap(env["IMPRESS_P5B_ROOT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .resolvingSymlinksInPath()
        let pid = ProcessInfo.processInfo.processIdentifier
        let root = SharedContainer.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let expectedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-unit-tests-\(pid)")
            .standardizedFileURL.resolvingSymlinksInPath()
        let db = SharedWorkspace.databaseURL.standardizedFileURL.resolvingSymlinksInPath()
        let tokenPath = LoopbackToken.path(port: port)

        try require(ImpressRuntime.isUnitTestProcess && ImpressRuntime.isUITestingProcess,
                    "test launch flags")
        try require(Bundle.main.bundleIdentifier == "com.impress.p5bproof.\(app)",
                    "distinct proof bundle")
        try require(root == expectedRoot, "PID-owned container")
        try require(db == root.appendingPathComponent("workspace/impress.sqlite"),
                    "PID-owned store")
        try require(RustStoreAdapter.shared.databaseLocation == SharedWorkspace.databasePath,
                    "native Rust store agrees")
        try require(tokenPath.hasPrefix(root.path + "/"), "PID-owned bearer path")
        try require(UserDefaults.standard.integer(forKey: "httpAutomationPort") == Int(port),
                    "owned HTTP port")
        try require(env["IMPRESS_DEVICE_ID"]?.hasPrefix("codex-p5b-") == true,
                    "owned device")
        try require(proofRoot.path.hasPrefix(temporaryRoot.path + "/impress-p5b-transport-"),
                    "owned proof root")
        try require(output.path.hasPrefix(proofRoot.path + "/"), "owned output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        callEvidenceURL = output.appendingPathComponent("calls.json")

        var token: String?
        for _ in 0..<100 {
            if let candidate = try? String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
                token = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let bearer = try XCTUnwrap(token, "Isolated HTTP server did not publish a bearer")
        let base = "http://127.0.0.1:\(port)"

        // The kit route must be available in every shell, independent of its
        // app-specific inventory. Fractions distinguish the actual series
        // computation from an empty or canned success.
        let series = try await verb(base, bearer, "surface-demo-service_series",
                                    ["freq": 1.5, "n": 4])
        let seriesValue = try object(series, "kit series")
        try require(seriesValue["x"] as? [Double] == [0, 0.25, 0.5, 0.75],
                    "kit series returned real coordinates")
        try require((seriesValue["values"] as? [Any])?.count == 4,
                    "kit series returned four values")

        switch app {
        case "imbib": try await proveImbib(base, bearer)
        case "imprint": try await proveImprint(base, bearer)
        case "impart": try await proveImpart(base, bearer)
        case "implore": try await proveImplore(base, bearer)
        case "impel": break // kit series is the app-independent transport proof
        default: throw failure("unknown proof app: \(app)")
        }
        let audit = try await verifyNativeAudit(app: app, databasePath: db.path)
        let logs = try await request(base, bearer, "/api/logs?limit=200", nil)
        try require(logs.status == 200, "logs HTTP \(logs.status): \(logs.value)")
        let evidence: [String: Any] = [
            "app": app, "pid": pid, "port": Int(port), "store": db.path,
            "calls": calls, "audit": audit, "logs": logs.value,
            "traceparent": traceID, "parent_call": parentCallID,
        ]
        let data = try JSONSerialization.data(withJSONObject: evidence,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("proof.json"), options: .atomic)
    }

    private func proveImbib(_ base: String, _ bearer: String) async throws {
        let status = try object(try await verb(base, bearer, "imbib-app-service_status", [:]),
                                "imbib status")
        try require(status["running"] as? Bool == true, "imbib app status is running")
        let title = "P5b transport library \(UUID().uuidString)"
        let library = try object(try await verb(base, bearer,
            "imbib-library-service_create-library", ["name": title]), "created library")
        let libraryID = try XCTUnwrap(library["id"] as? String)
        try require(UUID(uuidString: libraryID) != nil && library["name"] as? String == title,
                    "created library has its persisted identity and title")
        for suffix in ["one", "two"] {
            _ = try object(try await verb(base, bearer, "imbib-library-service_create-collection", [
                "name": "P5c2 " + suffix + " " + UUID().uuidString,
                "library_id": libraryID, "is_smart": false, "query": NSNull()
            ]), "created library collection")
        }
        let libraries = try array(try await verb(base, bearer,
            "imbib-library-service_list-libraries", [:]), "library readback")
        let generatedRow = try XCTUnwrap(libraries
            .compactMap { $0 as? [String: Any] }
            .first { $0["id"] as? String == libraryID })
        try require(generatedRow["collection_count"] as? Int == 2 &&
                    generatedRow["can_edit"] as? Bool == true,
                    "generated list reports stored collection count and local editability")
        let legacyEnvelope = try object(try await request(base, bearer, "/api/libraries", nil),
                                        "legacy library list")
        let legacyRows = try XCTUnwrap(legacyEnvelope["libraries"] as? [[String: Any]])
        let legacyRow = try XCTUnwrap(legacyRows.first {
            ($0["id"] as? String)?.lowercased() == libraryID.lowercased()
        })
        try require(legacyRow["collectionCount"] as? Int == generatedRow["collection_count"] as? Int &&
                    legacyRow["canEdit"] as? Bool == generatedRow["can_edit"] as? Bool,
                    "legacy HTTP and generated library metadata agree")
        let key = "p5bproof" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let paperTitle = "P5b Transport Paper"
        let bibtex = "@article{\(key), title={\(paperTitle)}, author={Doe, Jane and Roe, John}, year={2026}, journal={Transport Journal}, volume={7}, number={2}, pages={10-20}, doi={10.5555/p5c6-ris}, abstract={RIS transport fixture}, keywords={alpha, beta}, issn={9876-5432}}"
        let imported = try array(try await verb(base, bearer,
            "imbib-library-service_import-bibtex",
            ["bibtex": bibtex, "library_id": libraryID]), "BibTeX import")
        let paperID = try XCTUnwrap(imported.first as? String)
        try require(UUID(uuidString: paperID) != nil, "BibTeX import returned a paper UUID")
        let paper = try object(try await verb(base, bearer,
            "imbib-library-service_get-publication", ["id": paperID]), "paper readback")
        try require(paper["id"] as? String == paperID &&
                    (paper["title"] as? String)?.contains(paperTitle) == true,
                    "BibTeX paper reads back with its title")
        let ris = try string(try await verb(base, bearer,
            "imbib-library-service_export-ris", ["ids": [key]]), "generated RIS export")
        let legacyRIS = try object(try await request(
            base, bearer, "/api/export?keys=\(key)&format=ris", nil), "legacy RIS export")
        try require(legacyRIS["content"] as? String == ris &&
                    legacyRIS["paperCount"] as? Int == 1,
                    "generated RIS bytes match the legacy export route")
        let exported = try string(try await verb(base, bearer,
            "imbib-library-service_export-bibtex", ["ids": [paperID]]), "BibTeX export")
        try require(exported.contains(paperTitle), "imported BibTeX exports from the store")

        // The generated search contract and retained legacy route must select
        // the same scratch papers, in the same order, with container/read
        // filters applied before limit/offset.
        let searchLibrary = try object(try await verb(base, bearer,
            "imbib-library-service_create-library",
            ["name": "P5c9 search \(UUID().uuidString)"]), "search library")
        let searchLibraryID = try XCTUnwrap(searchLibrary["id"] as? String)
        let searchCollection = try object(try await verb(base, bearer,
            "imbib-library-service_create-collection",
            ["name": "P5c9 collection", "library_id": searchLibraryID,
             "is_smart": false, "query": NSNull()]), "search collection")
        let searchCollectionID = try XCTUnwrap(searchCollection["id"] as? String)
        let searchKeys = ["p5c9alpha" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                          "p5c9beta" + UUID().uuidString.replacingOccurrences(of: "-", with: "")]
        let searchBibTeX = """
        @article{\(searchKeys[0]), title={P5c9SearchAlpha}, author={Doe, Jane}, year={2026}}
        @article{\(searchKeys[1]), title={P5c9SearchBeta}, author={Roe, John}, year={2026}}
        """
        let searchPaperIDs = try array(try await verb(base, bearer,
            "imbib-library-service_import-bibtex",
            ["bibtex": searchBibTeX, "library_id": searchLibraryID]), "search imports")
            .compactMap { $0 as? String }
        try require(searchPaperIDs.count == 2, "search fixture contains two papers")
        _ = try await verb(base, bearer, "imbib-library-service_add-to-collection",
                           ["publication_ids": [searchPaperIDs[0]],
                            "collection_id": searchCollectionID])
        _ = try await verb(base, bearer, "imbib-library-service_set-read",
                           ["ids": [searchPaperIDs[0]], "read": true])

        let libraryArgs: [String: Any] = [
            "query": "P5c9Search", "limit": 10, "offset": 0,
            "filters": ["library": searchLibraryID, "read": true],
        ]
        let generatedLibraryRows = try array(try await verb(base, bearer,
            "imbib-library-service_search-publications", libraryArgs), "filtered search verb")
        let legacyLibrary = try await request(base, bearer,
            "/api/search?q=P5c9Search&limit=10&offset=0&read=true&library=\(searchLibraryID)", nil)
        try require(legacyLibrary.status == 200, "filtered legacy search HTTP \(legacyLibrary.status)")
        let legacyLibraryRows = try array(object(legacyLibrary, "filtered legacy search")["papers"] ?? NSNull(),
                                         "filtered legacy papers")
        try require(searchResultIDs(generatedLibraryRows) == searchResultIDs(legacyLibraryRows),
                    "library and read filters match between generated and legacy search")
        try require(searchResultIDs(generatedLibraryRows) == [searchPaperIDs[0]],
                    "library/read filters select only the read fixture paper")

        let collectionArgs: [String: Any] = [
            "query": "", "limit": 10, "offset": 0,
            "filters": ["collection": searchCollectionID],
        ]
        let generatedCollectionRows = try array(try await verb(base, bearer,
            "imbib-library-service_search-publications", collectionArgs), "collection search verb")
        let legacyCollection = try await request(base, bearer,
            "/api/search?q=&limit=10&offset=0&collection=\(searchCollectionID)", nil)
        try require(legacyCollection.status == 200,
                    "collection legacy search HTTP \(legacyCollection.status)")
        let legacyCollectionRows = try array(object(legacyCollection, "collection legacy search")["papers"] ?? NSNull(),
                                             "collection legacy papers")
        try require(searchResultIDs(generatedCollectionRows) == searchResultIDs(legacyCollectionRows),
                    "empty-query collection selection matches between generated and legacy search")
        try require(searchResultIDs(generatedCollectionRows) == [searchPaperIDs[0]],
                    "empty-query collection search selects its exact member")

        let offsetArgs: [String: Any] = [
            "query": "P5c9Search", "limit": 1, "offset": 1,
            "filters": ["library": searchLibraryID],
        ]
        let generatedOffsetRows = try array(try await verb(base, bearer,
            "imbib-library-service_search-publications", offsetArgs), "offset search verb")
        let legacyOffset = try await request(base, bearer,
            "/api/search?q=P5c9Search&limit=1&offset=1&library=\(searchLibraryID)", nil)
        try require(legacyOffset.status == 200, "offset legacy search HTTP \(legacyOffset.status)")
        let legacyOffsetRows = try array(object(legacyOffset, "offset legacy search")["papers"] ?? NSNull(),
                                         "offset legacy papers")
        try require(searchResultIDs(generatedOffsetRows) == searchResultIDs(legacyOffsetRows),
                    "offset is applied after the same library filter")
        let future = "2999-01-01T00:00:00.000Z"
        let generatedFuture = try array(try await verb(base, bearer,
            "imbib-library-service_search-publications",
            ["query": "P5c9Search", "limit": 10, "filters": ["added_after": future]]),
            "fractional date search")
        let legacyFuture = try await request(base, bearer,
            "/api/search?q=P5c9Search&addedAfter=\(future)", nil)
        try require(legacyFuture.status == 200, "fractional date HTTP succeeded")
        let legacyFutureRows = try array(object(legacyFuture, "fractional date HTTP")["papers"] ?? NSNull(),
                                         "fractional date papers")
        try require(generatedFuture.isEmpty && legacyFutureRows.isEmpty,
                    "both transports apply fractional timestamp bounds")
        let legacyResolution = try await request(base, bearer, "/api/papers/resolve", [
            "query": key, "library": libraryID, "download_pdfs": false
        ])
        let legacyResolutionBody = try object(legacyResolution, "legacy local citation resolution")
        let generatedResolution = try await verb(base, bearer,
            "imbib-app-service_resolve-citation", [
                "query": key, "library_id": libraryID, "download_pdfs": false
            ])
        let generatedResolutionBody = try object(generatedResolution, "generated local citation resolution")
        let legacyResolvedPaper = try XCTUnwrap(legacyResolutionBody["paper"] as? [String: Any])
        let generatedResolvedPaper = try XCTUnwrap(generatedResolutionBody["paper"] as? [String: Any])
        let legacyVia = try XCTUnwrap(legacyResolutionBody["via"] as? String)
        let generatedVia = try XCTUnwrap(generatedResolutionBody["via"] as? String)
        try require(legacyVia == "local-search" && generatedVia == legacyVia,
                    "native citation resolution preserves the legacy local-search branch")
        try require(legacyResolvedPaper["id"] as? String == generatedResolvedPaper["id"] as? String &&
                    legacyResolvedPaper["cite_key"] as? String == key &&
                    generatedResolvedPaper["cite_key"] as? String == key &&
                    legacyResolvedPaper["title"] as? String == generatedResolvedPaper["title"] as? String,
                    "native citation resolution returns the same saved paper as HTTP")

        let legacyMissing = try await request(base, bearer, "/api/papers/resolve", [
            "download_pdfs": false
        ])
        let generatedMissing = try await request(base, bearer,
            "/api/verb/imbib-app-service_resolve-citation", ["download_pdfs": false])
        try require(legacyMissing.status == 400 && generatedMissing.status == 400,
                    "both citation surfaces refuse missing input")
        let legacyError = try objectWithoutSuccessCheck(legacyMissing, "legacy missing citation error")
        let generatedError = try objectWithoutSuccessCheck(generatedMissing, "generated missing citation error")
        try require((legacyError["error"] as? String)?.contains("Provide at least") == true &&
                    (generatedError["message"] as? String)?.contains("Provide at least") == true,
                    "both surfaces explain the missing citation input")

        let tagRoot = "p5c14-" + UUID().uuidString.lowercased()
        let tagChild = tagRoot + "/nested"
        _ = try object(try await verb(base, bearer, "imbib-tags-service_create-tag", [
            "path": tagRoot, "color_light": NSNull(), "color_dark": NSNull()
        ]), "create tag parent")
        _ = try object(try await verb(base, bearer, "imbib-tags-service_create-tag", [
            "path": tagChild, "color_light": NSNull(), "color_dark": NSNull()
        ]), "create nested tag")
        _ = try object(try await verb(base, bearer, "imbib-tags-service_add-tag", [
            "ids": [paperID], "tag_path": tagChild
        ]), "assign nested tag")
        let generatedTags = try array(try await verb(base, bearer,
            "imbib-tags-service_list-tags-with-counts", [
                "prefix": tagRoot.uppercased(), "limit": 10
            ]), "generated hierarchical tag counts")
            .compactMap { $0 as? [String: Any] }
        let legacyTagEnvelope = try object(try await request(base, bearer,
            "/api/tags?prefix=\(tagRoot.uppercased())&limit=10", nil),
            "legacy hierarchical tag counts")
        let legacyTags = try XCTUnwrap(legacyTagEnvelope["tags"] as? [[String: Any]])
        try require(generatedTags.count == 2 && legacyTags.count == 2,
                    "prefix filtering returns only the parent and nested tag")
        for path in [tagRoot, tagChild] {
            let generatedTag = try XCTUnwrap(generatedTags.first { $0["path"] as? String == path })
            let legacyTag = try XCTUnwrap(legacyTags.first { $0["canonicalPath"] as? String == path })
            let parent = path == tagRoot ? nil : tagRoot
            try require(generatedTag["id"] as? String == path &&
                        legacyTag["id"] as? String == path &&
                        generatedTag["parent_path"] as? String == parent &&
                        legacyTag["parentPath"] as? String == parent &&
                        generatedTag["publication_count"] as? Int == 1 &&
                        legacyTag["publicationCount"] as? Int == 1 &&
                        legacyTag["useCount"] as? Int == 1,
                        "stable path identity, hierarchy and descendant count agree for \(path)")
        }
        let generatedLimited = try array(try await verb(base, bearer,
            "imbib-tags-service_list-tags-with-counts", [
                "prefix": tagRoot.uppercased(), "limit": 1
            ]), "generated limited tag counts")
        let legacyLimited = try await request(base, bearer,
            "/api/tags?prefix=\(tagRoot.uppercased())&limit=1", nil)
        let legacyLimitedTags = try XCTUnwrap(
            (legacyLimited.value as? [String: Any])?["tags"] as? [[String: Any]])
        let generatedLimitedPath = try XCTUnwrap(
            (generatedLimited.first as? [String: Any])?["path"] as? String)
        let legacyLimitedPath = try XCTUnwrap(legacyLimitedTags.first?["canonicalPath"] as? String)
        try require(generatedLimited.count == 1 && legacyLimited.status == 200 &&
                    legacyLimitedTags.count == 1 && generatedLimitedPath == legacyLimitedPath,
                    "both surfaces apply the same limit without reordering")
    }

    private func searchResultIDs(_ values: [Any]) -> [String] {
        values.compactMap { (($0 as? [String: Any])?["id"] as? String)?.lowercased() }
    }

    private func proveImprint(_ base: String, _ bearer: String) async throws {
        let status = try object(try await verb(base, bearer, "imprint-app-service_status", [:]),
                                "imprint status")
        try require(status["running"] as? Bool == true, "imprint app status is running")
        let title = "P5b transport manuscript \(UUID().uuidString)"
        let created = try string(try await verb(base, bearer,
            "imprint-app-service_create-document", ["title": title, "format": "typst"]),
            "created document")
        try require(UUID(uuidString: created) != nil, "created document has a UUID")
        let source = "= Native transport proof\n\nPersisted text."
        let inserted = try boolean(try await verb(base, bearer,
            "imprint-app-service_insert-text",
            ["document_id": created, "offset": 0, "text": source]), "insert text")
        try require(inserted, "native insert reported a write")
        let content = try string(try await verb(base, bearer,
            "imprint-app-service_get-content", ["document_id": created]), "read content")
        try require(content == source, "native insert reads back from the app")
        let renamed = title + " edited"
        let updated = try boolean(try await verb(base, bearer,
            "imprint-app-service_update-document",
            ["document_id": created, "title": renamed]), "rename document")
        try require(updated, "native rename reported a write")
        let documents = try array(try await verb(base, bearer,
            "imprint-manuscript-service_list-documents", [:]), "document readback")
        try require(documents.contains { item in
            guard let row = item as? [String: Any] else { return false }
            return (row["id"] as? String).flatMap(UUID.init(uuidString:)) == UUID(uuidString: created)
                && row["title"] as? String == renamed
        }, "renamed manuscript reads back through the native store service")
        let document = try object(try await verb(base, bearer,
            "imprint-manuscript-service_get-document", ["id": created]), "document metadata")
        try require(document["title"] as? String == renamed && document["format"] as? String == "typst",
                    "single manuscript reads back from the exact native store")
        for format in ["typst", "latex", "text"] {
            let bytes = try array(try await verb(base, bearer,
                "imprint-manuscript-service_export-document", ["id": created, "format": format]),
                "export \(format)")
            let octets = try bytes.map { value in
                try XCTUnwrap((value as? Int).flatMap(UInt8.init(exactly:)))
            }
            let data = Data(octets)
            if format == "typst" {
                let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                try require(exported["source"] as? String == source, "Typst export retains source envelope")
            } else {
                let text = try XCTUnwrap(String(data: data, encoding: .utf8))
                try require(text.contains("Persisted text."), "export contains the persisted body")
            }
        }
        let invalid = try await request(base, bearer,
            "/api/verb/imprint-manuscript-service_get-document", ["id": "not-a-uuid"])
        try require(invalid.status == 400, "invalid manuscript ID is a refusal")
        let missing = try await request(base, bearer,
            "/api/verb/imprint-manuscript-service_get-document", ["id": UUID().uuidString])
        try require(missing.status == 404, "missing manuscript is a refusal")
    }

    private func proveImpart(_ base: String, _ bearer: String) async throws {
        let status = try object(try await verb(base, bearer, "impart-service_status", [:]),
                                "impart status")
        try require(status["running"] as? Bool == true, "impart app status is running")
        let title = "P5b research conversation \(UUID().uuidString)"
        let conversation = try object(try await verb(base, bearer,
            "impart-service_create-conversation", ["title": title, "summary": NSNull()]),
            "created conversation")
        let id = try XCTUnwrap(conversation["id"] as? String)
        try require(UUID(uuidString: id) != nil && conversation["title"] as? String == title,
                    "conversation created with real ID")
        let content = "Transport message \(UUID().uuidString)"
        let message = try object(try await verb(base, bearer,
            "impart-service_add-message",
            ["conversation_id": id, "content": content, "role": "user"]), "added message")
        let messageID = try XCTUnwrap(message["id"] as? String)
        try require(UUID(uuidString: messageID) != nil && message["content"] as? String == content,
                    "message is persisted and identified")
        let artifact = try boolean(try await verb(base, bearer,
            "impart-service_record-artifact", ["conversation_id": id,
                "title": "Reference paper", "kind": "paper",
                "reference": "impress://imbib/papers/example"]), "record artifact")
        try require(artifact, "artifact relationship was written")
        let read = try object(try await verb(base, bearer,
            "impart-service_get-conversation", ["conversation_id": id]),
            "conversation readback")
        try require(read["id"] as? String == id && (read["message_count"] as? Int ?? 0) >= 1,
                    "conversation and message count read back")
        let messages = read["messages"] as? [[String: Any]] ?? []
        let stats = read["statistics"] as? [String: Any] ?? [:]
        try require(messages.contains { $0["id"] as? String == messageID &&
            $0["content_markdown"] as? String == content }, "message reads back in generated detail")
        try require((stats["artifact_count"] as? Int ?? 0) >= 1,
                    "recorded artifact reads back in statistics")
        let retiredDetail = try await request(base, bearer,
            "/api/research/conversations/\(id)", nil)
        try require(retiredDetail.status == 404,
                    "conversation detail HTTP route is retired after generated read migration")
    }

    private func proveImplore(_ base: String, _ bearer: String) async throws {
        let status = try object(try await verb(base, bearer, "implore-service_status", [:]),
                                "implore status")
        try require(status["running"] as? Bool == true, "implore app status is running")
        let datasetID = "p5b-audit-\(UUID().uuidString)"
        let created = try object(try await verb(base, bearer, "implore-service_create-figure", [
            "dataset_id": datasetID, "plot_type": "scatter", "x": "time", "y": "value",
            "name": "Audit proof", "series": [["label": "proof", "x": [0.0, 1.0], "y": [1.0, 2.0]]]
        ]), "created figure")
        let figureID = try XCTUnwrap(created["id"] as? String)
        try require(created["ok"] as? Bool == true && UUID(uuidString: figureID) != nil,
                    "figure creation persisted")
        let readback = try object(try await verb(base, bearer, "implore-service_get-figure",
                                             ["figure_id": figureID]), "figure readback")
        try require(readback["id"] as? String == figureID, "created figure reads back")
        // ImploreNativeVerbProofTests separately loads the owned rg-volume
        // fixture and asserts the five formerly-dead verbs against its viewer.
    }

    private func verifyNativeAudit(app: String, databasePath: String) async throws -> [String: Any] {
        let expectedVerb: String
        switch app {
        case "imbib": expectedVerb = "imbib-library-service_create-library"
        case "imprint": expectedVerb = "imprint-app-service_create-document"
        case "impart": expectedVerb = "impart-service_create-conversation"
        case "implore": expectedVerb = "implore-service_create-figure"
        case "impel": return [:] // This app's transport proof invokes only read-only kit verbs.
        default: throw failure("unknown audit proof app: \(app)")
        }
        let store = try SharedStore.open(path: databasePath)
        for _ in 0..<100 {
            let rows = try store.queryBySchema(schemaRef: "core/verb-call@1.0.0", limit: 200, offset: 0)
            for row in rows {
                guard let payload = try? JSONSerialization.jsonObject(with: Data(row.payloadJson.utf8)) as? [String: Any],
                      payload["verb"] as? String == expectedVerb,
                      payload["trace_id"] as? String == traceID else { continue }
                let caller = try XCTUnwrap(payload["caller"] as? [String: Any])
                try require(UUID(uuidString: row.id) != nil &&
                            payload["parent_call"] as? String == parentCallID,
                            "native audit preserves the supplied parent call")
                try require(payload["ok"] as? Bool == true &&
                            caller["kind"] as? String == "app" && caller["name"] as? String == app,
                            "native audit preserves the expected app caller")
                return ["id": row.id, "verb": expectedVerb, "trace_id": traceID,
                        "parent_call": parentCallID, "caller": caller, "ok": true]
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw failure("No \(expectedVerb) audit row appeared in the exact PID-owned store")
    }

    private struct Reply {
        let status: Int
        let value: Any
    }

    private func verb(_ base: String, _ bearer: String, _ name: String,
                      _ args: [String: Any]) async throws -> Reply {
        try await request(base, bearer, "/api/verb/\(name)", args)
    }

    private func request(_ base: String, _ bearer: String, _ path: String,
                         _ body: [String: Any]?) async throws -> Reply {
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
        request.timeoutInterval = 30
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(traceID, forHTTPHeaderField: "traceparent")
        request.setValue(parentCallID, forHTTPHeaderField: "x-impress-parent-call")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        calls.append(["path": path, "status": status, "args": body ?? [:], "result": value,
                      "traceparent": traceID, "parent_call": parentCallID])
        if let callEvidenceURL {
            try JSONSerialization.data(withJSONObject: calls, options: [.prettyPrinted, .sortedKeys])
                .write(to: callEvidenceURL, options: .atomic)
        }
        return Reply(status: status, value: value)
    }

    private func object(_ reply: Reply, _ label: String) throws -> [String: Any] {
        try require(reply.status == 200, "\(label) HTTP \(reply.status): \(reply.value)")
        let value = try XCTUnwrap(reply.value as? [String: Any], "\(label) did not return an object")
        try require(value["ok"] as? Bool != false && value["status"] as? String != "error",
                    "\(label) refused: \(value)")
        return value
    }
    private func objectWithoutSuccessCheck(_ reply: Reply, _ label: String) throws -> [String: Any] {
        try require((400..<500).contains(reply.status), "\(label) status \(reply.status)")
        return try XCTUnwrap(reply.value as? [String: Any], "\(label) did not return an object")
    }
    private func array(_ reply: Reply, _ label: String) throws -> [Any] {
        try require(reply.status == 200, "\(label) HTTP \(reply.status): \(reply.value)")
        return try XCTUnwrap(reply.value as? [Any], "\(label) did not return an array")
    }
    private func string(_ reply: Reply, _ label: String) throws -> String {
        try require(reply.status == 200, "\(label) HTTP \(reply.status): \(reply.value)")
        return try XCTUnwrap(reply.value as? String, "\(label) did not return a string")
    }
    private func boolean(_ reply: Reply, _ label: String) throws -> Bool {
        try require(reply.status == 200, "\(label) HTTP \(reply.status): \(reply.value)")
        return try XCTUnwrap(reply.value as? Bool, "\(label) did not return a boolean")
    }
    private func require(_ condition: Bool, _ message: String) throws {
        XCTAssertTrue(condition, message)
        if !condition { throw failure(message) }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "ImpressP5bTransportProof", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
