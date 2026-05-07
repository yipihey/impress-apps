//
//  ManuscriptMboxExportTests.swift
//  PublicationManagerCoreTests
//
//  Phase 5.3 tests: MboxExporter.exportManuscripts produces a valid
//  mbox file with one message per manuscript and per-revision attachments.
//

import XCTest
@testable import PublicationManagerCore

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

final class ManuscriptMboxExportTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManuscriptMboxExportTests-\(UUID().uuidString)", isDirectory: true)
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

    private func seedRevision(
        dbPath: String,
        parentManuscriptRef: String,
        tag: String,
        contentHash: String
    ) throws -> String {
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
        try store.upsertItem(
            id: id,
            schemaRef: "manuscript-revision",
            payloadJson: String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8)!
        )
        return id
    }

    // MARK: - Tests

    func testExportProducesMboxFileWithMessagePerManuscript() async throws {
        let (bridge, dbPath) = try freshBridge()
        let m1 = try await bridge.createManuscript(title: "Manuscript A")
        let m2 = try await bridge.createManuscript(title: "Manuscript B")
        _ = try seedRevision(dbPath: dbPath, parentManuscriptRef: m1, tag: "v1", contentHash: String(repeating: "1", count: 64))
        _ = try seedRevision(dbPath: dbPath, parentManuscriptRef: m2, tag: "v1", contentHash: String(repeating: "2", count: 64))

        let outputURL = tempDir.appendingPathComponent("export.mbox")
        let exporter = MboxExporter()
        try await exporter.exportManuscripts(
            manuscriptIDs: [m1, m2],
            bridge: bridge,
            to: outputURL
        )

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        // mbox messages start with "From " envelope lines.
        let messageCount = content.components(separatedBy: "\nFrom ").count
        XCTAssertGreaterThanOrEqual(messageCount, 2, "expected at least 2 messages, got \(messageCount)")
        XCTAssertTrue(content.contains("Manuscript A"))
        XCTAssertTrue(content.contains("Manuscript B"))
        // Custom journal headers must appear.
        XCTAssertTrue(content.contains("X-Imbib-Journal-Manuscript-ID"))
        XCTAssertTrue(content.contains("X-Imbib-Journal-Revision-Count"))
    }

    func testExportEmbedsRevisionAttachments() async throws {
        let (bridge, dbPath) = try freshBridge()
        let m = try await bridge.createManuscript(title: "Two-revision paper")
        _ = try seedRevision(dbPath: dbPath, parentManuscriptRef: m, tag: "v1", contentHash: String(repeating: "a", count: 64))
        _ = try seedRevision(dbPath: dbPath, parentManuscriptRef: m, tag: "v2-submitted", contentHash: String(repeating: "b", count: 64))

        let outputURL = tempDir.appendingPathComponent("two-rev.mbox")
        let exporter = MboxExporter()
        try await exporter.exportManuscripts(
            manuscriptIDs: [m],
            bridge: bridge,
            to: outputURL
        )

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        // Each revision tag appears in body + attachment custom header.
        XCTAssertTrue(content.contains("v1"))
        XCTAssertTrue(content.contains("v2-submitted"))
        XCTAssertTrue(content.contains("X-Imbib-Journal-Revision-Tag"))
    }

    func testExportSkipsMissingManuscripts() async throws {
        let (bridge, _) = try freshBridge()
        let m = try await bridge.createManuscript(title: "Lonely")
        let bogus = UUID().uuidString.lowercased()

        let outputURL = tempDir.appendingPathComponent("partial.mbox")
        let exporter = MboxExporter()
        try await exporter.exportManuscripts(
            manuscriptIDs: [m, bogus],
            bridge: bridge,
            to: outputURL
        )
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        // The real one is included; the bogus one is skipped.
        XCTAssertTrue(content.contains("Lonely"))
        XCTAssertFalse(content.contains(bogus))
    }
}
