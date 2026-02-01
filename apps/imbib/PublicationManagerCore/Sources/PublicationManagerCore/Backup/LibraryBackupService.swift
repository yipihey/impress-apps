//
//  LibraryBackupService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-28.
//

import Foundation
import CoreData
import OSLog

/// Service for creating comprehensive library backups.
///
/// Provides one-click full library export including:
/// - BibTeX file with all metadata
/// - All attachments (PDFs, images, supplementary files - preserving folder structure)
/// - Notes as JSON
/// - Settings backup
/// - Manifest with checksums for integrity verification
///
/// # Usage
///
/// ```swift
/// let backup = LibraryBackupService()
/// let backupURL = try await backup.exportFullBackup()
/// // Present share sheet or save panel with backupURL
/// ```
public actor LibraryBackupService {

    // MARK: - Properties

    private let persistenceController: PersistenceController
    private let fileManager: FileManager

    // MARK: - Progress

    /// Progress information for UI.
    public struct BackupProgress: Sendable {
        public let phase: Phase
        public let current: Int
        public let total: Int
        public let currentItem: String?

        public var fractionComplete: Double {
            guard total > 0 else { return 0 }
            return Double(current) / Double(total)
        }

        public enum Phase: String, Sendable {
            case preparing = "Preparing backup..."
            case exportingBibTeX = "Exporting BibTeX..."
            case copyingAttachments = "Copying attachments..."
            case exportingNotes = "Exporting notes..."
            case exportingSettings = "Exporting settings..."
            case creatingManifest = "Creating manifest..."
            case compressing = "Compressing..."
            case complete = "Complete"
        }
    }

    /// Progress callback type.
    public typealias ProgressHandler = @Sendable (BackupProgress) -> Void

    // MARK: - Initialization

    public init(
        persistenceController: PersistenceController = .shared,
        fileManager: FileManager = .default
    ) {
        self.persistenceController = persistenceController
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Export a full library backup.
    ///
    /// Creates a timestamped backup folder containing:
    /// - `library.bib` - All publications as BibTeX
    /// - `Attachments/` - All linked files (PDFs, images, etc., preserving relative paths)
    /// - `notes.json` - All notes
    /// - `settings.json` - App settings
    /// - `manifest.json` - File checksums for integrity
    ///
    /// - Parameter progressHandler: Optional callback for progress updates.
    /// - Returns: URL of the backup folder.
    public func exportFullBackup(progressHandler: ProgressHandler? = nil) async throws -> URL {
        let backupURL = try createBackupDirectory()

        // Phase 1: Export BibTeX
        progressHandler?(BackupProgress(phase: .exportingBibTeX, current: 0, total: 1, currentItem: nil))
        try await exportBibTeX(to: backupURL)

        // Phase 2: Copy all attachments (PDFs, images, supplementary files, etc.)
        progressHandler?(BackupProgress(phase: .copyingAttachments, current: 0, total: 1, currentItem: nil))
        let attachmentCount = try await copyAttachments(to: backupURL, progressHandler: progressHandler)

        // Phase 3: Export notes
        progressHandler?(BackupProgress(phase: .exportingNotes, current: 0, total: 1, currentItem: nil))
        try await exportNotes(to: backupURL)

        // Phase 4: Export settings
        progressHandler?(BackupProgress(phase: .exportingSettings, current: 0, total: 1, currentItem: nil))
        try await exportSettings(to: backupURL)

        // Phase 5: Create manifest
        progressHandler?(BackupProgress(phase: .creatingManifest, current: 0, total: 1, currentItem: nil))
        try await createManifest(at: backupURL)

        progressHandler?(BackupProgress(phase: .complete, current: 1, total: 1, currentItem: nil))

        Logger.backup.info("Full backup created at: \(backupURL.path)")
        return backupURL
    }

    /// Export library as a compressed archive.
    ///
    /// - Parameter progressHandler: Optional callback for progress updates.
    /// - Returns: URL of the .zip archive.
    public func exportCompressedBackup(progressHandler: ProgressHandler? = nil) async throws -> URL {
        let backupURL = try await exportFullBackup(progressHandler: progressHandler)

        progressHandler?(BackupProgress(phase: .compressing, current: 0, total: 1, currentItem: nil))

        let archiveURL = backupURL.deletingPathExtension().appendingPathExtension("zip")
        try await compressDirectory(at: backupURL, to: archiveURL)

        // Remove uncompressed folder
        try fileManager.removeItem(at: backupURL)

        progressHandler?(BackupProgress(phase: .complete, current: 1, total: 1, currentItem: nil))

        return archiveURL
    }

    /// Verify a backup's integrity using its manifest.
    ///
    /// - Parameter backupURL: URL of the backup folder.
    /// - Returns: Verification result.
    public func verifyBackup(at backupURL: URL) async throws -> BackupVerificationResult {
        let manifestURL = backupURL.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)

        var missingFiles: [String] = []
        var corruptedFiles: [String] = []

        for (path, expectedChecksum) in manifest.fileChecksums {
            let fileURL = backupURL.appendingPathComponent(path)

            if fileManager.fileExists(atPath: fileURL.path) {
                let actualChecksum = try computeChecksum(for: fileURL)
                if actualChecksum != expectedChecksum {
                    corruptedFiles.append(path)
                }
            } else {
                missingFiles.append(path)
            }
        }

        return BackupVerificationResult(
            isValid: missingFiles.isEmpty && corruptedFiles.isEmpty,
            missingFiles: missingFiles,
            corruptedFiles: corruptedFiles,
            manifest: manifest
        )
    }

    /// Get list of available backups.
    public func listBackups() -> [BackupInfo] {
        let backupsDir = getBackupsDirectory()

        guard fileManager.fileExists(atPath: backupsDir.path) else {
            return []
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: backupsDir,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            return contents.compactMap { url in
                guard url.lastPathComponent.hasPrefix("imbib-backup-") else { return nil }

                let resources = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                let manifestURL = url.appendingPathComponent("manifest.json")

                var publicationCount = 0
                var attachmentCount = 0

                if let manifestData = try? Data(contentsOf: manifestURL),
                   let manifest = try? JSONDecoder().decode(BackupManifest.self, from: manifestData) {
                    publicationCount = manifest.publicationCount
                    attachmentCount = manifest.attachmentCount
                }

                return BackupInfo(
                    url: url,
                    createdAt: resources?.creationDate ?? Date.distantPast,
                    sizeBytes: resources?.fileSize ?? 0,
                    publicationCount: publicationCount,
                    attachmentCount: attachmentCount
                )
            }.sorted { $0.createdAt > $1.createdAt }
        } catch {
            Logger.backup.warning("Failed to list backups: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Private Methods

    private func createBackupDirectory() throws -> URL {
        let backupsDir = getBackupsDirectory()

        if !fileManager.fileExists(atPath: backupsDir.path) {
            try fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupsDir.appendingPathComponent("imbib-backup-\(timestamp)", isDirectory: true)

        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)

        return backupURL
    }

    private func getBackupsDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("imbib/Backups", isDirectory: true)
    }

    private func exportBibTeX(to backupURL: URL) async throws {
        let bibURL = backupURL.appendingPathComponent("library.bib")

        let publications = await MainActor.run { () -> [CDPublication] in
            let context = persistenceController.viewContext
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.sortDescriptors = [NSSortDescriptor(key: "citeKey", ascending: true)]
            return (try? context.fetch(request)) ?? []
        }

        var bibContent = "% imbib Library Backup\n"
        bibContent += "% Generated: \(Date())\n"
        bibContent += "% Publications: \(publications.count)\n\n"

        for publication in publications {
            if let bibtex = publication.rawBibTeX {
                bibContent += bibtex
                bibContent += "\n\n"
            }
        }

        try bibContent.write(to: bibURL, atomically: true, encoding: .utf8)
        Logger.backup.info("Exported \(publications.count) publications to BibTeX")
    }

    private func copyAttachments(to backupURL: URL, progressHandler: ProgressHandler?) async throws -> Int {
        let attachmentsURL = backupURL.appendingPathComponent("Attachments", isDirectory: true)
        try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        // Get all publications with linked files and their resolved URLs
        let attachmentFiles = await MainActor.run { () -> [(citeKey: String, relativePath: String, sourceURL: URL)] in
            let context = persistenceController.viewContext
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            let results = (try? context.fetch(request)) ?? []

            var files: [(citeKey: String, relativePath: String, sourceURL: URL)] = []
            for pub in results {
                guard let linkedFiles = pub.linkedFiles, !linkedFiles.isEmpty,
                      let library = pub.libraries?.first else {
                    continue
                }

                for linkedFile in linkedFiles {
                    if let sourceURL = AttachmentManager.shared.resolveURL(for: linkedFile, in: library) {
                        files.append((citeKey: pub.citeKey, relativePath: linkedFile.relativePath, sourceURL: sourceURL))
                    }
                }
            }
            return files
        }

        var copiedCount = 0
        for (index, fileInfo) in attachmentFiles.enumerated() {
            progressHandler?(BackupProgress(
                phase: .copyingAttachments,
                current: index,
                total: attachmentFiles.count,
                currentItem: fileInfo.citeKey
            ))

            if fileManager.fileExists(atPath: fileInfo.sourceURL.path) {
                let destURL = attachmentsURL.appendingPathComponent(fileInfo.relativePath)

                // Create subdirectories if needed
                let destDir = destURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: destDir.path) {
                    try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
                }

                try fileManager.copyItem(at: fileInfo.sourceURL, to: destURL)
                copiedCount += 1
            } else {
                Logger.backup.warning("Attachment not found at: \(fileInfo.sourceURL.path)")
            }
        }

        Logger.backup.info("Copied \(copiedCount) attachment files")
        return copiedCount
    }

    private func exportNotes(to backupURL: URL) async throws {
        let notesURL = backupURL.appendingPathComponent("notes.json")

        let notes = await MainActor.run { () -> [[String: Any]] in
            let context = persistenceController.viewContext
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            let publications = (try? context.fetch(request)) ?? []

            return publications.compactMap { pub -> [String: Any]? in
                guard let noteField = pub.fields["note"], !noteField.isEmpty else {
                    return nil
                }
                return [
                    "citeKey": pub.citeKey,
                    "note": noteField
                ]
            }
        }

        let notesData = try JSONSerialization.data(withJSONObject: notes, options: .prettyPrinted)
        try notesData.write(to: notesURL)

        Logger.backup.info("Exported \(notes.count) notes")
    }

    private func exportSettings(to backupURL: URL) async throws {
        let settingsURL = backupURL.appendingPathComponent("settings.json")

        // Export synced settings
        let settings = await SyncedSettingsStore.shared.exportAllSettings()
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
        try settingsData.write(to: settingsURL)

        Logger.backup.info("Exported settings")
    }

    private func createManifest(at backupURL: URL) async throws {
        let contents = try fileManager.contentsOfDirectory(
            at: backupURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var checksums: [String: String] = [:]
        var attachmentCount = 0

        for fileURL in contents {
            let relativePath = fileURL.lastPathComponent

            if fileURL.hasDirectoryPath {
                // Recursively process directories
                try await processDirectory(at: fileURL, relativeTo: backupURL, checksums: &checksums, attachmentCount: &attachmentCount)
            } else {
                checksums[relativePath] = try computeChecksum(for: fileURL)
            }
        }

        // Get publication count
        let publicationCount = await MainActor.run { () -> Int in
            let context = persistenceController.viewContext
            let request = NSFetchRequest<NSNumber>(entityName: "Publication")
            request.resultType = .countResultType
            return (try? context.fetch(request).first?.intValue) ?? 0
        }

        let manifest = BackupManifest(
            version: 1,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            schemaVersion: SchemaVersion.current.rawValue,
            publicationCount: publicationCount,
            attachmentCount: attachmentCount,
            fileChecksums: checksums
        )

        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: backupURL.appendingPathComponent("manifest.json"))
    }

    private func processDirectory(
        at url: URL,
        relativeTo baseURL: URL,
        checksums: inout [String: String],
        attachmentCount: inout Int
    ) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        // Check if we're in the Attachments directory
        let isAttachmentsDir = url.path.contains("/Attachments")

        for fileURL in contents {
            let relativePath = fileURL.path.replacingOccurrences(of: baseURL.path + "/", with: "")

            if fileURL.hasDirectoryPath {
                try processDirectory(at: fileURL, relativeTo: baseURL, checksums: &checksums, attachmentCount: &attachmentCount)
            } else {
                checksums[relativePath] = try computeChecksum(for: fileURL)
                if isAttachmentsDir {
                    attachmentCount += 1
                }
            }
        }
    }

    private func computeChecksum(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let hash = data.withUnsafeBytes { buffer -> String in
            var hash: [UInt8] = Array(repeating: 0, count: 32)
            // Simple checksum using XOR folding (not cryptographic)
            for (index, byte) in buffer.enumerated() {
                hash[index % 32] ^= byte
            }
            return hash.map { String(format: "%02x", $0) }.joined()
        }
        return hash
    }

    private func compressDirectory(at source: URL, to destination: URL) async throws {
        // Use ditto for macOS compression
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", source.path, destination.path]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw BackupError.compressionFailed
        }
        #else
        // For iOS, just return the folder (compression would need different approach)
        throw BackupError.compressionNotSupported
        #endif
    }

}

// MARK: - Supporting Types

/// Backup manifest for integrity verification.
public struct BackupManifest: Codable {
    public let version: Int
    public let createdAt: Date
    public let appVersion: String
    public let schemaVersion: Int
    public let publicationCount: Int
    public let attachmentCount: Int
    public let fileChecksums: [String: String]

    // For backward compatibility with older backups
    private enum CodingKeys: String, CodingKey {
        case version, createdAt, appVersion, schemaVersion, publicationCount
        case attachmentCount
        case pdfCount  // Legacy key for reading old backups
        case fileChecksums
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        publicationCount = try container.decode(Int.self, forKey: .publicationCount)
        // Try attachmentCount first, fall back to pdfCount for old backups
        attachmentCount = try container.decodeIfPresent(Int.self, forKey: .attachmentCount)
            ?? container.decodeIfPresent(Int.self, forKey: .pdfCount)
            ?? 0
        fileChecksums = try container.decode([String: String].self, forKey: .fileChecksums)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(publicationCount, forKey: .publicationCount)
        try container.encode(attachmentCount, forKey: .attachmentCount)
        try container.encode(fileChecksums, forKey: .fileChecksums)
    }

    public init(
        version: Int,
        createdAt: Date,
        appVersion: String,
        schemaVersion: Int,
        publicationCount: Int,
        attachmentCount: Int,
        fileChecksums: [String: String]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
        self.publicationCount = publicationCount
        self.attachmentCount = attachmentCount
        self.fileChecksums = fileChecksums
    }
}

/// Information about a backup.
public struct BackupInfo: Identifiable {
    public var id: URL { url }
    public let url: URL
    public let createdAt: Date
    public let sizeBytes: Int
    public let publicationCount: Int
    public let attachmentCount: Int

    /// Human-readable size string.
    public var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// Result of backup verification.
public struct BackupVerificationResult {
    public let isValid: Bool
    public let missingFiles: [String]
    public let corruptedFiles: [String]
    public let manifest: BackupManifest
}

/// Errors that can occur during backup.
public enum BackupError: LocalizedError {
    case compressionFailed
    case compressionNotSupported
    case verificationFailed(missingFiles: [String], corruptedFiles: [String])

    public var errorDescription: String? {
        switch self {
        case .compressionFailed:
            return "Failed to compress backup"
        case .compressionNotSupported:
            return "Compression is not supported on this platform"
        case .verificationFailed(let missing, let corrupted):
            return "Backup verification failed: \(missing.count) missing, \(corrupted.count) corrupted"
        }
    }
}

// MARK: - Logger Extension

private extension Logger {
    static let backup = Logger(subsystem: "com.imbib.app", category: "backup")
}
