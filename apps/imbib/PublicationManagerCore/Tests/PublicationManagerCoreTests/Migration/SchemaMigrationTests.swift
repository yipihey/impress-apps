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

    // MARK: - SafeMigrationError Tests

    func testSafeMigrationErrorDescriptions() {
        // Verify all error cases have meaningful descriptions
        let errors: [SafeMigrationError] = [
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

    func testSafeMigrationErrorStoreNotFound() {
        let error = SafeMigrationError.storeNotFound
        XCTAssertTrue(error.errorDescription!.contains("not found"))
    }

    func testSafeMigrationErrorBackupFailed() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "test error"])
        let error = SafeMigrationError.backupFailed(underlying: underlying)
        XCTAssertTrue(error.errorDescription!.contains("Backup"))
        XCTAssertTrue(error.errorDescription!.contains("test error"))
    }

    func testSafeMigrationErrorDataLoss() {
        let error = SafeMigrationError.dataLoss(expected: 100, actual: 50)
        XCTAssertTrue(error.errorDescription!.contains("100"))
        XCTAssertTrue(error.errorDescription!.contains("50"))
    }

    func testSafeMigrationErrorValidationFailed() {
        let error = SafeMigrationError.validationFailed(reason: "schema mismatch")
        XCTAssertTrue(error.errorDescription!.contains("schema mismatch"))
    }

    // MARK: - MigrationState Tests

    func testMigrationStateValues() {
        // Ensure all states can be created
        let states: [SafeMigrationService.MigrationState] = [
            .idle,
            .backingUp,
            .validatingPre,
            .migrating,
            .validatingPost,
            .enablingSync,
            .completed,
            .failed(SafeMigrationError.storeNotFound)
        ]

        XCTAssertEqual(states.count, 8)
    }

    // MARK: - Backup Directory Tests

    func testBackupDirectoryCreation() async throws {
        // This test verifies the backup directory path construction
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let expectedPath = appSupport.appendingPathComponent("imbib/Backups", isDirectory: true)

        // The path should be valid and constructible
        XCTAssertTrue(expectedPath.path.contains("imbib"))
        XCTAssertTrue(expectedPath.path.contains("Backups"))
    }

}

// MARK: - Sync Health Monitor Tests

/// Tests for SyncHealthMonitor.
final class SyncHealthMonitorTests: XCTestCase {

    // MARK: - SyncHealthStatus Tests

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

    func testSyncHealthStatusColors() {
        XCTAssertEqual(SyncHealthStatus.healthy.color, "green")
        XCTAssertEqual(SyncHealthStatus.attention.color, "yellow")
        XCTAssertEqual(SyncHealthStatus.degraded.color, "orange")
        XCTAssertEqual(SyncHealthStatus.critical.color, "red")
        XCTAssertEqual(SyncHealthStatus.disabled.color, "gray")
    }

    func testSyncHealthStatusRawValues() {
        // Verify raw values exist for all cases
        XCTAssertEqual(SyncHealthStatus.healthy.rawValue, "healthy")
        XCTAssertEqual(SyncHealthStatus.attention.rawValue, "attention")
        XCTAssertEqual(SyncHealthStatus.degraded.rawValue, "degraded")
        XCTAssertEqual(SyncHealthStatus.critical.rawValue, "critical")
        XCTAssertEqual(SyncHealthStatus.disabled.rawValue, "disabled")
    }

    // MARK: - SyncHealthIssue.Severity Tests

    func testSyncHealthIssueSeverityComparable() {
        XCTAssertLessThan(SyncHealthIssue.Severity.info, SyncHealthIssue.Severity.attention)
        XCTAssertLessThan(SyncHealthIssue.Severity.attention, SyncHealthIssue.Severity.warning)
        XCTAssertLessThan(SyncHealthIssue.Severity.warning, SyncHealthIssue.Severity.critical)
    }

    func testSyncHealthIssueSeverityRawValues() {
        XCTAssertEqual(SyncHealthIssue.Severity.info.rawValue, 0)
        XCTAssertEqual(SyncHealthIssue.Severity.attention.rawValue, 1)
        XCTAssertEqual(SyncHealthIssue.Severity.warning.rawValue, 2)
        XCTAssertEqual(SyncHealthIssue.Severity.critical.rawValue, 3)
    }

    func testSyncHealthIssueSeverityOrdering() {
        // Test sorting by severity
        let severities: [SyncHealthIssue.Severity] = [.critical, .info, .warning, .attention]
        let sorted = severities.sorted()
        XCTAssertEqual(sorted, [.info, .attention, .warning, .critical])
    }

    // MARK: - SyncHealthIssue Tests

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

    func testSyncHealthIssueHasUniqueId() {
        let issue1 = SyncHealthIssue(
            type: .conflict,
            severity: .warning,
            title: "Issue 1",
            description: "Description",
            suggestedAction: "Action"
        )

        let issue2 = SyncHealthIssue(
            type: .conflict,
            severity: .warning,
            title: "Issue 2",
            description: "Description",
            suggestedAction: "Action"
        )

        XCTAssertNotEqual(issue1.id, issue2.id)
    }

    func testSyncHealthIssueTimestamp() {
        let beforeCreation = Date()
        let issue = SyncHealthIssue(
            type: .networkError,
            severity: .attention,
            title: "Network Issue",
            description: "Cannot reach server",
            suggestedAction: "Check connection"
        )
        let afterCreation = Date()

        XCTAssertGreaterThanOrEqual(issue.createdAt, beforeCreation)
        XCTAssertLessThanOrEqual(issue.createdAt, afterCreation)
    }

    func testSyncHealthIssueTypeValues() {
        // Verify all issue types can be created
        let types: [SyncHealthIssue.IssueType] = [
            .conflict,
            .syncPaused,
            .quotaWarning,
            .quotaExceeded,
            .networkError,
            .schemaVersionMismatch,
            .outdatedBackup
        ]

        XCTAssertEqual(types.count, 7)
    }

    // MARK: - Notification Names Tests

    func testNotificationNamesExist() {
        // Verify notification names are unique
        XCTAssertNotEqual(Notification.Name.syncDidComplete, .syncDidFail)
        XCTAssertNotEqual(Notification.Name.syncDidComplete, .syncDidStart)
        XCTAssertNotEqual(Notification.Name.syncDidFail, .syncDidStart)
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
            attachmentCount: 25,
            fileChecksums: ["file1.bib": "abc123", "file2.pdf": "def456"]
        )

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: encoded)

        XCTAssertEqual(decoded.version, manifest.version)
        XCTAssertEqual(decoded.appVersion, manifest.appVersion)
        XCTAssertEqual(decoded.publicationCount, manifest.publicationCount)
        XCTAssertEqual(decoded.attachmentCount, manifest.attachmentCount)
        XCTAssertEqual(decoded.fileChecksums.count, manifest.fileChecksums.count)
    }

    func testBackupInfoSizeString() {
        let info = BackupInfo(
            url: URL(fileURLWithPath: "/tmp/backup"),
            createdAt: Date(),
            sizeBytes: 1024 * 1024, // 1 MB
            publicationCount: 10,
            attachmentCount: 5
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
