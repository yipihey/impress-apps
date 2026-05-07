//
//  ManuscriptBridgeTests.swift
//  PublicationManagerCoreTests
//
//  Phase 2.2 tests: round-trip create/list/getStatus/setStatus/accept/reject
//  against an in-memory SharedStore handle.
//

import XCTest
@testable import PublicationManagerCore

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

final class ManuscriptBridgeTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManuscriptBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func freshBridge() throws -> (ManuscriptBridge, String) {
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        return (try ManuscriptBridge(testStorePath: dbPath), dbPath)
    }

    // MARK: - Manuscript create/get/list

    func testCreateThenGetReturnsManuscript() async throws {
        let (bridge, _) = try freshBridge()
        let id = try await bridge.createManuscript(title: "Two-Point Function of T3FT")

        let m = await bridge.getManuscript(id: id)
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.id, id)
        XCTAssertEqual(m?.title, "Two-Point Function of T3FT")
        XCTAssertEqual(m?.status, .draft)
        XCTAssertEqual(m?.currentRevisionRef, JournalRevisionPlaceholderID)
    }

    func testCreatedIDIsLowercaseUUID() async throws {
        let (bridge, _) = try freshBridge()
        let id = try await bridge.createManuscript(title: "Lowercase test")
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNotNil(UUID(uuidString: id))
    }

    func testListManuscriptsReturnsCreatedItems() async throws {
        let (bridge, _) = try freshBridge()
        let id1 = try await bridge.createManuscript(title: "Paper A")
        let id2 = try await bridge.createManuscript(title: "Paper B")

        let all = await bridge.listManuscripts()
        let ids = Set(all.map(\.id))
        XCTAssertTrue(ids.contains(id1))
        XCTAssertTrue(ids.contains(id2))
    }

    func testListManuscriptsFiltersByStatus() async throws {
        let (bridge, _) = try freshBridge()
        let draftID = try await bridge.createManuscript(title: "Drafted")
        let submittedID = try await bridge.createManuscript(title: "To submit")
        try await bridge.setStatus(manuscriptID: submittedID, status: .submitted)

        let drafts = await bridge.listManuscripts(status: .draft)
        let submitted = await bridge.listManuscripts(status: .submitted)

        XCTAssertTrue(drafts.contains { $0.id == draftID })
        XCTAssertFalse(drafts.contains { $0.id == submittedID })
        XCTAssertTrue(submitted.contains { $0.id == submittedID })
        XCTAssertFalse(submitted.contains { $0.id == draftID })
    }

    // MARK: - Status transitions

    func testSetStatusUpdatesPersistedValue() async throws {
        let (bridge, _) = try freshBridge()
        let id = try await bridge.createManuscript(title: "Lifecycle test")

        try await bridge.setStatus(manuscriptID: id, status: .internalReview)
        let afterReview = await bridge.getManuscript(id: id)
        XCTAssertEqual(afterReview?.status, .internalReview)

        try await bridge.setStatus(manuscriptID: id, status: .submitted)
        let afterSubmit = await bridge.getManuscript(id: id)
        XCTAssertEqual(afterSubmit?.status, .submitted)
    }

    func testSetStatusOnMissingManuscriptThrowsNotFound() async throws {
        let (bridge, _) = try freshBridge()
        do {
            try await bridge.setStatus(manuscriptID: UUID().uuidString.lowercased(), status: .submitted)
            XCTFail("expected notFound")
        } catch ManuscriptBridgeError.notFound { /* ok */ }
        catch { XCTFail("unexpected error: \(error)") }
    }

    // MARK: - imprint source bridge

    func testAttachImprintSourceStoresFields() async throws {
        let (bridge, _) = try freshBridge()
        let id = try await bridge.createManuscript(title: "With imprint source")
        let docUUID = UUID().uuidString
        let libUUID = UUID().uuidString
        try await bridge.attachImprintSource(
            manuscriptID: id,
            documentUUID: docUUID,
            libraryUUID: libUUID,
            packagePath: "/tmp/some.imprint"
        )
        let resolved = await bridge.imprintDocumentUUID(forManuscript: id)
        XCTAssertEqual(resolved, docUUID)
    }

    func testImprintDocumentUUIDIsNilBeforeAttachment() async throws {
        let (bridge, _) = try freshBridge()
        let id = try await bridge.createManuscript(title: "Unbridged")
        let resolved = await bridge.imprintDocumentUUID(forManuscript: id)
        XCTAssertNil(resolved)
    }

    // MARK: - Submissions accept/reject

    /// Seed a submission directly via SharedStore to mirror what
    /// CounselEngine's JournalSubmissionService would write in production.
    private func seedSubmission(
        dbPath: String,
        title: String,
        kind: JournalSubmissionKind,
        parentManuscriptRef: String? = nil
    ) throws -> String {
        #if canImport(ImpressRustCore)
        let store = try SharedStore.open(path: dbPath)
        let id = UUID().uuidString.lowercased()
        var payload: [String: Any] = [
            "title": title,
            "submission_kind": kind.rawValue,
            "source_format": "tex",
            "source_payload": "\\section{Test}\\n",
            "state": "pending",
            "content_hash": String(repeating: "a", count: 64),
        ]
        if let p = parentManuscriptRef { payload["parent_manuscript_ref"] = p }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try store.upsertItem(id: id, schemaRef: "manuscript-submission", payloadJson: String(data: data, encoding: .utf8)!)
        return id
        #else
        XCTFail("ImpressRustCore not available")
        return ""
        #endif
    }

    func testListPendingSubmissionsReturnsSeededItems() async throws {
        let (bridge, dbPath) = try freshBridge()
        let s1 = try seedSubmission(dbPath: dbPath, title: "Pending 1", kind: .newManuscript)
        let s2 = try seedSubmission(dbPath: dbPath, title: "Pending 2", kind: .newManuscript)

        let pending = await bridge.listPendingSubmissions()
        let ids = Set(pending.map(\.id))
        XCTAssertTrue(ids.contains(s1))
        XCTAssertTrue(ids.contains(s2))
        XCTAssertEqual(pending.first(where: { $0.id == s1 })?.title, "Pending 1")
    }

    func testAcceptNewManuscriptCreatesManuscriptAndAdvancesState() async throws {
        let (bridge, dbPath) = try freshBridge()
        let s = try seedSubmission(dbPath: dbPath, title: "Accept me", kind: .newManuscript)

        let manuscriptID = try await bridge.acceptSubmission(id: s, outcome: .newManuscript)
        XCTAssertNotNil(manuscriptID)

        // Submission state advances to accepted.
        let updated = await bridge.getSubmission(id: s)
        XCTAssertEqual(updated?.state, .accepted)

        // Manuscript exists in Drafts.
        let m = await bridge.getManuscript(id: manuscriptID!)
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.title, "Accept me")
        XCTAssertEqual(m?.status, .draft)

        // Pending list no longer contains the submission.
        let pending = await bridge.listPendingSubmissions()
        XCTAssertFalse(pending.contains { $0.id == s })
    }

    func testAcceptNewRevisionDoesNotCreateManuscript() async throws {
        let (bridge, dbPath) = try freshBridge()
        let parent = try await bridge.createManuscript(title: "Parent")
        let s = try seedSubmission(
            dbPath: dbPath,
            title: "Revision proposal",
            kind: .newRevision,
            parentManuscriptRef: parent
        )

        let result = try await bridge.acceptSubmission(id: s, outcome: .newRevisionOf(manuscriptID: parent))
        XCTAssertNil(result, "newRevisionOf must not create a new manuscript")

        let updated = await bridge.getSubmission(id: s)
        XCTAssertEqual(updated?.state, .accepted)

        // Parent manuscript still exists, unchanged.
        let parentStill = await bridge.getManuscript(id: parent)
        XCTAssertNotNil(parentStill)
    }

    // MARK: - Revisions (Phase 3)

    /// Seed a manuscript-revision item directly into the store, mirroring
    /// what JournalSnapshotJob (impel side) would write in production.
    private func seedRevision(
        dbPath: String,
        parentManuscriptRef: String,
        tag: String,
        contentHash: String
    ) throws -> String {
        #if canImport(ImpressRustCore)
        let store = try SharedStore.open(path: dbPath)
        let id = UUID().uuidString.lowercased()
        let payload: [String: Any] = [
            "parent_manuscript_ref": parentManuscriptRef,
            "revision_tag": tag,
            "content_hash": contentHash,
            "pdf_artifact_ref": "00000000-0000-0000-0000-000000000001",
            "source_archive_ref": "blob:sha256:\(contentHash)",
            "snapshot_reason": "manual",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try store.upsertItem(id: id, schemaRef: "manuscript-revision", payloadJson: String(data: data, encoding: .utf8)!)
        return id
        #else
        XCTFail("ImpressRustCore not available")
        return ""
        #endif
    }

    func testListRevisionsReturnsRevisionsForManuscript() async throws {
        let (bridge, dbPath) = try freshBridge()
        let parent = try await bridge.createManuscript(title: "Has revisions")
        let other = try await bridge.createManuscript(title: "Other manuscript")

        let r1 = try seedRevision(dbPath: dbPath, parentManuscriptRef: parent, tag: "v1", contentHash: String(repeating: "1", count: 64))
        let r2 = try seedRevision(dbPath: dbPath, parentManuscriptRef: parent, tag: "v2", contentHash: String(repeating: "2", count: 64))
        _ = try seedRevision(dbPath: dbPath, parentManuscriptRef: other, tag: "v1", contentHash: String(repeating: "3", count: 64))

        let revisions = await bridge.listRevisions(manuscriptID: parent)
        let ids = Set(revisions.map(\.id))
        XCTAssertTrue(ids.contains(r1))
        XCTAssertTrue(ids.contains(r2))
        XCTAssertEqual(revisions.count, 2, "must filter out revisions of other manuscripts")
    }

    func testGetRevisionByIDDecodesPayload() async throws {
        let (bridge, dbPath) = try freshBridge()
        let parent = try await bridge.createManuscript(title: "P")
        let revID = try seedRevision(dbPath: dbPath, parentManuscriptRef: parent, tag: "submitted", contentHash: String(repeating: "a", count: 64))

        let rev = await bridge.getRevision(id: revID)
        XCTAssertNotNil(rev)
        XCTAssertEqual(rev?.parentManuscriptRef, parent)
        XCTAssertEqual(rev?.revisionTag, "submitted")
    }

    func testListRevisionsForManuscriptWithNoneReturnsEmpty() async throws {
        let (bridge, _) = try freshBridge()
        let parent = try await bridge.createManuscript(title: "Pristine")
        let revisions = await bridge.listRevisions(manuscriptID: parent)
        XCTAssertEqual(revisions.count, 0)
    }

    func testRejectSubmissionAdvancesStateToCancelled() async throws {
        let (bridge, dbPath) = try freshBridge()
        let s = try seedSubmission(dbPath: dbPath, title: "Reject me", kind: .newManuscript)

        try await bridge.rejectSubmission(id: s, reason: "not aligned")
        let updated = await bridge.getSubmission(id: s)
        XCTAssertEqual(updated?.state, .cancelled)

        let pending = await bridge.listPendingSubmissions()
        XCTAssertFalse(pending.contains { $0.id == s })
    }
}
