//
//  SyncService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import CoreData
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif

/// Service for managing CloudKit synchronization (ADR-007)
public actor SyncService {

    public static let shared = SyncService()

    // MARK: - State

    public enum SyncState: Sendable {
        case idle
        case syncing
        case error(Error)
    }

    private(set) var state: SyncState = .idle
    private(set) var lastSyncDate: Date?

    // MARK: - Dependencies

    private let persistenceController: PersistenceController
    private let fieldMerger: FieldMerger
    private let conflictDetector: ConflictDetector

    // MARK: - Initialization

    private init() {
        self.persistenceController = .shared
        self.fieldMerger = .shared
        self.conflictDetector = .shared
    }

    /// Initialize with custom dependencies (for testing)
    public init(
        persistenceController: PersistenceController,
        fieldMerger: FieldMerger,
        conflictDetector: ConflictDetector
    ) {
        self.persistenceController = persistenceController
        self.fieldMerger = fieldMerger
        self.conflictDetector = conflictDetector
    }

    // MARK: - Sync Operations

    /// Start sync monitoring
    public func startSync() {
        guard persistenceController.isCloudKitEnabled else {
            Logger.sync.warning("CloudKit sync not enabled")
            return
        }

        Logger.sync.info("Starting CloudKit sync monitoring")
        state = .idle

        // Configure merge policy
        Task { @MainActor in
            persistenceController.configureCloudKitMerging()
        }
    }

    /// Stop sync monitoring
    public func stopSync() {
        Logger.sync.info("Stopping CloudKit sync monitoring")
        state = .idle
    }

    /// Trigger a manual sync
    public func triggerSync() async throws {
        guard persistenceController.isCloudKitEnabled else {
            throw SyncError.networkError(NSError(domain: "SyncService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "CloudKit sync not enabled"
            ]))
        }

        Logger.sync.info("Triggering manual sync")
        state = .syncing

        do {
            // Save any pending changes
            await MainActor.run {
                persistenceController.save()
            }

            // CloudKit will handle the actual sync
            // Our merge policy handles conflicts automatically

            state = .idle
            lastSyncDate = Date()

            Logger.sync.info("Manual sync completed")

            // Notify UI
            await MainActor.run {
                NotificationCenter.default.post(name: .syncDidComplete, object: nil)
            }
        } catch {
            state = .error(error)
            Logger.sync.error("Sync failed: \(error)")
            throw error
        }
    }

    // MARK: - Conflict Handling

    /// Process incoming publication and handle any conflicts
    public func processIncomingPublication(
        _ publication: CDPublication,
        context: NSManagedObjectContext
    ) async throws {
        Logger.sync.info("Processing incoming publication: \(publication.citeKey)")

        // Check for cite key conflicts
        if let conflict = await conflictDetector.detectCiteKeyConflict(incoming: publication, in: context) {
            Logger.sync.info("Cite key conflict detected, queuing for resolution")
            await MainActor.run {
                SyncConflictQueue.shared.enqueue(.citeKey(conflict))
            }
            return
        }

        // Check for duplicate by identifiers
        if let existing = await conflictDetector.detectDuplicateByIdentifiers(incoming: publication, in: context) {
            Logger.sync.info("Duplicate detected by identifiers, merging")
            let _ = await fieldMerger.merge(local: existing, remote: publication, context: context)
            context.delete(publication)
            return
        }

        // No conflicts - publication is ready
        Logger.sync.info("Publication processed successfully: \(publication.citeKey)")
    }

    // MARK: - PDF Sync

    /// Sync PDF files for a publication
    public func syncPDFsForPublication(
        _ publication: CDPublication,
        localPapersURL: URL
    ) async throws {
        guard let linkedFiles = publication.linkedFiles else { return }

        for file in linkedFiles where file.isPDF {
            let localURL = localPapersURL.appendingPathComponent(file.relativePath)

            // Check if local file exists
            let localExists = FileManager.default.fileExists(atPath: localURL.path)

            if !localExists && publication.hasPDFDownloaded {
                // Local file was deleted but we expected it - mark as not downloaded
                publication.hasPDFDownloaded = false
                publication.pdfDownloadDate = nil
                Logger.sync.warning("PDF file missing for \(publication.citeKey): \(file.relativePath)")
            }
        }
    }

    // MARK: - Import with Conflict Detection

    /// Import a BibTeX entry with automatic conflict detection
    public func importWithConflictDetection(
        _ entry: BibTeXEntry,
        to library: CDLibrary,
        context: NSManagedObjectContext
    ) async throws -> CDPublication {
        // Create publication
        let publication = CDPublication(context: context)
        publication.id = UUID()
        publication.citeKey = entry.citeKey
        publication.entryType = entry.entryType
        publication.rawBibTeX = entry.rawBibTeX
        publication.dateAdded = Date()
        publication.dateModified = Date()

        // Set fields
        publication.update(from: entry, context: context)

        // Add to library
        publication.addToLibrary(library)

        // Check for conflicts
        if let conflict = await conflictDetector.detectCiteKeyConflict(incoming: publication, in: context) {
            // Queue conflict for user resolution
            await MainActor.run {
                SyncConflictQueue.shared.enqueue(.citeKey(conflict))
            }

            // For now, auto-rename the incoming publication
            publication.citeKey = "\(entry.citeKey)_\(UUID().uuidString.prefix(4))"
            Logger.sync.info("Auto-renamed conflicting publication to: \(publication.citeKey)")
        }

        return publication
    }
}

// MARK: - Sync Status

public extension SyncService {

    /// Get current sync status for UI
    var syncStatus: SyncStatus {
        switch state {
        case .idle:
            if let lastSync = lastSyncDate {
                return .synced(lastSync)
            }
            return .notSynced
        case .syncing:
            return .syncing
        case .error(let error):
            return .error(error.localizedDescription)
        }
    }

    /// Sync status for UI display
    enum SyncStatus: Sendable {
        case notSynced
        case syncing
        case synced(Date)
        case error(String)

        public var description: String {
            switch self {
            case .notSynced:
                return "Not synced"
            case .syncing:
                return "Syncing..."
            case .synced(let date):
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
            case .error(let message):
                return "Sync error: \(message)"
            }
        }

        public var icon: String {
            switch self {
            case .notSynced: return "icloud.slash"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .synced: return "checkmark.icloud"
            case .error: return "exclamationmark.icloud"
            }
        }
    }
}
