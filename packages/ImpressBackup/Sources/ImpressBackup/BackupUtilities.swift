//
//  BackupUtilities.swift
//  ImpressBackup
//
//  Shared backup utilities for impress apps.
//

import Foundation
import OSLog

// MARK: - Backup Progress

/// Generic progress information for backup operations.
public struct BackupProgress<Phase: BackupPhase>: Sendable {
    public let phase: Phase
    public let current: Int
    public let total: Int
    public let currentItem: String?

    public init(phase: Phase, current: Int, total: Int, currentItem: String? = nil) {
        self.phase = phase
        self.current = current
        self.total = total
        self.currentItem = currentItem
    }

    public var fractionComplete: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

/// Protocol for backup phases (app-specific).
public protocol BackupPhase: Sendable {
    var displayName: String { get }
}

/// Progress callback type.
public typealias BackupProgressHandler<Phase: BackupPhase> = @Sendable (BackupProgress<Phase>) -> Void

// MARK: - Backup Directory Manager

/// Manages backup directory creation and cleanup.
public actor BackupDirectoryManager {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let backupPrefix: String

    /// Create a backup directory manager.
    ///
    /// - Parameters:
    ///   - appName: App name for the backup directory (e.g., "imbib", "imprint")
    ///   - backupPrefix: Prefix for backup folder names (e.g., "imbib-backup-", "Document-backup-")
    ///   - fileManager: File manager to use
    public init(
        appName: String,
        backupPrefix: String,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.backupPrefix = backupPrefix

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseDirectory = appSupport.appendingPathComponent("\(appName)/Backups", isDirectory: true)
    }

    /// Create a new backup directory with timestamp.
    ///
    /// - Parameter suffix: Optional suffix for the backup name.
    /// - Returns: URL of the created backup directory.
    public func createBackupDirectory(suffix: String? = nil) throws -> URL {
        // Ensure base directory exists
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }

        let timestamp = Self.formatTimestamp(Date())
        var backupName = "\(backupPrefix)\(timestamp)"
        if let suffix = suffix {
            backupName += "-\(suffix)"
        }

        let backupURL = baseDirectory.appendingPathComponent(backupName, isDirectory: true)
        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)

        return backupURL
    }

    /// Format a date as a filesystem-safe timestamp.
    public static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// Get the base backups directory.
    public var backupsDirectory: URL {
        baseDirectory
    }
}

// MARK: - Backup Info

/// Generic backup information.
public struct BackupInfo: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let createdAt: Date
    public let sizeBytes: Int

    public init(url: URL, name: String, createdAt: Date, sizeBytes: Int) {
        self.url = url
        self.name = name
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
    }

    /// Human-readable size string.
    public var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

// MARK: - Backup Listing

/// Utility for listing backups.
public enum BackupListing {

    /// List backups in a directory.
    ///
    /// - Parameters:
    ///   - directory: Directory containing backups.
    ///   - prefix: Optional prefix to filter by.
    ///   - fileManager: File manager to use.
    /// - Returns: List of backup info, sorted by date (newest first).
    public static func listBackups(
        in directory: URL,
        prefix: String? = nil,
        fileManager: FileManager = .default
    ) -> [BackupInfo] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            return contents.compactMap { url -> BackupInfo? in
                // Filter by prefix if specified
                if let prefix = prefix {
                    guard url.lastPathComponent.hasPrefix(prefix) else { return nil }
                }

                let resources = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isDirectoryKey])

                // Calculate size for directories
                let size: Int
                if resources?.isDirectory == true {
                    size = directorySize(at: url, fileManager: fileManager)
                } else {
                    size = resources?.fileSize ?? 0
                }

                return BackupInfo(
                    url: url,
                    name: url.lastPathComponent,
                    createdAt: resources?.creationDate ?? Date.distantPast,
                    sizeBytes: size
                )
            }.sorted { $0.createdAt > $1.createdAt }
        } catch {
            return []
        }
    }

    /// Calculate the total size of a directory.
    public static func directorySize(at url: URL, fileManager: FileManager = .default) -> Int {
        var size = 0
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if let resources = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resources.fileSize {
                size += fileSize
            }
        }

        return size
    }
}

// MARK: - Backup Cleanup

/// Utility for cleaning up old backups.
public enum BackupCleanup {

    /// Delete old backups, keeping the most recent ones.
    ///
    /// - Parameters:
    ///   - backups: List of backups (should be sorted by date, newest first).
    ///   - keepCount: Number of backups to keep.
    ///   - fileManager: File manager to use.
    /// - Returns: Number of backups deleted.
    @discardableResult
    public static func cleanupOldBackups(
        _ backups: [BackupInfo],
        keepCount: Int = 5,
        fileManager: FileManager = .default
    ) throws -> Int {
        let toDelete = backups.dropFirst(keepCount)
        var deletedCount = 0

        for backup in toDelete {
            try fileManager.removeItem(at: backup.url)
            deletedCount += 1
        }

        return deletedCount
    }

    /// Group backups by a key and cleanup each group.
    ///
    /// - Parameters:
    ///   - backups: List of backups.
    ///   - keyExtractor: Function to extract grouping key from backup.
    ///   - keepCount: Number of backups to keep per group.
    ///   - fileManager: File manager to use.
    /// - Returns: Total number of backups deleted.
    @discardableResult
    public static func cleanupGroupedBackups<Key: Hashable>(
        _ backups: [BackupInfo],
        groupedBy keyExtractor: (BackupInfo) -> Key,
        keepCount: Int = 5,
        fileManager: FileManager = .default
    ) throws -> Int {
        var grouped: [Key: [BackupInfo]] = [:]
        for backup in backups {
            let key = keyExtractor(backup)
            grouped[key, default: []].append(backup)
        }

        var totalDeleted = 0
        for (_, groupBackups) in grouped {
            // Sort by date (newest first) within each group
            let sorted = groupBackups.sorted { $0.createdAt > $1.createdAt }
            totalDeleted += try cleanupOldBackups(sorted, keepCount: keepCount, fileManager: fileManager)
        }

        return totalDeleted
    }
}

// MARK: - Checksum Utilities

/// Utilities for computing file checksums.
public enum ChecksumUtilities {

    /// Compute a simple XOR-based checksum for a file.
    ///
    /// Note: This is not cryptographically secure - use only for integrity checking.
    public static func computeChecksum(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return computeChecksum(for: data)
    }

    /// Compute a simple XOR-based checksum for data.
    public static func computeChecksum(for data: Data) -> String {
        data.withUnsafeBytes { buffer -> String in
            var hash: [UInt8] = Array(repeating: 0, count: 32)
            for (index, byte) in buffer.enumerated() {
                hash[index % 32] ^= byte
            }
            return hash.map { String(format: "%02x", $0) }.joined()
        }
    }
}
