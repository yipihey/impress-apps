//
//  DocumentBackupService.swift
//  imprint
//
//  Created by Claude on 2026-01-28.
//

import Foundation
import OSLog

/// Service for safely backing up .imprint document bundles.
///
/// Provides:
/// - Pre-migration backup
/// - Export to external location
/// - Backup verification
/// - Automatic cleanup of old backups
public actor DocumentBackupService {

    // MARK: - Properties

    private let fileManager: FileManager
    private let backupDirectory: URL

    // MARK: - Initialization

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        // Store backups in Application Support
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.backupDirectory = appSupport.appendingPathComponent("imprint/Backups", isDirectory: true)
    }

    // MARK: - Public API

    /// Create a backup of a document before migration or risky operation.
    ///
    /// - Parameter documentURL: URL of the .imprint bundle to backup.
    /// - Returns: URL of the backup.
    public func backupDocument(at documentURL: URL) async throws -> URL {
        // Ensure backup directory exists
        if !fileManager.fileExists(atPath: backupDirectory.path) {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        }

        // Create timestamped backup name
        let originalName = documentURL.deletingPathExtension().lastPathComponent
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupName = "\(originalName)-backup-\(timestamp).imprint"

        let backupURL = backupDirectory.appendingPathComponent(backupName)

        // Copy the entire bundle
        try fileManager.copyItem(at: documentURL, to: backupURL)

        Logger.backup.info("Created backup at: \(backupURL.path)")
        return backupURL
    }

    /// Export a document to a user-specified location.
    ///
    /// - Parameters:
    ///   - documentURL: URL of the .imprint bundle to export.
    ///   - destinationURL: Where to save the export.
    /// - Returns: URL of the exported document.
    public func exportDocument(at documentURL: URL, to destinationURL: URL) async throws -> URL {
        // Remove existing file at destination if present
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: documentURL, to: destinationURL)

        Logger.backup.info("Exported document to: \(destinationURL.path)")
        return destinationURL
    }

    /// Verify a backup's integrity.
    ///
    /// - Parameter backupURL: URL of the backup to verify.
    /// - Returns: Verification result.
    public func verifyBackup(at backupURL: URL) async throws -> DocumentBackupVerificationResult {
        var issues: [String] = []

        // Check that it's a directory (bundle)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: backupURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return DocumentBackupVerificationResult(
                isValid: false,
                issues: ["Backup is not a valid document bundle"]
            )
        }

        // Check for required files
        let requiredFiles = ["main.typ", "metadata.json"]
        for filename in requiredFiles {
            let fileURL = backupURL.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: fileURL.path) {
                issues.append("Missing required file: \(filename)")
            }
        }

        // Check metadata can be read
        let metadataURL = backupURL.appendingPathComponent("metadata.json")
        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                let data = try Data(contentsOf: metadataURL)
                _ = try JSONDecoder().decode(VersionedDocumentMetadata.self, from: data)
            } catch {
                issues.append("Metadata is corrupted: \(error.localizedDescription)")
            }
        }

        // Check CRDT state if present
        let crdtURL = backupURL.appendingPathComponent("document.crdt")
        if fileManager.fileExists(atPath: crdtURL.path) {
            let data = try Data(contentsOf: crdtURL)
            if data.isEmpty {
                issues.append("CRDT state file is empty")
            }
        }

        return DocumentBackupVerificationResult(
            isValid: issues.isEmpty,
            issues: issues
        )
    }

    /// List all backups for a document.
    ///
    /// - Parameter documentName: Name of the original document.
    /// - Returns: List of backup information, sorted by date (newest first).
    public func listBackups(for documentName: String? = nil) -> [DocumentBackupInfo] {
        guard fileManager.fileExists(atPath: backupDirectory.path) else {
            return []
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            return contents.compactMap { url -> DocumentBackupInfo? in
                // Filter by document name if specified
                if let name = documentName {
                    guard url.lastPathComponent.hasPrefix(name) else { return nil }
                }

                // Only include .imprint bundles
                guard url.pathExtension == "imprint" else { return nil }

                let resources = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])

                // Try to read metadata
                var title: String?
                let metadataURL = url.appendingPathComponent("metadata.json")
                if let data = try? Data(contentsOf: metadataURL),
                   let metadata = try? JSONDecoder().decode(VersionedDocumentMetadata.self, from: data) {
                    title = metadata.title
                }

                return DocumentBackupInfo(
                    url: url,
                    originalName: extractOriginalName(from: url.lastPathComponent),
                    title: title,
                    createdAt: resources?.creationDate ?? Date.distantPast,
                    sizeBytes: directorySize(at: url)
                )
            }.sorted { $0.createdAt > $1.createdAt }
        } catch {
            Logger.backup.warning("Failed to list backups: \(error.localizedDescription)")
            return []
        }
    }

    /// Delete old backups, keeping the most recent ones.
    ///
    /// - Parameters:
    ///   - documentName: Optional name to filter by.
    ///   - keepCount: Number of backups to keep per document.
    public func cleanupOldBackups(for documentName: String? = nil, keepCount: Int = 5) async throws {
        let backups = listBackups(for: documentName)

        // Group by original document name
        var grouped: [String: [DocumentBackupInfo]] = [:]
        for backup in backups {
            grouped[backup.originalName, default: []].append(backup)
        }

        // Delete old backups for each document
        for (_, docBackups) in grouped {
            let toDelete = docBackups.dropFirst(keepCount)
            for backup in toDelete {
                try fileManager.removeItem(at: backup.url)
                Logger.backup.info("Deleted old backup: \(backup.url.lastPathComponent)")
            }
        }
    }

    /// Restore a document from backup.
    ///
    /// - Parameters:
    ///   - backupURL: URL of the backup.
    ///   - destinationURL: Where to restore the document.
    /// - Returns: URL of the restored document.
    public func restoreFromBackup(at backupURL: URL, to destinationURL: URL) async throws -> URL {
        // Verify backup first
        let verification = try await verifyBackup(at: backupURL)
        guard verification.isValid else {
            throw DocumentBackupError.invalidBackup(issues: verification.issues)
        }

        // Create backup of existing document if present
        if fileManager.fileExists(atPath: destinationURL.path) {
            let existingBackup = try await backupDocument(at: destinationURL)
            Logger.backup.info("Created backup of existing document: \(existingBackup.path)")
            try fileManager.removeItem(at: destinationURL)
        }

        // Copy backup to destination
        try fileManager.copyItem(at: backupURL, to: destinationURL)

        Logger.backup.info("Restored document from backup to: \(destinationURL.path)")
        return destinationURL
    }

    // MARK: - Private Methods

    private func extractOriginalName(from backupName: String) -> String {
        // Format: "OriginalName-backup-2026-01-28T12-00-00Z.imprint"
        let components = backupName.components(separatedBy: "-backup-")
        return components.first ?? backupName.replacingOccurrences(of: ".imprint", with: "")
    }

    private func directorySize(at url: URL) -> Int {
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

// MARK: - Supporting Types

/// Information about a document backup.
public struct DocumentBackupInfo: Identifiable {
    public var id: URL { url }
    public let url: URL
    public let originalName: String
    public let title: String?
    public let createdAt: Date
    public let sizeBytes: Int

    /// Human-readable size string.
    public var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// Result of backup verification.
public struct DocumentBackupVerificationResult {
    public let isValid: Bool
    public let issues: [String]
}

/// Errors that can occur during backup operations.
public enum DocumentBackupError: LocalizedError {
    case invalidBackup(issues: [String])
    case restoreFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBackup(let issues):
            return "Backup is invalid: \(issues.joined(separator: ", "))"
        case .restoreFailed(let reason):
            return "Failed to restore backup: \(reason)"
        }
    }
}

// MARK: - Logger Extension

private extension Logger {
    static let backup = Logger(subsystem: "com.imbib.imprint", category: "backup")
}
