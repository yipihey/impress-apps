//
//  BackupRestoreService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import CoreData
import OSLog

/// Service for restoring library backups.
///
/// Provides functionality to restore backups created by `LibraryBackupService`:
/// - Parse backup manifest and validate contents
/// - Import publications from BibTeX
/// - Relink attachments from backup Attachments folder
/// - Import notes from notes.json
/// - Optionally restore settings from settings.json
/// - Support merge (add to existing) vs replace (clear and restore) modes
///
/// # Usage
///
/// ```swift
/// let restore = BackupRestoreService()
///
/// // Preview what will be restored
/// let preview = try await restore.prepareRestore(from: backupURL)
///
/// // Execute the restore
/// let options = RestoreOptions(mode: .merge, ...)
/// let result = try await restore.executeRestore(from: backupURL, options: options)
/// ```
public actor BackupRestoreService {

    // MARK: - Types

    /// Mode for restore operation.
    public enum RestoreMode: String, CaseIterable, Sendable {
        /// Add backup contents to existing library (skip duplicates by cite key)
        case merge
        /// Clear existing library and restore only backup contents
        case replace
    }

    /// Options for restore operation.
    public struct RestoreOptions: Sendable {
        public let mode: RestoreMode
        public let restorePublications: Bool
        public let restoreAttachments: Bool
        public let restoreNotes: Bool
        public let restoreSettings: Bool

        public init(
            mode: RestoreMode = .merge,
            restorePublications: Bool = true,
            restoreAttachments: Bool = true,
            restoreNotes: Bool = true,
            restoreSettings: Bool = false
        ) {
            self.mode = mode
            self.restorePublications = restorePublications
            self.restoreAttachments = restoreAttachments
            self.restoreNotes = restoreNotes
            self.restoreSettings = restoreSettings
        }

        /// Default options: merge mode, all content except settings
        public static let `default` = RestoreOptions()
    }

    /// Preview of what will be restored.
    public struct RestorePreview: Sendable {
        public let backupDate: Date
        public let appVersion: String
        public let schemaVersion: Int
        public let publicationCount: Int
        public let attachmentCount: Int
        public let notesCount: Int
        public let hasSettings: Bool
        public let isValid: Bool
        public let validationIssues: [String]
    }

    /// Result of restore operation.
    public struct RestoreResult: Sendable {
        public let publicationsRestored: Int
        public let publicationsSkipped: Int
        public let attachmentsRestored: Int
        public let attachmentsMissing: Int
        public let notesRestored: Int
        public let settingsRestored: Bool
        public let warnings: [String]
    }

    // MARK: - Progress

    /// Progress information for UI.
    public struct RestoreProgress: Sendable {
        public let phase: Phase
        public let current: Int
        public let total: Int
        public let currentItem: String?

        public var fractionComplete: Double {
            guard total > 0 else { return 0 }
            return Double(current) / Double(total)
        }

        public enum Phase: String, Sendable {
            case preparing = "Preparing restore..."
            case clearingLibrary = "Clearing existing library..."
            case importingPublications = "Importing publications..."
            case restoringAttachments = "Restoring attachments..."
            case importingNotes = "Importing notes..."
            case importingSettings = "Importing settings..."
            case complete = "Complete"
        }
    }

    /// Progress callback type.
    public typealias ProgressHandler = @Sendable (RestoreProgress) -> Void

    // MARK: - Properties

    private let persistenceController: PersistenceController
    private let fileManager: FileManager

    // MARK: - Initialization

    public init(
        persistenceController: PersistenceController = .shared,
        fileManager: FileManager = .default
    ) {
        self.persistenceController = persistenceController
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Preview what will be restored from a backup.
    ///
    /// Reads the backup manifest and validates contents without modifying anything.
    ///
    /// - Parameter backupURL: URL of the backup folder
    /// - Returns: Preview of backup contents
    public func prepareRestore(from backupURL: URL) async throws -> RestorePreview {
        Logger.backup.info("Preparing restore from: \(backupURL.path)")

        // Read manifest
        let manifestURL = backupURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw RestoreError.manifestNotFound
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)

        // Check for notes
        let notesURL = backupURL.appendingPathComponent("notes.json")
        var notesCount = 0
        if fileManager.fileExists(atPath: notesURL.path) {
            if let notesData = try? Data(contentsOf: notesURL),
               let notes = try? JSONSerialization.jsonObject(with: notesData) as? [[String: Any]] {
                notesCount = notes.count
            }
        }

        // Check for settings
        let settingsURL = backupURL.appendingPathComponent("settings.json")
        let hasSettings = fileManager.fileExists(atPath: settingsURL.path)

        // Validate backup
        var validationIssues: [String] = []
        let bibURL = backupURL.appendingPathComponent("library.bib")
        if !fileManager.fileExists(atPath: bibURL.path) {
            validationIssues.append("library.bib not found")
        }

        // Check schema version compatibility
        if manifest.schemaVersion > SchemaVersion.current.rawValue {
            validationIssues.append("Backup from newer app version (schema \(manifest.schemaVersion) > \(SchemaVersion.current.rawValue))")
        }

        return RestorePreview(
            backupDate: manifest.createdAt,
            appVersion: manifest.appVersion,
            schemaVersion: manifest.schemaVersion,
            publicationCount: manifest.publicationCount,
            attachmentCount: manifest.attachmentCount,
            notesCount: notesCount,
            hasSettings: hasSettings,
            isValid: validationIssues.isEmpty,
            validationIssues: validationIssues
        )
    }

    /// Execute a restore operation.
    ///
    /// - Parameters:
    ///   - backupURL: URL of the backup folder
    ///   - options: Restore options (mode, what to restore)
    ///   - progressHandler: Optional callback for progress updates
    /// - Returns: Result of the restore operation
    public func executeRestore(
        from backupURL: URL,
        options: RestoreOptions,
        progressHandler: ProgressHandler? = nil
    ) async throws -> RestoreResult {
        Logger.backup.info("Executing restore from: \(backupURL.path) with mode: \(options.mode.rawValue)")

        progressHandler?(RestoreProgress(phase: .preparing, current: 0, total: 1, currentItem: nil))

        var warnings: [String] = []

        // Phase 1: Clear library if replace mode
        if options.mode == .replace {
            progressHandler?(RestoreProgress(phase: .clearingLibrary, current: 0, total: 1, currentItem: nil))
            await clearAllPublications()
        }

        // Phase 2: Import publications
        var publicationsRestored = 0
        var publicationsSkipped = 0

        if options.restorePublications {
            let bibURL = backupURL.appendingPathComponent("library.bib")
            if fileManager.fileExists(atPath: bibURL.path) {
                let result = try await importPublications(
                    from: bibURL,
                    mode: options.mode,
                    progressHandler: progressHandler
                )
                publicationsRestored = result.imported
                publicationsSkipped = result.skipped
            } else {
                warnings.append("library.bib not found in backup")
            }
        }

        // Phase 3: Restore attachments
        var attachmentsRestored = 0
        var attachmentsMissing = 0

        if options.restoreAttachments {
            let attachmentsURL = backupURL.appendingPathComponent("Attachments")
            if fileManager.fileExists(atPath: attachmentsURL.path) {
                let result = try await restoreAttachments(
                    from: attachmentsURL,
                    progressHandler: progressHandler
                )
                attachmentsRestored = result.restored
                attachmentsMissing = result.missing
            }
        }

        // Phase 4: Import notes
        var notesRestored = 0

        if options.restoreNotes {
            let notesURL = backupURL.appendingPathComponent("notes.json")
            if fileManager.fileExists(atPath: notesURL.path) {
                progressHandler?(RestoreProgress(phase: .importingNotes, current: 0, total: 1, currentItem: nil))
                notesRestored = try await importNotes(from: notesURL)
            }
        }

        // Phase 5: Import settings
        var settingsRestored = false

        if options.restoreSettings {
            let settingsURL = backupURL.appendingPathComponent("settings.json")
            if fileManager.fileExists(atPath: settingsURL.path) {
                progressHandler?(RestoreProgress(phase: .importingSettings, current: 0, total: 1, currentItem: nil))
                try await importSettings(from: settingsURL)
                settingsRestored = true
            }
        }

        progressHandler?(RestoreProgress(phase: .complete, current: 1, total: 1, currentItem: nil))

        Logger.backup.info("Restore complete: \(publicationsRestored) publications, \(attachmentsRestored) attachments, \(notesRestored) notes")

        return RestoreResult(
            publicationsRestored: publicationsRestored,
            publicationsSkipped: publicationsSkipped,
            attachmentsRestored: attachmentsRestored,
            attachmentsMissing: attachmentsMissing,
            notesRestored: notesRestored,
            settingsRestored: settingsRestored,
            warnings: warnings
        )
    }

    // MARK: - Private Methods

    /// Clear all publications from the library.
    private func clearAllPublications() async {
        Logger.backup.info("Clearing all publications for replace mode")
        let context = persistenceController.viewContext

        await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            do {
                let publications = try context.fetch(request)
                for publication in publications {
                    context.delete(publication)
                }
                self.persistenceController.save()
                Logger.backup.info("Cleared \(publications.count) publications")
            } catch {
                Logger.backup.error("Failed to clear publications: \(error.localizedDescription)")
            }
        }
    }

    /// Import publications from BibTeX file.
    private func importPublications(
        from bibURL: URL,
        mode: RestoreMode,
        progressHandler: ProgressHandler?
    ) async throws -> (imported: Int, skipped: Int) {
        Logger.backup.info("Importing publications from: \(bibURL.path)")

        let bibContent = try String(contentsOf: bibURL, encoding: .utf8)
        let parser = BibTeXParser()
        let entries = try parser.parseEntries(bibContent)

        Logger.backup.info("Parsed \(entries.count) entries from backup")

        var imported = 0
        var skipped = 0
        let repository = PublicationRepository(persistenceController: persistenceController)

        for (index, entry) in entries.enumerated() {
            progressHandler?(RestoreProgress(
                phase: .importingPublications,
                current: index,
                total: entries.count,
                currentItem: entry.citeKey
            ))

            // Check for duplicate in merge mode
            if mode == .merge {
                if let _ = await repository.fetch(byCiteKey: entry.citeKey) {
                    skipped += 1
                    continue
                }
            }

            // Create publication
            await repository.create(from: entry, processLinkedFiles: false)
            imported += 1
        }

        Logger.backup.info("Imported \(imported) publications, skipped \(skipped)")
        return (imported, skipped)
    }

    /// Restore attachments from backup Attachments folder.
    private func restoreAttachments(
        from attachmentsURL: URL,
        progressHandler: ProgressHandler?
    ) async throws -> (restored: Int, missing: Int) {
        Logger.backup.info("Restoring attachments from: \(attachmentsURL.path)")

        // Get the default library's Papers directory
        let papersURL = getPapersDirectory()

        // Ensure Papers directory exists
        if !fileManager.fileExists(atPath: papersURL.path) {
            try fileManager.createDirectory(at: papersURL, withIntermediateDirectories: true)
        }

        // Enumerate all files in Attachments folder
        guard let enumerator = fileManager.enumerator(
            at: attachmentsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var files: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues?.isRegularFile == true {
                files.append(fileURL)
            }
        }

        var restored = 0
        var missing = 0

        for (index, sourceURL) in files.enumerated() {
            // Get relative path within Attachments folder
            let relativePath = sourceURL.path.replacingOccurrences(of: attachmentsURL.path + "/", with: "")

            progressHandler?(RestoreProgress(
                phase: .restoringAttachments,
                current: index,
                total: files.count,
                currentItem: relativePath
            ))

            let destURL = papersURL.appendingPathComponent(relativePath)

            // Create subdirectories if needed
            let destDir = destURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: destDir.path) {
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            }

            // Skip if file already exists
            if fileManager.fileExists(atPath: destURL.path) {
                Logger.backup.debug("Attachment already exists: \(relativePath)")
                continue
            }

            // Copy file
            do {
                try fileManager.copyItem(at: sourceURL, to: destURL)
                restored += 1
            } catch {
                Logger.backup.warning("Failed to restore attachment \(relativePath): \(error.localizedDescription)")
                missing += 1
            }
        }

        // Now link attachments to publications
        await linkRestoredAttachments(papersURL: papersURL)

        Logger.backup.info("Restored \(restored) attachments, \(missing) failed")
        return (restored, missing)
    }

    /// Link restored attachments to their publications based on filename patterns.
    private func linkRestoredAttachments(papersURL: URL) async {
        let context = persistenceController.viewContext

        await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            let publications = (try? context.fetch(request)) ?? []

            for publication in publications {
                // Skip if already has linked files
                if let linkedFiles = publication.linkedFiles, !linkedFiles.isEmpty {
                    continue
                }

                // Try to find matching PDF by cite key pattern
                let patterns = [
                    "\(publication.citeKey).pdf",
                    "\(publication.citeKey)_*.pdf"
                ]

                for pattern in patterns {
                    let pdfURL = papersURL.appendingPathComponent(pattern.replacingOccurrences(of: "*", with: ""))
                    if self.fileManager.fileExists(atPath: pdfURL.path) {
                        let linkedFile = CDLinkedFile(context: context)
                        linkedFile.id = UUID()
                        linkedFile.relativePath = "Papers/\(pdfURL.lastPathComponent)"
                        linkedFile.filename = pdfURL.lastPathComponent
                        linkedFile.fileType = "pdf"
                        linkedFile.dateAdded = Date()
                        linkedFile.publication = publication
                        break
                    }
                }
            }

            self.persistenceController.save()
        }
    }

    /// Import notes from notes.json.
    private func importNotes(from notesURL: URL) async throws -> Int {
        Logger.backup.info("Importing notes from: \(notesURL.path)")

        let notesData = try Data(contentsOf: notesURL)
        guard let notes = try JSONSerialization.jsonObject(with: notesData) as? [[String: Any]] else {
            throw RestoreError.invalidNotesFormat
        }

        let context = persistenceController.viewContext
        var restored = 0

        for noteEntry in notes {
            guard let citeKey = noteEntry["citeKey"] as? String,
                  let note = noteEntry["note"] as? String else {
                continue
            }

            await context.perform {
                let request = NSFetchRequest<CDPublication>(entityName: "Publication")
                request.predicate = NSPredicate(format: "citeKey == %@", citeKey)
                request.fetchLimit = 1

                if let publication = try? context.fetch(request).first {
                    var fields = publication.fields
                    fields["note"] = note
                    publication.fields = fields
                    restored += 1
                }
            }
        }

        await context.perform {
            self.persistenceController.save()
        }

        Logger.backup.info("Imported \(restored) notes")
        return restored
    }

    /// Import settings from settings.json.
    private func importSettings(from settingsURL: URL) async throws {
        Logger.backup.info("Importing settings from: \(settingsURL.path)")

        let settingsData = try Data(contentsOf: settingsURL)
        guard let settings = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw RestoreError.invalidSettingsFormat
        }

        SyncedSettingsStore.shared.importSettings(settings)
        Logger.backup.info("Imported settings")
    }

    /// Get the Papers directory for the default library.
    private func getPapersDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("imbib/DefaultLibrary/Papers", isDirectory: true)
    }
}

// MARK: - Restore Errors

/// Errors that can occur during restore.
public enum RestoreError: LocalizedError {
    case manifestNotFound
    case invalidBackupFormat
    case invalidNotesFormat
    case invalidSettingsFormat
    case schemaVersionMismatch(backup: Int, current: Int)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "Backup manifest not found"
        case .invalidBackupFormat:
            return "Invalid backup format"
        case .invalidNotesFormat:
            return "Invalid notes format in backup"
        case .invalidSettingsFormat:
            return "Invalid settings format in backup"
        case .schemaVersionMismatch(let backup, let current):
            return "Backup schema version (\(backup)) is newer than current (\(current))"
        }
    }
}

// MARK: - Logger Extension

private extension Logger {
    static let backup = Logger(subsystem: "com.imbib.app", category: "backup")
}
