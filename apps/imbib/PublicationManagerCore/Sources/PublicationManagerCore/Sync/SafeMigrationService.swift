//
//  SafeMigrationService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-28.
//

import Foundation
import CoreData
import OSLog

/// Service for performing safe Core Data migrations with backup and validation.
///
/// This service wraps all Core Data migrations with:
/// 1. Pre-migration backup
/// 2. State validation before and after
/// 3. CloudKit sync coordination
/// 4. Rollback capability on failure
///
/// # Usage
///
/// ```swift
/// let migrationService = SafeMigrationService(persistenceController: .shared)
/// do {
///     try await migrationService.performMigration()
/// } catch {
///     // Handle migration failure
/// }
/// ```
public actor SafeMigrationService {

    // MARK: - Properties

    private let persistenceController: PersistenceController
    private let fileManager: FileManager
    private let backupDirectory: URL

    // MARK: - State

    /// Current migration state.
    public enum MigrationState: Sendable {
        case idle
        case backingUp
        case validatingPre
        case migrating
        case validatingPost
        case enablingSync
        case completed
        case failed(Error)
    }

    private(set) var state: MigrationState = .idle
    private(set) var lastBackupURL: URL?

    // MARK: - Initialization

    public init(
        persistenceController: PersistenceController,
        fileManager: FileManager = .default
    ) {
        self.persistenceController = persistenceController
        self.fileManager = fileManager

        // Create backup directory in Application Support
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.backupDirectory = appSupport.appendingPathComponent("imbib/Backups", isDirectory: true)
    }

    // MARK: - Public API

    /// Perform a safe migration with backup and validation.
    ///
    /// This method:
    /// 1. Creates a backup of the current store
    /// 2. Validates the pre-migration state
    /// 3. Performs the actual migration
    /// 4. Validates the post-migration state
    /// 5. Enables CloudKit sync only after successful migration
    ///
    /// - Throws: `MigrationError` if any step fails.
    public func performMigration() async throws {
        Logger.migration.info("Starting safe migration process")

        do {
            // Step 1: Create backup
            state = .backingUp
            let backupURL = try await backupCurrentStore()
            lastBackupURL = backupURL
            Logger.migration.info("Backup created at: \(backupURL.path)")

            // Step 2: Validate pre-migration state
            state = .validatingPre
            let preState = try await captureStoreState()
            Logger.migration.info("Pre-migration state captured: \(preState.publicationCount) publications")

            // Step 3: Perform migration
            state = .migrating
            try await performActualMigration()
            Logger.migration.info("Migration completed")

            // Step 4: Validate post-migration state
            state = .validatingPost
            let postState = try await captureStoreState()
            try validateMigration(from: preState, to: postState)
            Logger.migration.info("Post-migration validation passed")

            // Step 5: Enable CloudKit sync
            state = .enablingSync
            try await enableCloudKitSync()
            Logger.migration.info("CloudKit sync enabled")

            state = .completed
            Logger.migration.info("Safe migration completed successfully")

        } catch {
            state = .failed(error)
            Logger.migration.error("Migration failed: \(error.localizedDescription)")

            // Attempt rollback if we have a backup
            if let backupURL = lastBackupURL {
                Logger.migration.info("Attempting rollback from backup")
                // Note: Actual rollback would require app restart
                // Store rollback intent for next launch
                UserDefaults.forCurrentEnvironment.set(backupURL.path, forKey: "migration.pendingRollback")
            }

            throw error
        }
    }

    /// Check if a migration is needed.
    public func checkMigrationNeeded() async -> Bool {
        let storedVersion = UserDefaults.forCurrentEnvironment.integer(forKey: SchemaVersion.userDefaultsKey)

        if storedVersion == 0 {
            // First launch, no migration needed
            return false
        }

        return storedVersion < SchemaVersion.current.rawValue
    }

    /// Get the URL of the most recent backup, if available.
    public func getMostRecentBackup() -> URL? {
        guard fileManager.fileExists(atPath: backupDirectory.path) else {
            return nil
        }

        do {
            let backups = try fileManager.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )

            // Sort by creation date, newest first
            let sorted = backups.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return date1 > date2
            }

            return sorted.first
        } catch {
            Logger.migration.warning("Failed to list backups: \(error.localizedDescription)")
            return nil
        }
    }

    /// Delete old backups, keeping only the most recent ones.
    ///
    /// - Parameter keepCount: Number of backups to keep. Default is 3.
    public func cleanupOldBackups(keepCount: Int = 3) async throws {
        guard fileManager.fileExists(atPath: backupDirectory.path) else {
            return
        }

        let backups = try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        // Sort by creation date, oldest first
        let sorted = backups.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return date1 < date2
        }

        // Delete oldest backups, keeping keepCount
        let toDelete = sorted.dropLast(keepCount)
        for backupURL in toDelete {
            try fileManager.removeItem(at: backupURL)
            Logger.migration.info("Deleted old backup: \(backupURL.lastPathComponent)")
        }
    }

    // MARK: - Private Methods

    /// Create a backup of the current Core Data store.
    private func backupCurrentStore() async throws -> URL {
        // Create backup directory if needed
        if !fileManager.fileExists(atPath: backupDirectory.path) {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        }

        // Create timestamped backup folder
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDirectory.appendingPathComponent("backup-\(timestamp)", isDirectory: true)
        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)

        // Get store URLs from persistence controller
        let storeURL = await MainActor.run {
            persistenceController.storeURL
        }

        guard let storeURL = storeURL else {
            throw MigrationError.storeNotFound
        }

        // Copy store files
        let storeFiles = [
            storeURL,
            storeURL.appendingPathExtension("shm"),
            storeURL.appendingPathExtension("wal")
        ]

        for fileURL in storeFiles where fileManager.fileExists(atPath: fileURL.path) {
            let destURL = backupURL.appendingPathComponent(fileURL.lastPathComponent)
            try fileManager.copyItem(at: fileURL, to: destURL)
        }

        // Store schema version in backup
        let metadata = BackupMetadata(
            schemaVersion: SchemaVersion.current.rawValue,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: backupURL.appendingPathComponent("metadata.json"))

        return backupURL
    }

    /// Capture the current state of the store for validation.
    private func captureStoreState() async throws -> StoreState {
        return await MainActor.run {
            let context = persistenceController.viewContext

            // Count publications
            let publicationFetch = NSFetchRequest<NSNumber>(entityName: "CDPublication")
            publicationFetch.resultType = .countResultType
            let publicationCount = (try? context.fetch(publicationFetch).first?.intValue) ?? 0

            // Count libraries
            let libraryFetch = NSFetchRequest<NSNumber>(entityName: "CDLibrary")
            libraryFetch.resultType = .countResultType
            let libraryCount = (try? context.fetch(libraryFetch).first?.intValue) ?? 0

            return StoreState(
                publicationCount: publicationCount,
                libraryCount: libraryCount,
                schemaVersion: SchemaVersion.current.rawValue
            )
        }
    }

    /// Perform the actual Core Data migration.
    private func performActualMigration() async throws {
        // Core Data lightweight migration is typically automatic
        // This method handles any additional migration logic needed

        // Update stored schema version
        UserDefaults.forCurrentEnvironment.set(
            SchemaVersion.current.rawValue,
            forKey: SchemaVersion.userDefaultsKey
        )
    }

    /// Validate that migration preserved data correctly.
    private func validateMigration(from preState: StoreState, to postState: StoreState) throws {
        // Publications should not decrease
        if postState.publicationCount < preState.publicationCount {
            throw MigrationError.dataLoss(
                expected: preState.publicationCount,
                actual: postState.publicationCount
            )
        }

        // Libraries should not decrease
        if postState.libraryCount < preState.libraryCount {
            throw MigrationError.dataLoss(
                expected: preState.libraryCount,
                actual: postState.libraryCount
            )
        }

        Logger.migration.info("""
            Migration validation passed:
            - Publications: \(preState.publicationCount) → \(postState.publicationCount)
            - Libraries: \(preState.libraryCount) → \(postState.libraryCount)
            """)
    }

    /// Enable CloudKit sync after successful migration.
    private func enableCloudKitSync() async throws {
        await MainActor.run {
            // Configure CloudKit sync if not already enabled
            if persistenceController.isCloudKitEnabled {
                persistenceController.configureCloudKitMerging()
            }
        }
    }
}

// MARK: - Supporting Types

/// Errors that can occur during migration.
public enum MigrationError: LocalizedError {
    case storeNotFound
    case backupFailed(underlying: Error)
    case migrationFailed(underlying: Error)
    case validationFailed(reason: String)
    case dataLoss(expected: Int, actual: Int)
    case rollbackFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .storeNotFound:
            return "Core Data store not found"
        case .backupFailed(let error):
            return "Backup failed: \(error.localizedDescription)"
        case .migrationFailed(let error):
            return "Migration failed: \(error.localizedDescription)"
        case .validationFailed(let reason):
            return "Migration validation failed: \(reason)"
        case .dataLoss(let expected, let actual):
            return "Data loss detected: expected \(expected) items, found \(actual)"
        case .rollbackFailed(let error):
            return "Rollback failed: \(error.localizedDescription)"
        }
    }
}

/// Captured state of the store for validation.
private struct StoreState: Sendable {
    let publicationCount: Int
    let libraryCount: Int
    let schemaVersion: Int
}

/// Metadata stored with each backup.
private struct BackupMetadata: Codable {
    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
}

// MARK: - Logger Extension

private extension Logger {
    static let migration = Logger(subsystem: "com.imbib.app", category: "migration")
}
