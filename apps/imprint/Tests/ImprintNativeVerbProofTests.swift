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
        let retiredList = await router.route(HTTPRequest(method: "GET", path: "/api/documents"))
        XCTAssertEqual(retiredList.status, 404)
        let generatedList = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-manuscript-service_list-documents", body: "{}"))
        XCTAssertEqual(generatedList.status, 200, String(decoding: generatedList.body, as: UTF8.self))
        let generatedRows = try XCTUnwrap(JSONSerialization.jsonObject(with: generatedList.body) as? [[String: Any]])
        let generatedRow = try XCTUnwrap(generatedRows.first {
            ($0["id"] as? String)?.lowercased() == id.uuidString.lowercased()
        })
        XCTAssertEqual(generatedRow["title"] as? String, "Renamed proof")
        XCTAssertEqual(generatedRow["authors"] as? [String], ["Human Author"])
        XCTAssertEqual(generatedRow["format"] as? String, "typst")
        XCTAssertEqual(generatedRow["status"] as? String, "in-review")
        XCTAssertEqual(generatedRow["word_count"] as? Int, 3)
        XCTAssertEqual((generatedRow["id"] as? String)?.lowercased(), id.uuidString.lowercased())

        let retiredDetailResponse = await router.route(HTTPRequest(
            method: "GET", path: "/api/documents/\(id.uuidString)"))
        XCTAssertEqual(retiredDetailResponse.status, 404)
        let generatedDetailResponse = await router.route(HTTPRequest(
            method: "POST", path: "/api/verb/imprint-manuscript-service_get-document",
            body: #"{"id":"\#(id.uuidString)"}"#))
        XCTAssertEqual(generatedDetailResponse.status, 200, String(decoding: generatedDetailResponse.body, as: UTF8.self))
        let generatedDetail = try XCTUnwrap(JSONSerialization.jsonObject(with: generatedDetailResponse.body) as? [String: Any])
        XCTAssertEqual(generatedDetail["title"] as? String, "Renamed proof")
        XCTAssertEqual(generatedDetail["authors"] as? [String], ["Human Author"])
        XCTAssertEqual(generatedDetail["format"] as? String, "typst")
        XCTAssertEqual(generatedDetail["status"] as? String, "in-review")
        XCTAssertEqual(generatedDetail["linked_imbib_manuscript_id"] as? String, linkedManuscriptID.uuidString)
        XCTAssertEqual(generatedDetail["linked_imbib_library_id"] as? String, "linked-library-proof")
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

        // Retired comment routes return 404. The generated contract retains the
        // same seeded create, filtered-list, threading and suggestion behavior.
        let retiredCreateBody = try JSONSerialization.data(withJSONObject: [
            "content": "must not be stored through retired route",
            "start": 7,
            "end": 9,
        ])
        let retiredCreate = await router.route(HTTPRequest(
            method: "POST", path: "/api/documents/\(id.uuidString)/comments",
            body: String(decoding: retiredCreateBody, as: UTF8.self)))
        XCTAssertEqual(retiredCreate.status, 404)

        let generatedRootResponse = try await call("create-comment", [
            "document_id": id.uuidString,
            "body": "Thread root",
            "anchor": "😀",
            "proposed_text": "🧪",
            "author_agent_id": "legacy-reviewer",
            "author_name": "Legacy Reviewer",
        ])
        XCTAssertEqual(generatedRootResponse.status, 200, String(decoding: generatedRootResponse.body, as: UTF8.self))
        let generatedRoot = try XCTUnwrap(value(generatedRootResponse) as? [String: Any])
        let generatedRootID = try XCTUnwrap(generatedRoot["id"] as? String)
        XCTAssertEqual(generatedRoot["author_agent_id"] as? String, "legacy-reviewer")
        XCTAssertEqual(generatedRoot["proposed_text"] as? String, "🧪")

        let retiredSuggestionList = await router.route(HTTPRequest(
            method: "GET", path: "/api/documents/\(id.uuidString)/comments",
            queryParams: ["filter": "suggestions", "authorAgentId": "legacy-reviewer"]))
        XCTAssertEqual(retiredSuggestionList.status, 404)
        let generatedSuggestionList = try await call("list-comments", [
            "document_id": id.uuidString,
            "filter": "suggestions",
            "author_agent_id": "legacy-reviewer",
        ])
        XCTAssertEqual(generatedSuggestionList.status, 200,
                       String(decoding: generatedSuggestionList.body, as: UTF8.self))
        let generatedSuggestions = try XCTUnwrap(value(generatedSuggestionList) as? [[String: Any]])
        XCTAssertEqual(generatedSuggestions.count, 1)
        let generatedSuggestion = try XCTUnwrap(generatedSuggestions.first)
        XCTAssertEqual(generatedSuggestion["id"] as? String, generatedRootID)
        XCTAssertEqual(generatedSuggestion["author_agent_id"] as? String, "legacy-reviewer")
        XCTAssertEqual(generatedSuggestion["body"] as? String, "Thread root")
        XCTAssertEqual(generatedSuggestion["proposed_text"] as? String, "🧪")
        XCTAssertEqual(generatedSuggestion["is_suggestion"] as? Bool, true)

        let countBeforeInvalidParent = comments.comments.count
        let invalidParent = try await call("create-comment", [
            "document_id": id.uuidString, "body": "must not be stored", "parent_id": "not-a-uuid",
        ])
        XCTAssertEqual(invalidParent.status, 400)
        XCTAssertEqual(comments.comments.count, countBeforeInvalidParent)

        let generatedReply = try await call("create-comment", [
            "document_id": id.uuidString,
            "body": "Thread reply",
            "parent_id": generatedRootID,
            "proposed_text": "revised agent",
            "author_agent_id": "reply-agent",
            "author_name": "Reply Agent",
        ])
        XCTAssertEqual(generatedReply.status, 200, String(decoding: generatedReply.body, as: UTF8.self))
        let generatedReplyRecord = try XCTUnwrap(value(generatedReply) as? [String: Any])
        XCTAssertEqual(generatedReplyRecord["parent_id"] as? String, generatedRootID)
        XCTAssertEqual(generatedReplyRecord["proposed_text"] as? String, "revised agent")
        XCTAssertEqual(generatedReplyRecord["author_agent_id"] as? String, "reply-agent")
        XCTAssertEqual(generatedReplyRecord["author"] as? String, "Reply Agent")
        XCTAssertEqual(generatedReplyRecord["range"] as? [String: Int],
                       generatedRoot["range"] as? [String: Int])
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == generatedRootID }?.textRange,
                       comments.comments.first {
                           $0.id.uuidString == generatedReplyRecord["id"] as? String
                       }?.textRange,
                       "Replies must keep the root's live UTF-16 range")

        let retiredAgentList = await router.route(HTTPRequest(
            method: "GET", path: "/api/documents/\(id.uuidString)/comments",
            queryParams: ["authorAgentId": "reply-agent"]))
        XCTAssertEqual(retiredAgentList.status, 404)
        let generatedAgentList = try await call("list-comments", [
            "document_id": id.uuidString, "author_agent_id": "reply-agent",
        ])
        XCTAssertEqual(generatedAgentList.status, 200)
        let generatedAgentRows = try XCTUnwrap(value(generatedAgentList) as? [[String: Any]])
        XCTAssertEqual(generatedAgentRows.count, 1)
        XCTAssertEqual(generatedAgentRows.first?["parent_id"] as? String, generatedRootID)

        // Acceptance stays available through the generated verb; the HTTP
        // registration is retired while preserving the same live-editor effect.
        let rootRange = try XCTUnwrap(comments.comments.first { $0.id.uuidString == generatedRootID }?.textRange)
        let expectedAfterRootAccept = (session.source as NSString).replacingCharacters(
            in: NSRange(location: rootRange.start, length: rootRange.length), with: "🧪")
        let retiredAccept = await router.route(HTTPRequest(
            method: "POST", path: "/api/comments/\(generatedRootID)/accept"))
        XCTAssertEqual(retiredAccept.status, 404)
        let generatedRootAccept = try await call("accept-comment-suggestion", ["comment_id": generatedRootID])
        XCTAssertEqual(generatedRootAccept.status, 200, String(decoding: generatedRootAccept.body, as: UTF8.self))
        let generatedRootAcceptBody = try XCTUnwrap(value(generatedRootAccept) as? [String: Any])
        XCTAssertEqual(generatedRootAcceptBody["accepted"] as? Bool, true)
        XCTAssertEqual(generatedRootAcceptBody["comment_id"] as? String, generatedRootID)
        XCTAssertEqual(generatedRootAcceptBody["document_id"] as? String, id.uuidString)
        let rootOperationID = try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(generatedRootAcceptBody["operation_id"] as? String)))
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == generatedRootID }?.isResolved, true)
        XCTAssertEqual(session.source, expectedAfterRootAccept)
        XCTAssertEqual(ManuscriptStoreAdapter.shared.manuscript(id: id)?.body, expectedAfterRootAccept)
        XCTAssertEqual(OperationTracker.shared.get(id: rootOperationID)?.kind, "acceptSuggestion")
        XCTAssertEqual(OperationTracker.shared.get(id: rootOperationID)?.status.rawValue, "completed")

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

        // Rejecting also resolves without editing, via the generated verb.
        let rejectRootResponse = try await call("create-comment", [
            "document_id": id.uuidString,
            "body": "Reject this suggestion",
            "proposed_text": "unused replacement",
        ])
        XCTAssertEqual(rejectRootResponse.status, 200)
        let rejectRoot = try XCTUnwrap(value(rejectRootResponse) as? [String: Any])
        let rejectRootID = try XCTUnwrap(rejectRoot["id"] as? String)
        let sourceBeforeRejectRoot = session.source
        let retiredReject = await router.route(HTTPRequest(
            method: "POST", path: "/api/comments/\(rejectRootID)/reject"))
        XCTAssertEqual(retiredReject.status, 404)
        let generatedReject = try await call("reject-comment-suggestion", ["comment_id": rejectRootID])
        XCTAssertEqual(generatedReject.status, 200)
        XCTAssertEqual(try value(generatedReject) as? Bool, true)
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == rejectRootID }?.isResolved, true)
        XCTAssertEqual(session.source, sourceBeforeRejectRoot)

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
        let retiredPatch = await router.route(HTTPRequest(
            method: "PATCH", path: "/api/comments/\(commentID)", body: #"{"content":"retired"}"#))
        XCTAssertEqual(retiredPatch.status, 404)
        XCTAssertEqual(comments.comments.first { $0.id.uuidString == commentID }?.content, "Check this phrase")
        let retiredDelete = await router.route(HTTPRequest(
            method: "DELETE", path: "/api/comments/\(commentID)"))
        XCTAssertEqual(retiredDelete.status, 404)
        let generatedDelete = try await call("delete-comment", ["comment_id": commentID])
        XCTAssertEqual(generatedDelete.status, 200)
        XCTAssertEqual(try value(generatedDelete) as? Bool, true)
        XCTAssertFalse(comments.comments.contains { $0.id.uuidString == commentID })
    }

    private func requireIsolation(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "ImpressP5bProofIsolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
