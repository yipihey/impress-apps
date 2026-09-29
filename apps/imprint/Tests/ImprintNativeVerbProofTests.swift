import Foundation
import ImpressAutomation
import ImpressKit
import PublicationManagerCore
import XCTest
@testable import imprint

/// Hosted proof only. The test host's SharedWorkspace is PID-owned scratch;
/// the production App Group path must never be opened by this fixture.
@MainActor
final class ImprintNativeVerbProofTests: XCTestCase {
    func testNativeGenericRouteAndAppRefusalUseTheScratchWorkspace() async throws {
        guard ProcessInfo.processInfo.environment["IMPRINT_P5B_PROOF"] == "1" else {
            throw XCTSkip("Set IMPRINT_P5B_PROOF=1 for the isolated native proof")
        }
        let env = ProcessInfo.processInfo.environment
        let port = try XCTUnwrap(env["IMPRINT_P5B_PROOF_PORT"].flatMap(UInt16.init))
        let path = SharedWorkspace.databasePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-unit-tests-\(pid)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try requireIsolation(ImpressRuntime.isUnitTestProcess && ImpressRuntime.isUITestingProcess,
                             "Host must be a UI-testing XCTest process")
        try requireIsolation(
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                == root.appendingPathComponent("workspace/impress.sqlite"),
            "Workspace database must be PID-owned scratch")
        try requireIsolation(RustStoreAdapter.shared.databaseLocation == path,
                             "Rust store must use the same scratch database")
        try requireIsolation(UserDefaults.standard.integer(forKey: "httpAutomationPort") == Int(port),
                             "HTTP port must be the proof port")
        try requireIsolation(env["IMPRESS_DEVICE_ID"]?.hasPrefix("codex-p5b-") == true,
                             "Device ID must be proof-owned")
        try ImprintNativeVerbs.install()

        let router = ImprintHTTPRouter()
        let status = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-app-service_status", body: "{}"))
        XCTAssertEqual(status.status, 200, String(data: status.body, encoding: .utf8) ?? "")
        let statusBody = try XCTUnwrap(JSONSerialization.jsonObject(with: status.body) as? [String: Any])
        XCTAssertNotEqual(statusBody["code"] as? String, "not-found")

        let outline = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-manuscript-service_document-outline",
            body: #"{"source":"= Title\n== Section"}"#))
        XCTAssertEqual(outline.status, 200, String(data: outline.body, encoding: .utf8) ?? "")
        let outlineBody = try XCTUnwrap(JSONSerialization.jsonObject(with: outline.body) as? [String: Any])
        XCTAssertNotEqual(outlineBody["code"] as? String, "not-found")

        let compileCache = root.appendingPathComponent("compile-cache")
        setenv("IMPRINT_COMPILE_CACHE_DIR", compileCache.path, 1)
        let compileArgs: [String: Any] = [
            "source": "= Native proof\n\nA short PDF.\n",
            "options": ["page_size": "A4", "font_size": 11.0,
                        "margin_top": 72.0, "margin_right": 72.0,
                        "margin_bottom": 72.0, "margin_left": 72.0],
        ]
        let compileBytes = try JSONSerialization.data(withJSONObject: compileArgs)
        let compiled = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-manuscript-service_compile-typst",
            body: String(decoding: compileBytes, as: UTF8.self)))
        XCTAssertEqual(compiled.status, 200, String(decoding: compiled.body, as: UTF8.self))
        let compileValue = try XCTUnwrap(JSONSerialization.jsonObject(with: compiled.body) as? [String: Any])
        XCTAssertTrue(compileValue["error"] is NSNull)
        let pdfPath = try XCTUnwrap(compileValue["pdf_path"] as? String)
        try requireIsolation(pdfPath.hasPrefix(compileCache.path + "/"),
                             "Compiled PDF must remain in the PID-owned cache")
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: pdfPath)).starts(with: Data("%PDF".utf8)))

        let refused = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-app-service_get-content",
            body: #"{"document_id":"not-a-uuid"}"#))
        XCTAssertEqual(refused.status, 400, String(data: refused.body, encoding: .utf8) ?? "")
        let refusedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: refused.body) as? [String: Any])
        XCTAssertNotEqual(refusedBody["code"] as? String, "not-found")

        func call(_ verb: String, _ args: [String: Any]) async throws -> HTTPResponse {
            let data = try JSONSerialization.data(withJSONObject: args)
            return await router.route(HTTPRequest(
                method: "POST", path: "/api/verb/imprint-app-service_\(verb)",
                body: String(decoding: data, as: UTF8.self)))
        }
        func value(_ response: HTTPResponse) throws -> Any {
            try JSONSerialization.jsonObject(with: response.body, options: .fragmentsAllowed)
        }
        let created = try await call("create-document", ["title": "Created by generic verb", "format": "typst"])
        XCTAssertEqual(created.status, 200, String(decoding: created.body, as: UTF8.self))
        let createdID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(value(created) as? String)))
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: createdID)?.title, "Created by generic verb")
        let createdContent = try await call("get-content", ["document_id": createdID.uuidString])
        XCTAssertEqual(createdContent.status, 200)
        XCTAssertEqual(try value(createdContent) as? String, "")

        let id = try ManuscriptStoreAdapter.shared.createManuscript(
            title: "Native proof", format: .typst, body: "alpha beta alpha")
        let replaced = try await call("replace", [
            "document_id": id.uuidString, "find": "alpha", "replace": "gamma"])
        XCTAssertEqual(replaced.status, 200, String(data: replaced.body, encoding: .utf8) ?? "")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, "gamma beta gamma")
        XCTAssertEqual(ManuscriptSessionRegistry.shared.session(for: id)?.source, "gamma beta gamma")
        let afterReplace = try await call("get-content", ["document_id": id.uuidString])
        XCTAssertEqual(afterReplace.status, 200)
        XCTAssertEqual(try value(afterReplace) as? String, "gamma beta gamma")

        let inserted = try await call("insert-text", [
            "document_id": id.uuidString, "offset": 0, "text": "= "])
        XCTAssertEqual(inserted.status, 200, String(data: inserted.body, encoding: .utf8) ?? "")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, "= gamma beta gamma")

        let deleted = try await call("delete-text", [
            "document_id": id.uuidString, "offset": 0, "length": 2])
        XCTAssertEqual(deleted.status, 200, String(data: deleted.body, encoding: .utf8) ?? "")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, "gamma beta gamma")
        let afterDelete = try await call("get-content", ["document_id": id.uuidString])
        XCTAssertEqual(afterDelete.status, 200)
        XCTAssertEqual(try value(afterDelete) as? String, "gamma beta gamma")

        let renamed = try await call("update-document", [
            "document_id": id.uuidString, "title": "Renamed proof"])
        XCTAssertEqual(renamed.status, 200, String(data: renamed.body, encoding: .utf8) ?? "")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.title, "Renamed proof")

        let metadata = try await call("update-metadata", [
            "document_id": id.uuidString,
            "metadata_json": #"{"status":"in-review","authors":["Human Author"]}"#])
        XCTAssertEqual(metadata.status, 200, String(decoding: metadata.body, as: UTF8.self))
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.status, "in-review")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.authors, ["Human Author"])

        let linkedManuscriptID = UUID()
        try ManuscriptStoreAdapter.shared.updateMetadata(
            id: id, linkedImbibManuscriptID: linkedManuscriptID,
            linkedImbibLibraryID: "linked-library-proof")
        let legacyList = await router.route(HTTPRequest(method: "GET", path: "/api/documents"))
        XCTAssertEqual(legacyList.status, 200)
        let legacyListBody = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyList.body) as? [String: Any])
        let legacyRows = try XCTUnwrap(legacyListBody["documents"] as? [[String: Any]])
        let legacyRow = try XCTUnwrap(legacyRows.first {
            ($0["id"] as? String)?.lowercased() == id.uuidString.lowercased()
        })
        let generatedList = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-manuscript-service_list-documents", body: "{}"))
        XCTAssertEqual(generatedList.status, 200, String(decoding: generatedList.body, as: UTF8.self))
        let generatedRows = try XCTUnwrap(JSONSerialization.jsonObject(with: generatedList.body) as? [[String: Any]])
        let generatedRow = try XCTUnwrap(generatedRows.first {
            ($0["id"] as? String)?.lowercased() == id.uuidString.lowercased()
        })
        for (legacyKey, generatedKey) in [
            ("title", "title"), ("authors", "authors"), ("format", "format"),
            ("status", "status"), ("modifiedAt", "last_modified"), ("createdAt", "created_at"),
        ] {
            XCTAssertEqual(legacyRow[legacyKey] as? NSObject, generatedRow[generatedKey] as? NSObject,
                           "Legacy and generated list field \(legacyKey) diverged")
        }
        XCTAssertEqual((legacyRow["id"] as? String)?.lowercased(),
                       (generatedRow["id"] as? String)?.lowercased())
        XCTAssertEqual(generatedRow["word_count"] as? Int, 3)

        let legacyDetailResponse = await router.route(HTTPRequest(
            method: "GET", path: "/api/documents/\(id.uuidString)"))
        XCTAssertEqual(legacyDetailResponse.status, 200)
        let legacyDetailBody = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyDetailResponse.body) as? [String: Any])
        let legacyDetail = try XCTUnwrap(legacyDetailBody["document"] as? [String: Any])
        let generatedDetailResponse = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-manuscript-service_get-document",
            body: #"{"id":"\#(id.uuidString)"}"#))
        XCTAssertEqual(generatedDetailResponse.status, 200, String(decoding: generatedDetailResponse.body, as: UTF8.self))
        let generatedDetail = try XCTUnwrap(JSONSerialization.jsonObject(with: generatedDetailResponse.body) as? [String: Any])
        for (legacyKey, generatedKey) in [
            ("title", "title"), ("authors", "authors"), ("format", "format"),
            ("status", "status"), ("modifiedAt", "last_modified"), ("createdAt", "created_at"),
            ("linkedImbibManuscriptID", "linked_imbib_manuscript_id"),
            ("linkedImbibLibraryID", "linked_imbib_library_id"),
        ] {
            if legacyKey == "linkedImbibManuscriptID" {
                XCTAssertEqual((legacyDetail[legacyKey] as? String)?.lowercased(),
                               (generatedDetail[generatedKey] as? String)?.lowercased())
                continue
            }
            XCTAssertEqual(legacyDetail[legacyKey] as? NSObject,
                           generatedDetail[generatedKey] as? NSObject,
                           "Legacy and generated detail field \(legacyKey) diverged")
        }
        XCTAssertEqual(generatedDetail["word_count"] as? Int, 3)

        // A local editor change has not yet passed its debounce. Native insert
        // must derive from that live buffer, not the older stored body. The
        // offset is an editor UTF-16 position, after the two-unit emoji.
        let session = try XCTUnwrap(ManuscriptSessionRegistry.shared.session(for: id))
        session.source = "human 😀 gamma beta gamma"
        let merged = try await call("insert-text", [
            "document_id": id.uuidString, "offset": 9, "text": "agent "])
        XCTAssertEqual(merged.status, 200, String(decoding: merged.body, as: UTF8.self))
        XCTAssertEqual(session.source, "human 😀 agent gamma beta gamma")
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, session.source)
        let finalContent = try await call("get-content", ["document_id": id.uuidString])
        XCTAssertEqual(finalContent.status, 200)
        XCTAssertEqual(try value(finalContent) as? String, session.source)

        // The comment service is bound to this owned manuscript and scratch
        // Rust store. Native records must retain the document and real anchor.
        let comments = CommentService(authorId: "p5b-proof")
        comments.attach(manuscriptID: id, body: session.source)
        CommentRegistry.shared.register(comments, for: id)
        defer { CommentRegistry.shared.unregister(documentID: id) }
        let createdComment = try await call("create-comment", [
            "document_id": id.uuidString, "body": "Check this phrase", "anchor": "agent"])
        XCTAssertEqual(createdComment.status, 200, String(decoding: createdComment.body, as: UTF8.self))
        let comment = try XCTUnwrap(value(createdComment) as? [String: Any])
        let commentID = try XCTUnwrap(comment["id"] as? String)
        XCTAssertEqual(comment["document_id"] as? String, id.uuidString)
        XCTAssertEqual(comment["body"] as? String, "Check this phrase")
        XCTAssertEqual(comment["anchor"] as? String, "agent")
        XCTAssertEqual(comment["status"] as? String, "open")
        let storedBefore = ManuscriptCommentStore.list(manuscriptID: id)
        XCTAssertTrue(storedBefore.contains { $0.id.uuidString == commentID })

        let listedComments = try await call("list-comments", ["document_id": id.uuidString])
        XCTAssertEqual(listedComments.status, 200)
        let listed = try XCTUnwrap(value(listedComments) as? [[String: Any]])
        let listedComment = try XCTUnwrap(listed.first { $0["id"] as? String == commentID })
        XCTAssertEqual(listedComment["document_id"] as? String, id.uuidString)
        XCTAssertEqual(listedComment["anchor"] as? String, "agent")

        // Compare the retained HTTP contract with the generated read using a
        // real suggestion rooted in the live UTF-16 editor buffer.
        // The emoji occupies UTF-16 units 6..<8; a half-surrogate range
        // cannot be used as the expected replacement span.
        let legacyCreateBody = try JSONSerialization.data(withJSONObject: [
            "content": "Thread root",
            "start": 6,
            "end": 8,
            "proposedText": "🧪",
            "authorAgentId": "legacy-reviewer",
            "authorName": "Legacy Reviewer",
        ])
        let legacyCreate = await router.route(HTTPRequest(
            method: "POST", path: "/api/documents/\(id.uuidString)/comments",
            body: String(decoding: legacyCreateBody, as: UTF8.self)))
        XCTAssertEqual(legacyCreate.status, 201, String(decoding: legacyCreate.body, as: UTF8.self))
        let legacyCreatedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyCreate.body) as? [String: Any])
        let legacyRoot = try XCTUnwrap(legacyCreatedObject["comment"] as? [String: Any])
        let legacyRootID = try XCTUnwrap(legacyRoot["id"] as? String)
        XCTAssertEqual((legacyRoot["range"] as? [String: Int])?["start"], 6)
        XCTAssertEqual((legacyRoot["range"] as? [String: Int])?["end"], 8)
        XCTAssertEqual(legacyRoot["authorAgentId"] as? String, "legacy-reviewer")

        let legacySuggestionList = await router.route(HTTPRequest(
            method: "GET", path: "/api/documents/\(id.uuidString)/comments",
            queryParams: ["filter": "suggestions", "authorAgentId": "legacy-reviewer"]))
        XCTAssertEqual(legacySuggestionList.status, 200)
        let legacySuggestionBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacySuggestionList.body) as? [String: Any])
        let legacySuggestions = try XCTUnwrap(legacySuggestionBody["comments"] as? [[String: Any]])
        XCTAssertEqual(legacySuggestions.count, 1)
        let legacySuggestion = try XCTUnwrap(legacySuggestions.first)

        let generatedSuggestionList = try await call("list-comments", [
            "document_id": id.uuidString,
            "filter": "suggestions",
            "author_agent_id": "legacy-reviewer",
        ])
        XCTAssertEqual(generatedSuggestionList.status, 200,
                       String(decoding: generatedSuggestionList.body, as: UTF8.self))
        let generatedSuggestions = try XCTUnwrap(
            value(generatedSuggestionList) as? [[String: Any]])
        XCTAssertEqual(generatedSuggestions.count, 1)
        let generatedSuggestion = try XCTUnwrap(generatedSuggestions.first)
        XCTAssertEqual(generatedSuggestion["id"] as? String, legacySuggestion["id"] as? String)
        XCTAssertEqual(generatedSuggestion["author"] as? String, legacySuggestion["author"] as? String)
        XCTAssertEqual(generatedSuggestion["author_id"] as? String, legacySuggestion["authorId"] as? String)
        XCTAssertEqual(generatedSuggestion["body"] as? String, legacySuggestion["content"] as? String)
        XCTAssertEqual(generatedSuggestion["content"] as? String, legacySuggestion["content"] as? String)
        XCTAssertEqual(generatedSuggestion["status"] as? String, "open")
        XCTAssertEqual(generatedSuggestion["created_at"] as? String,
                       legacySuggestion["createdAt"] as? String)
        XCTAssertEqual(generatedSuggestion["modified_at"] as? String,
                       legacySuggestion["modifiedAt"] as? String)
        XCTAssertEqual(generatedSuggestion["proposed_text"] as? String,
                       legacySuggestion["proposedText"] as? String)
        XCTAssertEqual(generatedSuggestion["author_agent_id"] as? String,
                       legacySuggestion["authorAgentId"] as? String)
        XCTAssertEqual(generatedSuggestion["is_resolved"] as? Bool,
                       legacySuggestion["isResolved"] as? Bool)
        XCTAssertEqual(generatedSuggestion["is_suggestion"] as? Bool,
                       legacySuggestion["isSuggestion"] as? Bool)
        XCTAssertEqual((generatedSuggestion["range"] as? [String: Int])?["start"],
                       (legacySuggestion["range"] as? [String: Int])?["start"])
        XCTAssertEqual((generatedSuggestion["range"] as? [String: Int])?["end"],
                       (legacySuggestion["range"] as? [String: Int])?["end"])

        let countBeforeInvalidParent = comments.comments.count
        let invalidParent = try await call("create-comment", [
            "document_id": id.uuidString, "body": "must not be stored", "parent_id": "not-a-uuid",
        ])
        XCTAssertEqual(invalidParent.status, 400)
        XCTAssertEqual(comments.comments.count, countBeforeInvalidParent)

        let generatedReply = try await call("create-comment", [
            "document_id": id.uuidString,
            "body": "Thread reply",
            "parent_id": legacyRootID,
            "proposed_text": "revised agent",
            "author_agent_id": "reply-agent",
            "author_name": "Reply Agent",
        ])
        XCTAssertEqual(generatedReply.status, 200, String(decoding: generatedReply.body, as: UTF8.self))
        let generatedReplyRecord = try XCTUnwrap(value(generatedReply) as? [String: Any])
        XCTAssertEqual(generatedReplyRecord["parent_id"] as? String, legacyRootID)
        XCTAssertEqual(generatedReplyRecord["proposed_text"] as? String, "revised agent")
        XCTAssertEqual(generatedReplyRecord["author_agent_id"] as? String, "reply-agent")
        XCTAssertEqual(generatedReplyRecord["author"] as? String, "Reply Agent")
        XCTAssertEqual((generatedReplyRecord["range"] as? [String: Int])?["start"], 6)
        XCTAssertEqual((generatedReplyRecord["range"] as? [String: Int])?["end"], 8)
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == legacyRootID }?.textRange,
                       comments.comments.first {
                           $0.id.uuidString == generatedReplyRecord["id"] as? String
                       }?.textRange,
                       "Replies must keep the root's live UTF-16 range")

        let legacyAgentList = await router.route(HTTPRequest(
            method: "GET", path: "/api/documents/\(id.uuidString)/comments",
            queryParams: ["authorAgentId": "reply-agent"]))
        let legacyAgentBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyAgentList.body) as? [String: Any])
        let legacyAgentRows = try XCTUnwrap(legacyAgentBody["comments"] as? [[String: Any]])
        XCTAssertEqual(legacyAgentRows.count, 1)
        XCTAssertEqual(legacyAgentRows.first?["parentId"] as? String, legacyRootID)

        // The legacy accept route applies and saves the replacement at the
        // comment's UTF-16 range, returns its completed operation handle, and
        // resolves the comment only after the editor write succeeds.
        let rootRange = try XCTUnwrap(comments.comments.first { $0.id.uuidString == legacyRootID }?.textRange)
        XCTAssertEqual(rootRange, TextRange(start: 6, end: 8))
        let expectedAfterLegacyAccept = (session.source as NSString).replacingCharacters(
            in: NSRange(location: rootRange.start, length: rootRange.length),
            with: "🧪")
        let legacyAccept = await router.route(HTTPRequest(
            method: "POST", path: "/api/comments/\(legacyRootID)/accept"))
        XCTAssertEqual(legacyAccept.status, 200, String(decoding: legacyAccept.body, as: UTF8.self))
        let legacyAcceptBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyAccept.body) as? [String: Any])
        XCTAssertEqual(legacyAcceptBody["accepted"] as? Bool, true)
        XCTAssertEqual(legacyAcceptBody["commentId"] as? String, legacyRootID)
        XCTAssertEqual(legacyAcceptBody["documentId"] as? String, id.uuidString)
        let legacyOperationID = try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(legacyAcceptBody["operationId"] as? String)))
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == legacyRootID }?.isResolved, true)
        XCTAssertEqual(session.source, expectedAfterLegacyAccept)
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, expectedAfterLegacyAccept)
        XCTAssertEqual(OperationTracker.shared.get(id: legacyOperationID)?.kind, "acceptSuggestion")
        XCTAssertEqual(OperationTracker.shared.get(id: legacyOperationID)?.status.rawValue, "completed")

        // The generated accept verb follows the same native route and exposes
        // its camel-case HTTP result as a typed Rust record.
        let generatedAcceptSuggestion = try await call("create-comment", [
            "document_id": id.uuidString,
            "body": "Apply this generated suggestion",
            "proposed_text": "delta",
            "anchor": "gamma",
        ])
        XCTAssertEqual(generatedAcceptSuggestion.status, 200)
        let generatedAcceptComment = try XCTUnwrap(value(generatedAcceptSuggestion) as? [String: Any])
        let generatedAcceptID = try XCTUnwrap(generatedAcceptComment["id"] as? String)
        let generatedRange = try XCTUnwrap(generatedAcceptComment["range"] as? [String: Int])
        let expectedGammaRange = (session.source as NSString).range(of: "gamma")
        XCTAssertEqual(generatedRange["start"], expectedGammaRange.location)
        XCTAssertEqual(generatedRange["end"], expectedGammaRange.location + expectedGammaRange.length)
        let expectedAfterGeneratedAccept = (session.source as NSString).replacingCharacters(
            in: expectedGammaRange, with: "delta")
        let generatedAccept = try await call("accept-comment-suggestion", ["comment_id": generatedAcceptID])
        XCTAssertEqual(generatedAccept.status, 200, String(decoding: generatedAccept.body, as: UTF8.self))
        let generatedAcceptBody = try XCTUnwrap(value(generatedAccept) as? [String: Any])
        XCTAssertEqual(generatedAcceptBody["accepted"] as? Bool, true)
        XCTAssertEqual(generatedAcceptBody["comment_id"] as? String, generatedAcceptID)
        XCTAssertEqual(generatedAcceptBody["document_id"] as? String, id.uuidString)
        let generatedOperationID = try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(generatedAcceptBody["operation_id"] as? String)))
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == generatedAcceptID }?.isResolved, true)
        XCTAssertEqual(session.source, expectedAfterGeneratedAccept)
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, expectedAfterGeneratedAccept)
        XCTAssertEqual(OperationTracker.shared.get(id: generatedOperationID)?.kind, "acceptSuggestion")
        XCTAssertEqual(OperationTracker.shared.get(id: generatedOperationID)?.status.rawValue, "completed")

        // A stale suggestion range must fail against the latest live buffer,
        // leave the comment unresolved, and never overwrite the saved body.
        let staleSuggestion = try await call("create-comment", [
            "document_id": id.uuidString,
            "body": "This anchor will be out of range",
            "proposed_text": "not applied",
            "anchor": "beta",
        ])
        XCTAssertEqual(staleSuggestion.status, 200)
        let staleRecord = try XCTUnwrap(value(staleSuggestion) as? [String: Any])
        let staleID = try XCTUnwrap(staleRecord["id"] as? String)
        let savedBeforeStaleAccept = try XCTUnwrap(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body)
        session.source = "short"
        let staleAccept = try await call("accept-comment-suggestion", ["comment_id": staleID])
        XCTAssertEqual(staleAccept.status, 400, String(decoding: staleAccept.body, as: UTF8.self))
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == staleID }?.isResolved, false)
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, savedBeforeStaleAccept)
        session.source = savedBeforeStaleAccept
        comments.syncBody(savedBeforeStaleAccept)

        // Simulate typing after the range snapshot but before the edit enters
        // MainActor. A still-valid numeric range must not replace different text.
        let changedSource = "typed " + savedBeforeStaleAccept
        session.source = changedSource
        let racedBody = try JSONSerialization.data(withJSONObject: [
            "start": 0, "end": 1, "text": "must not apply",
            "expected_source": savedBeforeStaleAccept,
        ])
        let racedEdit = await ImprintNativeEdits.apply(
            method: "replace_range", id: id.uuidString,
            request: HTTPRequest(method: "POST", path: "/proof/range",
                                 body: String(decoding: racedBody, as: UTF8.self)))
        XCTAssertEqual(racedEdit.status, 409)
        XCTAssertEqual(session.source, changedSource)
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, savedBeforeStaleAccept)
        session.source = savedBeforeStaleAccept

        // The retained reject route resolves without changing source.
        let legacyRejectCreateBody = try JSONSerialization.data(withJSONObject: [
            "content": "Legacy reject",
            "start": 0,
            "end": 0,
            "proposedText": "unused replacement",
        ])
        let legacyRejectCreate = await router.route(HTTPRequest(
            method: "POST", path: "/api/documents/\(id.uuidString)/comments",
            body: String(decoding: legacyRejectCreateBody, as: UTF8.self)))
        XCTAssertEqual(legacyRejectCreate.status, 201)
        let legacyRejectObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyRejectCreate.body) as? [String: Any])
        let legacyRejectComment = try XCTUnwrap(legacyRejectObject["comment"] as? [String: Any])
        let legacyRejectID = try XCTUnwrap(legacyRejectComment["id"] as? String)
        let sourceBeforeLegacyReject = session.source
        let legacyReject = await router.route(HTTPRequest(
            method: "POST", path: "/api/comments/\(legacyRejectID)/reject"))
        XCTAssertEqual(legacyReject.status, 200)
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == legacyRejectID }?.isResolved, true)
        XCTAssertEqual(session.source, sourceBeforeLegacyReject)

        let rejectedSuggestion = try await call("create-comment", [
            "document_id": id.uuidString,
            "body": "No need to apply this",
            "proposed_text": "discard me",
            "anchor": "beta",
        ])
        XCTAssertEqual(rejectedSuggestion.status, 200)
        let rejectedSuggestionRecord = try XCTUnwrap(value(rejectedSuggestion) as? [String: Any])
        let rejectedSuggestionID = try XCTUnwrap(rejectedSuggestionRecord["id"] as? String)
        let sourceBeforeReject = session.source
        let storedBodyBeforeReject = ManuscriptStoreAdapter.shared.manuscript(id: id)?.body
        let rejected = try await call("reject-comment-suggestion", ["comment_id": rejectedSuggestionID])
        XCTAssertEqual(rejected.status, 200, String(decoding: rejected.body, as: UTF8.self))
        XCTAssertEqual(try value(rejected) as? Bool, true)
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == rejectedSuggestionID }?.isResolved, true)
        XCTAssertEqual(session.source, sourceBeforeReject)
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, storedBodyBeforeReject)

        // Acceptance refuses ordinary comments and unknown IDs; neither case
        // changes review state or the live/saved manuscript.
        let contentBeforeAcceptanceRefusals = session.source
        let storedBeforeAcceptanceRefusals = ManuscriptStoreAdapter.shared.manuscript(id: id)?.body
        let ordinaryCommentAccept = try await call("accept-comment-suggestion", ["comment_id": commentID])
        XCTAssertEqual(ordinaryCommentAccept.status, 400)
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == commentID }?.isResolved, false)
        let unknownCommentAccept = try await call(
            "accept-comment-suggestion", ["comment_id": UUID().uuidString])
        XCTAssertEqual(unknownCommentAccept.status, 404)
        XCTAssertEqual(session.source, contentBeforeAcceptanceRefusals)
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body,
                       storedBeforeAcceptanceRefusals)

        // Snapshot after the successful thread writes; the refusal must
        // preserve all records now present, including the new root and reply.
        let storedBeforeStatusRefusal = ManuscriptCommentStore.list(manuscriptID: id)
        // Accept/reject need suggestion semantics, so neither may mutate a
        // comment by silently treating the status as merely resolved.
        for unsupported in ["accepted", "rejected"] {
            let refusal = try await call("update-comment", [
                "comment_id": commentID, "body": "must not be saved", "status": unsupported])
            XCTAssertEqual(refusal.status, 400, String(decoding: refusal.body, as: UTF8.self))
            let error = try XCTUnwrap(value(refusal) as? [String: Any])
            XCTAssertTrue((error["message"] as? String)?.contains(unsupported) == true)
            XCTAssertEqual(comments.comments.first { $0.id.uuidString == commentID }?.content,
                           "Check this phrase")
            XCTAssertEqual(comments.comments.first { $0.id.uuidString == commentID }?.isResolved,
                           false)
            XCTAssertEqual(ManuscriptCommentStore.list(manuscriptID: id), storedBeforeStatusRefusal)
        }

        let resolved = try await call("update-comment", ["comment_id": commentID, "status": "resolved"])
        XCTAssertEqual(resolved.status, 200)
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == commentID }?.isResolved, true)
        let reopened = try await call("update-comment", ["comment_id": commentID, "status": "open"])
        XCTAssertEqual(reopened.status, 200)
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == commentID }?.isResolved, false)
    }

    private func requireIsolation(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "ImpressP5bProofIsolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
