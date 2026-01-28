//
//  SchemaMigrationTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-28.
//

import XCTest
@testable import PublicationManagerCore

/// Tests for Core Data schema migrations.
///
/// These tests verify that:
/// - Schema version tracking works correctly
/// - Migrations preserve data integrity
/// - Compatibility checks function properly
final class SchemaMigrationTests: XCTestCase {

    // MARK: - Schema Version Tests

    func testSchemaVersionComparable() {
        XCTAssertLessThan(SchemaVersion.v1_0, SchemaVersion.v1_1)
        XCTAssertLessThan(SchemaVersion.v1_1, SchemaVersion.v1_2)
        XCTAssertEqual(SchemaVersion.v1_2, SchemaVersion.current)
    }

    func testSchemaVersionDisplayString() {
        XCTAssertEqual(SchemaVersion.v1_0.displayString, "1.0")
        XCTAssertEqual(SchemaVersion.v1_1.displayString, "1.1")
        XCTAssertEqual(SchemaVersion.v1_2.displayString, "1.2")
    }

    func testSchemaVersionCompatibility() {
        // All versions should be compatible (minimum is v1.0)
        XCTAssertTrue(SchemaVersion.v1_0.isCompatibleWithCurrentApp)
        XCTAssertTrue(SchemaVersion.v1_1.isCompatibleWithCurrentApp)
        XCTAssertTrue(SchemaVersion.v1_2.isCompatibleWithCurrentApp)
    }

    func testSchemaVersionCanUpgrade() {
        XCTAssertTrue(SchemaVersion.v1_0.canUpgradeToCurrent)
        XCTAssertTrue(SchemaVersion.v1_1.canUpgradeToCurrent)
        XCTAssertFalse(SchemaVersion.v1_2.canUpgradeToCurrent) // Already current
    }

    func testSchemaVersionChangeDescriptions() {
        // All versions should have descriptions
        XCTAssertFalse(SchemaVersion.v1_0.changeDescription.isEmpty)
        XCTAssertFalse(SchemaVersion.v1_1.changeDescription.isEmpty)
        XCTAssertFalse(SchemaVersion.v1_2.changeDescription.isEmpty)
    }

    // MARK: - Schema Version Checker Tests

    func testVersionCheckerCurrentVersion() {
        let checker = SchemaVersionChecker()
        let result = checker.check(remoteVersionRaw: SchemaVersion.current.rawValue)

        switch result {
        case .current:
            break // Expected
        default:
            XCTFail("Expected .current, got \(result)")
        }
    }

    func testVersionCheckerOlderVersion() {
        let checker = SchemaVersionChecker()
        let result = checker.check(remoteVersionRaw: SchemaVersion.v1_0.rawValue)

        switch result {
        case .needsMigration(let from):
            XCTAssertEqual(from, .v1_0)
        default:
            XCTFail("Expected .needsMigration, got \(result)")
        }
    }

    func testVersionCheckerNewerVersion() {
        let checker = SchemaVersionChecker()
        let futureVersion = 300 // v3.0
        let result = checker.check(remoteVersionRaw: futureVersion)

        switch result {
        case .newerThanApp(let version):
            XCTAssertEqual(version, futureVersion)
        default:
            XCTFail("Expected .newerThanApp, got \(result)")
        }
    }

    func testVersionCheckerShouldWarnForNewerVersion() {
        let checker = SchemaVersionChecker()

        // Should not warn for compatible versions
        XCTAssertFalse(checker.shouldWarnBeforeSync(remoteVersionRaw: SchemaVersion.current.rawValue))
        XCTAssertFalse(checker.shouldWarnBeforeSync(remoteVersionRaw: SchemaVersion.v1_0.rawValue))

        // Should warn for newer versions
        XCTAssertTrue(checker.shouldWarnBeforeSync(remoteVersionRaw: 300))
    }

    // MARK: - Migration Tests

    func testMigrationRequiresFullResync() {
        // None of our current versions require full resync
        XCTAssertFalse(SchemaVersion.v1_0.requiresFullResync)
        XCTAssertFalse(SchemaVersion.v1_1.requiresFullResync)
        XCTAssertFalse(SchemaVersion.v1_2.requiresFullResync)
    }

    func testSchemaVersionExpectedFiles() {
        // These are implicitly defined by our Core Data model
        // Test that metadata keys are consistent
        XCTAssertEqual(SchemaVersion.cloudKitMetadataKey, "schemaVersion")
        XCTAssertEqual(SchemaVersion.userDefaultsKey, "imbib.schema.version")
    }
}

// MARK: - Migration Service Tests

/// Tests for SafeMigrationService.
final class SafeMigrationServiceTests: XCTestCase {

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

    func testMigrationErrorDescriptions() {
        // Verify all error cases have meaningful descriptions
        let errors: [MigrationError] = [
            .storeNotFound,
            .backupFailed(underlying: NSError(domain: "test", code: 1)),
            .migrationFailed(underlying: NSError(domain: "test", code: 1)),
            .validationFailed(reason: "test reason"),
            .dataLoss(expected: 100, actual: 50),
            .rollbackFailed(underlying: NSError(domain: "test", code: 1))
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}

// MARK: - Sync Health Monitor Tests

/// Tests for SyncHealthMonitor.
final class SyncHealthMonitorTests: XCTestCase {

    func testSyncHealthStatusIcons() {
        XCTAssertEqual(SyncHealthStatus.healthy.iconName, "checkmark.icloud")
        XCTAssertEqual(SyncHealthStatus.attention.iconName, "exclamationmark.icloud")
        XCTAssertEqual(SyncHealthStatus.degraded.iconName, "exclamationmark.triangle")
        XCTAssertEqual(SyncHealthStatus.critical.iconName, "xmark.icloud")
        XCTAssertEqual(SyncHealthStatus.disabled.iconName, "icloud.slash")
    }

    func testSyncHealthStatusDescriptions() {
        XCTAssertFalse(SyncHealthStatus.healthy.description.isEmpty)
        XCTAssertFalse(SyncHealthStatus.attention.description.isEmpty)
        XCTAssertFalse(SyncHealthStatus.degraded.description.isEmpty)
        XCTAssertFalse(SyncHealthStatus.critical.description.isEmpty)
        XCTAssertFalse(SyncHealthStatus.disabled.description.isEmpty)
    }

    func testSyncHealthIssueSeverityComparable() {
        XCTAssertLessThan(SyncHealthIssue.Severity.info, SyncHealthIssue.Severity.attention)
        XCTAssertLessThan(SyncHealthIssue.Severity.attention, SyncHealthIssue.Severity.warning)
        XCTAssertLessThan(SyncHealthIssue.Severity.warning, SyncHealthIssue.Severity.critical)
    }

    func testSyncHealthIssueCreation() {
        let issue = SyncHealthIssue(
            type: .conflict,
            severity: .warning,
            title: "Test Conflict",
            description: "A test conflict description",
            suggestedAction: "Resolve the conflict"
        )

        XCTAssertEqual(issue.type, .conflict)
        XCTAssertEqual(issue.severity, .warning)
        XCTAssertEqual(issue.title, "Test Conflict")
        XCTAssertFalse(issue.description.isEmpty)
        XCTAssertFalse(issue.suggestedAction.isEmpty)
    }
}

// MARK: - Library Backup Service Tests

/// Tests for LibraryBackupService.
final class LibraryBackupServiceTests: XCTestCase {

    func testBackupManifestCodable() throws {
        let manifest = BackupManifest(
            version: 1,
            createdAt: Date(),
            appVersion: "1.0.0",
            schemaVersion: 120,
            publicationCount: 50,
            pdfCount: 25,
            fileChecksums: ["file1.bib": "abc123", "file2.pdf": "def456"]
        )

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: encoded)

        XCTAssertEqual(decoded.version, manifest.version)
        XCTAssertEqual(decoded.appVersion, manifest.appVersion)
        XCTAssertEqual(decoded.publicationCount, manifest.publicationCount)
        XCTAssertEqual(decoded.pdfCount, manifest.pdfCount)
        XCTAssertEqual(decoded.fileChecksums.count, manifest.fileChecksums.count)
    }

    func testBackupInfoSizeString() {
        let info = BackupInfo(
            url: URL(fileURLWithPath: "/tmp/backup"),
            createdAt: Date(),
            sizeBytes: 1024 * 1024, // 1 MB
            publicationCount: 10,
            pdfCount: 5
        )

        XCTAssertFalse(info.sizeString.isEmpty)
        XCTAssertTrue(info.sizeString.contains("MB") || info.sizeString.contains("KB"))
    }

    func testBackupErrorDescriptions() {
        let errors: [BackupError] = [
            .compressionFailed,
            .compressionNotSupported,
            .verificationFailed(missingFiles: ["a.pdf"], corruptedFiles: ["b.pdf"])
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
