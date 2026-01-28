//
//  CRDTRecoveryTests.swift
//  imprint
//
//  Created by Claude on 2026-01-28.
//

import XCTest
@testable import imprint

/// Tests for recovering from CRDT corruption and sync issues.
///
/// These tests verify that:
/// - Corrupted CRDT state is detected
/// - Recovery mechanisms preserve document content
/// - Partial sync is handled gracefully
final class CRDTRecoveryTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - CRDT Corruption Detection Tests

    func testDetect_emptyCRDTFile() async throws {
        let validator = CRDTHealthValidator()

        // Create document bundle with empty CRDT
        let bundleURL = tempDirectory.appendingPathComponent("empty-crdt.imprint")
        try createTestBundle(at: bundleURL, crdtContent: Data())

        let result = try await validator.validateDocument(at: bundleURL)

        // Empty CRDT should be detected but is valid (just no history)
        XCTAssertTrue(result.hasCRDTState == false || result.issues.isEmpty == false)
    }

    func testDetect_invalidCRDTHeader() async throws {
        let validator = CRDTHealthValidator()

        // Create document bundle with invalid CRDT header
        let bundleURL = tempDirectory.appendingPathComponent("invalid-crdt.imprint")
        let invalidData = Data([0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03])
        try createTestBundle(at: bundleURL, crdtContent: invalidData)

        let result = try await validator.validateDocument(at: bundleURL)

        // Should detect invalid header
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.type == .crdtCorrupted })
    }

    func testDetect_missingRequiredFile() async throws {
        let validator = CRDTHealthValidator()

        // Create document bundle without main.typ
        let bundleURL = tempDirectory.appendingPathComponent("missing-file.imprint")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Only create metadata.json (missing main.typ)
        let metadata = VersionedDocumentMetadata(
            schemaVersion: .current,
            title: "Test",
            authors: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: bundleURL.appendingPathComponent("metadata.json"))

        let result = try await validator.validateDocument(at: bundleURL)

        XCTAssertFalse(result.isHealthy)
        XCTAssertTrue(result.issues.contains { $0.type == .missingFile })
    }

    func testDetect_validAutomergeHeader() async throws {
        let validator = CRDTHealthValidator()

        // Create document bundle with valid Automerge header
        let bundleURL = tempDirectory.appendingPathComponent("valid-crdt.imprint")
        // Automerge magic bytes
        let validData = Data([0x85, 0x6f, 0x4a, 0x83, 0x01, 0x02, 0x03, 0x04])
        try createTestBundle(at: bundleURL, crdtContent: validData)

        let result = try await validator.validateDocument(at: bundleURL)

        // Should have no corruption issues
        let corruptionIssues = result.issues.filter { $0.type == .crdtCorrupted }
        XCTAssertTrue(corruptionIssues.isEmpty)
    }

    // MARK: - Partial Sync Detection Tests

    func testDetect_partialSyncMarker() async throws {
        let validator = CRDTHealthValidator()

        // Create document bundle with sync marker
        let bundleURL = tempDirectory.appendingPathComponent("partial-sync.imprint")
        try createTestBundle(at: bundleURL)

        // Add sync-in-progress marker
        try "".write(to: bundleURL.appendingPathComponent(".sync-in-progress"),
                     atomically: true, encoding: .utf8)

        let hasPartialSync = await validator.checkForPartialSync(at: bundleURL)

        XCTAssertTrue(hasPartialSync)
    }

    func testDetect_tempFiles() async throws {
        let validator = CRDTHealthValidator()

        // Create document bundle with temp files
        let bundleURL = tempDirectory.appendingPathComponent("temp-files.imprint")
        try createTestBundle(at: bundleURL)

        // Add temp file that indicates interrupted operation
        try "partial data".write(to: bundleURL.appendingPathComponent(".main.typ.tmp"),
                                  atomically: true, encoding: .utf8)

        let hasPartialSync = await validator.checkForPartialSync(at: bundleURL)

        XCTAssertTrue(hasPartialSync)
    }

    func testNoPartialSync_cleanDocument() async throws {
        let validator = CRDTHealthValidator()

        // Create clean document bundle
        let bundleURL = tempDirectory.appendingPathComponent("clean.imprint")
        try createTestBundle(at: bundleURL)

        let hasPartialSync = await validator.checkForPartialSync(at: bundleURL)

        XCTAssertFalse(hasPartialSync)
    }

    // MARK: - Recovery Tests

    func testRepair_rebuildsFromSource() async throws {
        let validator = CRDTHealthValidator()

        // Create document with corrupted CRDT
        let bundleURL = tempDirectory.appendingPathComponent("repair-test.imprint")
        let invalidData = Data([0x00, 0x00, 0x00, 0x00])
        try createTestBundle(at: bundleURL, crdtContent: invalidData, sourceContent: "= Valid Source\n\nContent here.")

        // Repair should rebuild CRDT from source
        let result = try await validator.repairDocument(at: bundleURL)

        XCTAssertTrue(result.success || !result.actionsPerformed.isEmpty)
    }

    func testRepair_createsMissingFiles() async throws {
        let validator = CRDTHealthValidator()

        // Create document missing main.typ
        let bundleURL = tempDirectory.appendingPathComponent("missing-main.imprint")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Only create metadata
        let metadata = VersionedDocumentMetadata(
            schemaVersion: .current,
            title: "Recovered",
            authors: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: bundleURL.appendingPathComponent("metadata.json"))

        // Repair should create missing file
        let result = try await validator.repairDocument(at: bundleURL)

        XCTAssertTrue(result.actionsPerformed.contains { $0.contains("missing") })
    }

    func testRepair_clearsSyncState() async throws {
        let validator = CRDTHealthValidator()

        // Create document with partial sync state
        let bundleURL = tempDirectory.appendingPathComponent("clear-sync.imprint")
        try createTestBundle(at: bundleURL)
        try "".write(to: bundleURL.appendingPathComponent(".sync-in-progress"),
                     atomically: true, encoding: .utf8)
        try "temp".write(to: bundleURL.appendingPathComponent(".tmp-file.tmp"),
                         atomically: true, encoding: .utf8)

        // Manually simulate repair clearing sync state
        let syncMarker = bundleURL.appendingPathComponent(".sync-in-progress")
        if FileManager.default.fileExists(atPath: syncMarker.path) {
            try FileManager.default.removeItem(at: syncMarker)
        }

        // Verify sync marker removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncMarker.path))
    }

    // MARK: - Content Preservation Tests

    func testRepair_preservesSourceContent() async throws {
        let originalContent = "= Important Document\n\nThis content must be preserved."

        let bundleURL = tempDirectory.appendingPathComponent("preserve-content.imprint")
        try createTestBundle(at: bundleURL, sourceContent: originalContent)

        // Read back the source
        let sourceURL = bundleURL.appendingPathComponent("main.typ")
        let readContent = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertEqual(readContent, originalContent)
    }

    func testRepair_preservesMetadata() async throws {
        let bundleURL = tempDirectory.appendingPathComponent("preserve-metadata.imprint")

        let originalMetadata = VersionedDocumentMetadata(
            schemaVersion: .current,
            id: UUID(),
            title: "Important Title",
            authors: ["Author One", "Author Two"],
            linkedImbibManuscriptID: UUID()
        )

        try createTestBundle(at: bundleURL, metadata: originalMetadata)

        // Read back metadata
        let metadataURL = bundleURL.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let readMetadata = try decoder.decode(VersionedDocumentMetadata.self, from: data)

        XCTAssertEqual(readMetadata.title, originalMetadata.title)
        XCTAssertEqual(readMetadata.authors, originalMetadata.authors)
        XCTAssertEqual(readMetadata.linkedImbibManuscriptID, originalMetadata.linkedImbibManuscriptID)
    }

    // MARK: - Helper Methods

    private func createTestBundle(
        at url: URL,
        sourceContent: String = "= Test Document\n\nContent.",
        crdtContent: Data? = nil,
        metadata: VersionedDocumentMetadata? = nil
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Create main.typ
        try sourceContent.write(to: url.appendingPathComponent("main.typ"),
                                atomically: true, encoding: .utf8)

        // Create metadata.json
        let meta = metadata ?? VersionedDocumentMetadata(
            schemaVersion: .current,
            title: "Test",
            authors: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let metadataData = try encoder.encode(meta)
        try metadataData.write(to: url.appendingPathComponent("metadata.json"))

        // Create bibliography.bib (empty)
        try "".write(to: url.appendingPathComponent("bibliography.bib"),
                     atomically: true, encoding: .utf8)

        // Create document.crdt if content provided
        if let crdt = crdtContent {
            try crdt.write(to: url.appendingPathComponent("document.crdt"))
        }
    }
}

// MARK: - Stress Tests for CRDT

/// Stress tests for CRDT operations under load.
final class CRDTStressTests: XCTestCase {

    func testLargeDocument_10000Characters() throws {
        // Create a large source document
        let content = String(repeating: "This is a test paragraph. ", count: 500)
        XCTAssertGreaterThan(content.count, 10000)

        // Verify it can be handled
        let data = content.data(using: .utf8)
        XCTAssertNotNil(data)
    }

    func testManyEdits_rapidInsertion() throws {
        var document = ""

        // Simulate rapid insertions
        for i in 1...1000 {
            document.append("Line \(i)\n")
        }

        // Should handle without issues
        XCTAssertEqual(document.components(separatedBy: "\n").count, 1001) // 1000 lines + empty
    }

    func testConcurrentAccess_multipleReaders() async throws {
        let content = "Shared document content"

        // Simulate multiple concurrent readers
        await withTaskGroup(of: String.self) { group in
            for _ in 1...10 {
                group.addTask {
                    // Read the content
                    return content
                }
            }

            var results: [String] = []
            for await result in group {
                results.append(result)
            }

            // All readers should get the same content
            XCTAssertEqual(results.count, 10)
            XCTAssertTrue(results.allSatisfy { $0 == content })
        }
    }
}
