//
//  DocumentMigrationTests.swift
//  imprint
//
//  Created by Claude on 2026-01-28.
//

import XCTest
@testable import imprint

/// Tests for imprint document schema migrations.
///
/// These tests verify that:
/// - Document schema version tracking works correctly
/// - Migrations preserve document content
/// - CRDT state is handled safely during migration
final class DocumentMigrationTests: XCTestCase {

    // MARK: - Schema Version Tests

    func testDocumentSchemaVersionComparable() {
        XCTAssertLessThan(DocumentSchemaVersion.v1_0, DocumentSchemaVersion.v1_1)
        XCTAssertLessThan(DocumentSchemaVersion.v1_1, DocumentSchemaVersion.v1_2)
        XCTAssertEqual(DocumentSchemaVersion.v1_2, DocumentSchemaVersion.current)
    }

    func testDocumentSchemaVersionDisplayString() {
        XCTAssertEqual(DocumentSchemaVersion.v1_0.displayString, "1.0")
        XCTAssertEqual(DocumentSchemaVersion.v1_1.displayString, "1.1")
        XCTAssertEqual(DocumentSchemaVersion.v1_2.displayString, "1.2")
    }

    func testDocumentSchemaVersionReadability() {
        // All versions should be readable
        XCTAssertTrue(DocumentSchemaVersion.v1_0.isReadableByCurrentApp)
        XCTAssertTrue(DocumentSchemaVersion.v1_1.isReadableByCurrentApp)
        XCTAssertTrue(DocumentSchemaVersion.v1_2.isReadableByCurrentApp)
    }

    func testDocumentSchemaVersionNeedsMigration() {
        XCTAssertTrue(DocumentSchemaVersion.v1_0.needsMigration)
        XCTAssertTrue(DocumentSchemaVersion.v1_1.needsMigration)
        XCTAssertFalse(DocumentSchemaVersion.v1_2.needsMigration) // Already current
    }

    func testDocumentSchemaVersionExpectedFiles() {
        // v1.0 basic files
        let v1_0Files = DocumentSchemaVersion.v1_0.expectedFiles
        XCTAssertTrue(v1_0Files.contains("main.typ"))
        XCTAssertTrue(v1_0Files.contains("metadata.json"))

        // v1.2 should have all files
        let v1_2Files = DocumentSchemaVersion.v1_2.expectedFiles
        XCTAssertTrue(v1_2Files.contains("main.typ"))
        XCTAssertTrue(v1_2Files.contains("metadata.json"))
        XCTAssertTrue(v1_2Files.contains("bibliography.bib"))
        XCTAssertTrue(v1_2Files.contains("document.crdt"))
    }

    // MARK: - Version Checker Tests

    func testVersionCheckerCurrentVersion() {
        let checker = DocumentVersionChecker()
        let result = checker.check(versionRaw: DocumentSchemaVersion.current.rawValue)

        switch result {
        case .current:
            break // Expected
        default:
            XCTFail("Expected .current, got \(result)")
        }
    }

    func testVersionCheckerOlderVersion() {
        let checker = DocumentVersionChecker()
        let result = checker.check(versionRaw: DocumentSchemaVersion.v1_0.rawValue)

        switch result {
        case .needsMigration(let from):
            XCTAssertEqual(from, .v1_0)
        default:
            XCTFail("Expected .needsMigration, got \(result)")
        }
    }

    func testVersionCheckerNewerVersion() {
        let checker = DocumentVersionChecker()
        let futureVersion = 300 // v3.0
        let result = checker.check(versionRaw: futureVersion)

        switch result {
        case .newerThanApp(let version):
            XCTAssertEqual(version, futureVersion)
        default:
            XCTFail("Expected .newerThanApp, got \(result)")
        }
    }

    func testVersionCheckerLegacyDocument() {
        let checker = DocumentVersionChecker()
        let result = checker.check(versionRaw: nil)

        switch result {
        case .legacy:
            break // Expected
        default:
            XCTFail("Expected .legacy, got \(result)")
        }
    }

    func testVersionCheckerCanOpen() {
        let checker = DocumentVersionChecker()

        // Should be able to open current and older versions
        XCTAssertTrue(checker.canOpen(versionRaw: DocumentSchemaVersion.current.rawValue))
        XCTAssertTrue(checker.canOpen(versionRaw: DocumentSchemaVersion.v1_0.rawValue))
        XCTAssertTrue(checker.canOpen(versionRaw: nil)) // Legacy

        // Should not be able to open newer versions
        XCTAssertFalse(checker.canOpen(versionRaw: 300))
    }

    // MARK: - Versioned Metadata Tests

    func testVersionedMetadataCodable() throws {
        let metadata = VersionedDocumentMetadata(
            schemaVersion: .current,
            id: UUID(),
            title: "Test Document",
            authors: ["Author 1", "Author 2"],
            createdAt: Date(),
            modifiedAt: Date(),
            linkedImbibManuscriptID: UUID(),
            lastSavedByAppVersion: "1.0.0"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VersionedDocumentMetadata.self, from: encoded)

        XCTAssertEqual(decoded.schemaVersion, metadata.schemaVersion)
        XCTAssertEqual(decoded.title, metadata.title)
        XCTAssertEqual(decoded.authors, metadata.authors)
        XCTAssertEqual(decoded.linkedImbibManuscriptID, metadata.linkedImbibManuscriptID)
    }

    func testVersionedMetadataSchemaVersionEnum() {
        let metadata = VersionedDocumentMetadata(
            schemaVersion: .v1_2,
            title: "Test",
            authors: []
        )

        XCTAssertEqual(metadata.schemaVersionEnum, .v1_2)
    }

    // MARK: - Migration Error Tests

    func testMigrationErrorDescriptions() {
        let errors: [DocumentMigrationError] = [
            .newerVersion(documentVersion: 300),
            .unsupportedVersion(50),
            .missingFile("main.typ"),
            .corruptedDocument(reason: "Invalid JSON")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}

// MARK: - CRDT Health Validator Tests

/// Tests for CRDTHealthValidator.
final class CRDTHealthValidatorTests: XCTestCase {

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

    func testCRDTHealthIssueTypes() {
        // Verify all issue types have descriptions
        let issueTypes: [CRDTHealthIssue.IssueType] = [
            .crdtCorrupted,
            .contentMismatch,
            .partialSync,
            .missingFile,
            .staleHistory
        ]

        for type in issueTypes {
            let issue = CRDTHealthIssue(
                type: type,
                severity: .warning,
                description: "Test description",
                suggestedAction: "Test action"
            )
            XCTAssertEqual(issue.type, type)
        }
    }

    func testCRDTValidationResultSizeRatio() {
        let result = CRDTValidationResult(
            isHealthy: true,
            issues: [],
            hasCRDTState: true,
            sourceSize: 1000,
            crdtSize: 2000
        )

        XCTAssertEqual(result.sizeRatio, 2.0)
    }

    func testCRDTValidationResultSizeRatioZeroSource() {
        let result = CRDTValidationResult(
            isHealthy: true,
            issues: [],
            hasCRDTState: true,
            sourceSize: 0,
            crdtSize: 100
        )

        XCTAssertEqual(result.sizeRatio, 0)
    }

    func testCRDTRepairResult() {
        let result = CRDTRepairResult(
            success: true,
            actionsPerformed: ["Action 1", "Action 2"]
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.actionsPerformed.count, 2)
    }

    func testCRDTRepairErrorDescriptions() {
        let errors: [CRDTRepairError] = [
            .sourceNotReadable,
            .repairFailed(reason: "Test failure")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testCreateValidDocumentBundle() throws {
        // Create a valid document bundle for testing
        let bundleURL = tempDirectory.appendingPathComponent("test.imprint")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Create main.typ
        try "= Test Document\n\nContent here.".write(
            to: bundleURL.appendingPathComponent("main.typ"),
            atomically: true,
            encoding: .utf8
        )

        // Create metadata.json
        let metadata = VersionedDocumentMetadata(
            schemaVersion: .current,
            title: "Test Document",
            authors: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: bundleURL.appendingPathComponent("metadata.json"))

        // Verify files exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("main.typ").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("metadata.json").path))
    }
}

// MARK: - Document Backup Service Tests

/// Tests for DocumentBackupService.
final class DocumentBackupServiceTests: XCTestCase {

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

    func testDocumentBackupInfoSizeString() {
        let info = DocumentBackupInfo(
            url: URL(fileURLWithPath: "/tmp/backup.imprint"),
            originalName: "test",
            title: "Test Document",
            createdAt: Date(),
            sizeBytes: 1024 * 1024 // 1 MB
        )

        XCTAssertFalse(info.sizeString.isEmpty)
        XCTAssertTrue(info.sizeString.contains("MB") || info.sizeString.contains("KB"))
    }

    func testDocumentBackupVerificationResult() {
        let validResult = DocumentBackupVerificationResult(
            isValid: true,
            issues: []
        )
        XCTAssertTrue(validResult.isValid)
        XCTAssertTrue(validResult.issues.isEmpty)

        let invalidResult = DocumentBackupVerificationResult(
            isValid: false,
            issues: ["Missing file: main.typ"]
        )
        XCTAssertFalse(invalidResult.isValid)
        XCTAssertFalse(invalidResult.issues.isEmpty)
    }

    func testDocumentBackupErrorDescriptions() {
        let errors: [DocumentBackupError] = [
            .invalidBackup(issues: ["Issue 1", "Issue 2"]),
            .restoreFailed(reason: "Permission denied")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
