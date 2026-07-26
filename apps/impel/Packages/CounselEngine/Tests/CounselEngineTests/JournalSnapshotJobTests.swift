//
//  JournalSnapshotJobTests.swift
//  CounselEngineTests
//
//  Phase 3 tests for the Archivist worker. Verifies snapshot creation,
//  idempotency via content_hash check, and parent-manuscript update.
//

import CryptoKit
import Foundation
import Testing
@testable import CounselEngine

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

// MARK: - Helpers

private func freshStores() throws -> (JournalSnapshotJob, SharedStore, String) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JournalSnapshotJobTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let dbPath = tempDir.appendingPathComponent("test.sqlite").path
    let job = try JournalSnapshotJob(testStorePath: dbPath)
    let probeStore = try SharedStore.open(path: dbPath)
    return (job, probeStore, dbPath)
}

/// Seed a manuscript@1.0.0 item in the store so snapshot has something to update.
private func seedManuscript(in store: SharedStore, title: String) throws -> String {
    let id = UUID().uuidString.lowercased()
    let payload: [String: Any] = [
        "title": title,
        "status": "draft",
        "current_revision_ref": "00000000-0000-0000-0000-000000000000",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try store.upsertItem(id: id, schemaRef: "manuscript", payloadJson: String(data: data, encoding: .utf8)!)
    return id
}

private func decodePayload(_ json: String) throws -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { Issue.record("payload not JSON object"); return [:] }
    return obj
}

// MARK: - Snapshot creation

@Test func snapshotCreatesRevisionAndUpdatesParent() async throws {
    let (job, store, _) = try freshStores()
    let parentID = try seedManuscript(in: store, title: "Two-Point Function")

    let result = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: "\\section{Intro}\nbody text\n",
        revisionTag: "v1",
        reason: "manual"
    )

    #expect(result.wasNoOp == false)
    #expect(result.revisionID != nil)

    // Revision item exists with the right fields.
    let revID = result.revisionID!
    let revRow = try #require(try store.getItem(id: revID))
    let revPayload = try decodePayload(revRow.payloadJson)
    #expect(revPayload["parent_manuscript_ref"] as? String == parentID)
    #expect(revPayload["revision_tag"] as? String == "v1")
    #expect(revPayload["content_hash"] as? String == result.contentHash)
    #expect(revPayload["snapshot_reason"] as? String == "manual")
    // Source archive ref points to the blob namespace by hash.
    let sourceRef = revPayload["source_archive_ref"] as? String
    #expect(sourceRef?.hasPrefix("blob:sha256:") == true)
    #expect(sourceRef?.contains(result.contentHash) == true)

    // Parent manuscript's current_revision_ref now points at the new revision.
    let parentRow = try #require(try store.getItem(id: parentID))
    let parentPayload = try decodePayload(parentRow.payloadJson)
    #expect(parentPayload["current_revision_ref"] as? String == revID)
}

@Test func contentHashMatchesSHA256OfSource() async throws {
    let (job, store, _) = try freshStores()
    let parentID = try seedManuscript(in: store, title: "Hash Check")
    let source = "exact source bytes"
    let result = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: source,
        revisionTag: "v1",
        reason: "manual"
    )
    let expected = SHA256.hash(data: Data(source.utf8))
        .compactMap { String(format: "%02x", $0) }
        .joined()
    #expect(result.contentHash == expected)
}

// MARK: - Idempotency

@Test func snapshotIsIdempotentWhenContentMatchesCurrentRevision() async throws {
    let (job, store, _) = try freshStores()
    let parentID = try seedManuscript(in: store, title: "Idempotent")
    let source = "stable source"

    let first = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: source,
        revisionTag: "v1",
        reason: "manual"
    )
    #expect(first.wasNoOp == false)

    let second = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: source,
        revisionTag: "v2-attempt",
        reason: "manual"
    )
    #expect(second.wasNoOp == true)
    #expect(second.revisionID == nil)
    #expect(second.contentHash == first.contentHash)

    // Parent still points at the first revision; no new revision item created.
    let parentRow = try #require(try store.getItem(id: parentID))
    let parentPayload = try decodePayload(parentRow.payloadJson)
    #expect(parentPayload["current_revision_ref"] as? String == first.revisionID!)
}

@Test func differentContentProducesNewRevisionAndPredecessorEdge() async throws {
    let (job, store, _) = try freshStores()
    let parentID = try seedManuscript(in: store, title: "Two revisions")

    let v1 = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: "first version",
        revisionTag: "v1",
        reason: "manual"
    )
    let v2 = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: "second version with more content",
        revisionTag: "v2",
        reason: "manual"
    )
    #expect(v2.wasNoOp == false)
    #expect(v2.revisionID != v1.revisionID)

    // The new revision points back to the predecessor.
    let revRow = try #require(try store.getItem(id: v2.revisionID!))
    let revPayload = try decodePayload(revRow.payloadJson)
    #expect(revPayload["predecessor_revision_ref"] as? String == v1.revisionID!)

    // First revision did NOT have a predecessor (was the initial snapshot).
    let firstRow = try #require(try store.getItem(id: v1.revisionID!))
    let firstPayload = try decodePayload(firstRow.payloadJson)
    #expect(firstPayload["predecessor_revision_ref"] == nil)
}

// MARK: - Errors

@Test func snapshotOfMissingManuscriptThrowsNotFound() async throws {
    let (job, _, _) = try freshStores()
    do {
        _ = try await job.snapshot(
            manuscriptID: UUID().uuidString.lowercased(),
            sourceContent: "x",
            revisionTag: "v1",
            reason: "manual"
        )
        Issue.record("expected manuscriptNotFound")
    } catch JournalSnapshotError.manuscriptNotFound { /* ok */ }
    catch { Issue.record("unexpected error: \(error)") }
}

// MARK: - Compile integration (Phase 6)

/// Build a JournalSnapshotJob backed by an in-memory store + a real
/// ImprintCompileClient pointed at a per-test-keyed MockURLProtocol so
/// concurrent suites don't clobber each other's handlers.
private func freshSetupWithMockCompile(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) throws -> (JournalSnapshotJob, SharedStore, URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JournalSnapshotJobCompileTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let dbPath = tempDir.appendingPathComponent("test.sqlite").path
    let blobRoot = tempDir.appendingPathComponent("blobs", isDirectory: true)

    let (session, baseURL) = makeIsolatedSession(handler: handler)
    let client = ImprintCompileClient(baseURL: baseURL, session: session, requestTimeout: 2)
    let job = try JournalSnapshotJob(testStorePath: dbPath, compileClient: client, blobRootURL: blobRoot)
    let store = try SharedStore.open(path: dbPath)
    return (job, store, blobRoot)
}

@Suite(.serialized)
struct JournalSnapshotJobCompileTests {

@Test func snapshotWritesRealPDFRefWhenCompileSucceeds() async throws {
    let pdfBytes = Data("%PDF-1.4\nfake pdf body\n".utf8)
    let (job, store, blobRoot) = try freshSetupWithMockCompile { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/pdf",
                "X-Imprint-Compile-Status": "ok",
                "X-Imprint-Page-Count": "2",
                "X-Imprint-Compile-Ms": "100",
            ]
        )!
        return (response, pdfBytes)
    }
    let parentID = try seedManuscript(in: store, title: "Compile-success test")
    let result = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: "= Hello\n\nbody",
        revisionTag: "v1",
        reason: "manual"
    )

    let row = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(row.payloadJson)
    let pdfRef = try #require(payload["pdf_artifact_ref"] as? String)
    #expect(pdfRef.hasPrefix("blob:sha256:"), "expected real blob ref, got \(pdfRef)")
    #expect(payload["compile_status"] as? String == "ok")
    #expect(payload["page_count"] as? Int == 2)

    // Verify the PDF bytes landed on disk in the content-addressed location.
    let pdfHash = String(pdfRef.dropFirst("blob:sha256:".count))
    let prefix1 = String(pdfHash.prefix(2))
    let prefix2 = String(pdfHash.dropFirst(2).prefix(2))
    let pdfURL = blobRoot
        .appendingPathComponent(prefix1)
        .appendingPathComponent(prefix2)
        .appendingPathComponent("\(pdfHash).pdf")
    #expect(FileManager.default.fileExists(atPath: pdfURL.path),
            "PDF should be written at \(pdfURL.path)")
    let writtenBytes = try Data(contentsOf: pdfURL)
    #expect(writtenBytes == pdfBytes)
}

@Test func snapshotKeepsPlaceholderWhenImprintUnreachable() async throws {
    let (job, store, _) = try freshSetupWithMockCompile { _ in
        throw URLError(.cannotConnectToHost)
    }
    let parentID = try seedManuscript(in: store, title: "Imprint-down test")
    let result = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: "= Hi",
        revisionTag: "v1",
        reason: "manual"
    )
    let row = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(row.payloadJson)
    #expect(payload["pdf_artifact_ref"] as? String == "00000000-0000-0000-0000-000000000001",
            "expected placeholder PDF ref when imprint unreachable")
    #expect(payload["compile_status"] as? String == "deferred")
    #expect((payload["compile_error"] as? String)?.contains("not reachable") == true)
}

@Test func snapshotRecordsCompileErrorOn422() async throws {
    let (job, store, _) = try freshSetupWithMockCompile { request in
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "error",
            "error": "expected closing brace at line 12",
            "warnings": [],
            "compile_ms": 50,
        ] as [String: Any])
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 422,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (response, body)
    }
    let parentID = try seedManuscript(in: store, title: "Bad source test")
    let result = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: "= broken {",
        revisionTag: "v1",
        reason: "manual"
    )
    let row = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(row.payloadJson)
    #expect(payload["pdf_artifact_ref"] as? String == "00000000-0000-0000-0000-000000000001",
            "expected placeholder PDF ref on compile error")
    #expect(payload["compile_status"] as? String == "error")
    #expect((payload["compile_error"] as? String)?.contains("closing brace") == true)
}

}  // end @Suite

@Test func wordCountIsRecorded() async throws {
    let (job, store, _) = try freshStores()
    let parentID = try seedManuscript(in: store, title: "Word count")
    let result = try await job.snapshot(
        manuscriptID: parentID,
        sourceContent: "one two three four five",
        revisionTag: "v1",
        reason: "manual"
    )
    let row = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(row.payloadJson)
    let wc = (payload["word_count"] as? Int) ?? (payload["word_count"] as? NSNumber)?.intValue
    #expect(wc == 5)
}

// MARK: - Phase 8: bundle-source snapshot

@Test func bundleSnapshotWritesRealArchiveRefAndManifest() async throws {
    let (job, store, _) = try freshStores()
    let parentID = try seedManuscript(in: store, title: "Bundle Manuscript")

    let manifest = ManuscriptBundleManifest(
        mainSource: "paper.typ",
        sourceFormat: .typst,
        entries: [
            BundleEntry(path: "paper.typ", role: .main),
            BundleEntry(path: "figures/diagram.png", role: .figure),
        ],
        compile: BundleCompileSpec(engine: .typst)
    )
    let bundleSHA = String(repeating: "ab", count: 32) // 64 hex chars
    let result = try await job.snapshot(
        manuscriptID: parentID,
        source: .bundle(sha256: bundleSHA, manifest: manifest),
        revisionTag: "v1",
        reason: "manual"
    )
    #expect(result.wasNoOp == false)
    #expect(result.contentHash == bundleSHA)

    let revRow = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(revRow.payloadJson)
    // source_archive_ref now points at a real .tar.zst, not the placeholder.
    let sourceRef = payload["source_archive_ref"] as? String
    #expect(sourceRef == "blob:sha256:\(bundleSHA).tar.zst")
    // bundle_manifest_json carries the canonical manifest.
    let manifestJSON = payload["bundle_manifest_json"] as? String
    #expect(manifestJSON != nil)
    if let manifestJSON {
        let parsed = try ManuscriptBundleManifest.parse(manifestJSON)
        #expect(parsed.mainSource == "paper.typ")
        #expect(parsed.entries.count == 2)
    }
    // word_count is omitted for bundle revisions (the bundle bytes aren't
    // a word-countable text body).
    #expect(payload["word_count"] == nil)
    // compile_status is "deferred" until Phase 8.10/8.11 wires bundle compile.
    #expect(payload["compile_status"] as? String == "deferred")
}

@Test func bundleSnapshotWithEngineNoneIsSkipped() async throws {
    let (job, store, _) = try freshStores()
    let parentID = try seedManuscript(in: store, title: "Markdown Bundle")

    let manifest = ManuscriptBundleManifest(
        mainSource: "notes.md",
        sourceFormat: .markdown,
        entries: [BundleEntry(path: "notes.md", role: .main)],
        compile: BundleCompileSpec(engine: .none)
    )
    let bundleSHA = String(repeating: "cd", count: 32)
    let result = try await job.snapshot(
        manuscriptID: parentID,
        source: .bundle(sha256: bundleSHA, manifest: manifest),
        revisionTag: "v1",
        reason: "manual"
    )
    let revRow = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(revRow.payloadJson)
    // engine=none → compile_status: "skipped" (not "deferred").
    #expect(payload["compile_status"] as? String == "skipped")
}

@Test func bundleSnapshotIsIdempotentByArchiveSHA() async throws {
    let (job, store, _) = try freshStores()
    let parentID = try seedManuscript(in: store, title: "Idempotent Bundle")
    let manifest = ManuscriptBundleManifest(
        mainSource: "p.typ",
        sourceFormat: .typst,
        entries: [BundleEntry(path: "p.typ", role: .main)],
        compile: BundleCompileSpec(engine: .typst)
    )
    let sha = String(repeating: "ef", count: 32)

    let r1 = try await job.snapshot(
        manuscriptID: parentID,
        source: .bundle(sha256: sha, manifest: manifest),
        revisionTag: "v1",
        reason: "manual"
    )
    #expect(r1.wasNoOp == false)
    let r2 = try await job.snapshot(
        manuscriptID: parentID,
        source: .bundle(sha256: sha, manifest: manifest),
        revisionTag: "v2",
        reason: "manual"
    )
    #expect(r2.wasNoOp == true)
    #expect(r2.contentHash == sha)
}

// MARK: - Phase 8.11: bundle compile integration

@Suite(.serialized)
struct JournalSnapshotJobBundleCompileTests {

@Test func bundleSnapshotWritesRealPDFRefWhenBundleCompileSucceeds() async throws {
    let pdfBytes = Data("%PDF-1.4\nbundle pdf bytes\n".utf8)
    let (job, store, blobRoot) = try freshSetupWithMockCompile { request in
        // Verify the route + body shape.
        #expect(request.url?.path == "/api/compile/bundle")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/pdf",
                "X-Imprint-Compile-Status": "ok",
                "X-Imprint-Page-Count": "4",
                "X-Imprint-Compile-Ms": "350",
            ]
        )!
        return (response, pdfBytes)
    }
    let parentID = try seedManuscript(in: store, title: "Bundle Compile Test")
    let manifest = ManuscriptBundleManifest(
        mainSource: "paper.typ",
        sourceFormat: .typst,
        entries: [BundleEntry(path: "paper.typ", role: .main)],
        compile: BundleCompileSpec(engine: .typst)
    )
    let bundleSHA = String(repeating: "12", count: 32)

    let result = try await job.snapshot(
        manuscriptID: parentID,
        source: .bundle(sha256: bundleSHA, manifest: manifest),
        revisionTag: "v1",
        reason: "manual"
    )

    let row = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(row.payloadJson)
    let pdfRef = try #require(payload["pdf_artifact_ref"] as? String)
    #expect(pdfRef.hasPrefix("blob:sha256:"))
    #expect(payload["compile_status"] as? String == "ok")
    #expect(payload["page_count"] as? Int == 4)

    // PDF bytes landed in the content-addressed location.
    let pdfHash = String(pdfRef.dropFirst("blob:sha256:".count))
    let pdfURL = blobRoot
        .appendingPathComponent(String(pdfHash.prefix(2)))
        .appendingPathComponent(String(pdfHash.dropFirst(2).prefix(2)))
        .appendingPathComponent("\(pdfHash).pdf")
    #expect(FileManager.default.fileExists(atPath: pdfURL.path))
    let writtenBytes = try Data(contentsOf: pdfURL)
    #expect(writtenBytes == pdfBytes)
}

@Test func bundleSnapshotRecordsEngineUnavailableOnHTTP503() async throws {
    let (job, store, _) = try freshSetupWithMockCompile { request in
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "error",
            "error": "LaTeX engine xelatex not installed (no TeX distribution detected)",
        ] as [String: Any])
        return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: [:])!, body)
    }
    let parentID = try seedManuscript(in: store, title: "Engine-Missing Test")
    let manifest = ManuscriptBundleManifest(
        mainSource: "paper.tex",
        sourceFormat: .tex,
        entries: [BundleEntry(path: "paper.tex", role: .main)],
        compile: BundleCompileSpec(engine: .xelatex)
    )
    let result = try await job.snapshot(
        manuscriptID: parentID,
        source: .bundle(sha256: String(repeating: "ab", count: 32), manifest: manifest),
        revisionTag: "v1",
        reason: "manual"
    )
    let row = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(row.payloadJson)
    #expect(payload["compile_status"] as? String == "engine-unavailable")
    #expect((payload["compile_error"] as? String)?.contains("xelatex") == true)
    // PDF stays placeholder.
    #expect(payload["pdf_artifact_ref"] as? String == "00000000-0000-0000-0000-000000000001")
}

@Test func bundleSnapshotKeepsPlaceholderWhenImprintUnreachable() async throws {
    let (job, store, _) = try freshSetupWithMockCompile { _ in
        throw URLError(.cannotConnectToHost)
    }
    let parentID = try seedManuscript(in: store, title: "Imprint-Down Bundle Test")
    let manifest = ManuscriptBundleManifest(
        mainSource: "paper.typ",
        sourceFormat: .typst,
        entries: [BundleEntry(path: "paper.typ", role: .main)],
        compile: BundleCompileSpec(engine: .typst)
    )
    let result = try await job.snapshot(
        manuscriptID: parentID,
        source: .bundle(sha256: String(repeating: "ab", count: 32), manifest: manifest),
        revisionTag: "v1",
        reason: "manual"
    )
    let row = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(row.payloadJson)
    #expect(payload["compile_status"] as? String == "deferred")
    #expect((payload["compile_error"] as? String)?.contains("not reachable") == true)
}

@Test func bundleSnapshotRecordsCompileErrorOn422() async throws {
    let (job, store, _) = try freshSetupWithMockCompile { request in
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "error",
            "error": "Typst syntax error: unexpected token at line 5",
            "warnings": [],
            "compile_ms": 50,
        ] as [String: Any])
        return (HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: "HTTP/1.1", headerFields: [:])!, body)
    }
    let parentID = try seedManuscript(in: store, title: "Broken Bundle Test")
    let manifest = ManuscriptBundleManifest(
        mainSource: "paper.typ",
        sourceFormat: .typst,
        entries: [BundleEntry(path: "paper.typ", role: .main)],
        compile: BundleCompileSpec(engine: .typst)
    )
    let result = try await job.snapshot(
        manuscriptID: parentID,
        source: .bundle(sha256: String(repeating: "cd", count: 32), manifest: manifest),
        revisionTag: "v1",
        reason: "manual"
    )
    let row = try #require(try store.getItem(id: result.revisionID!))
    let payload = try decodePayload(row.payloadJson)
    #expect(payload["compile_status"] as? String == "error")
    #expect((payload["compile_error"] as? String)?.contains("syntax error") == true)
}

}
