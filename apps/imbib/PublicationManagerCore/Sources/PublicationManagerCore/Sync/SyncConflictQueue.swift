//
//  SyncConflictQueue.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import Combine
import OSLog

// MARK: - Sync Conflict

/// Represents a conflict that needs user resolution
public enum SyncConflict: Identifiable, Sendable, Hashable {
    case citeKey(CiteKeyConflict)
    case pdf(PDFConflict)

    public var id: String {
        switch self {
        case .citeKey(let c): return "citekey-\(c.id)"
        case .pdf(let c): return "pdf-\(c.id)"
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: SyncConflict, rhs: SyncConflict) -> Bool {
        lhs.id == rhs.id
    }

    public var title: String {
        switch self {
        case .citeKey(let c): return "Cite Key Conflict: \(c.citeKey)"
        case .pdf: return "PDF Conflict"
        }
    }

    public var description: String {
        switch self {
        case .citeKey(let c):
            return "Two publications have the same cite key: \"\(c.citeKey)\""
        case .pdf(let c):
            return "The PDF file \"\(c.localFilePath)\" was modified on multiple devices"
        }
    }

    public var detectedAt: Date {
        switch self {
        case .citeKey(let c): return c.detectedAt
        case .pdf(let c): return c.detectedAt
        }
    }
}

// MARK: - Sync Conflict Queue

/// Manages pending sync conflicts that need user resolution (ADR-007)
@MainActor
@Observable
public final class SyncConflictQueue {

    public static let shared = SyncConflictQueue()

    // MARK: - Published State

    public private(set) var pendingConflicts: [SyncConflict] = []

    /// Whether there are any unresolved conflicts
    public var hasConflicts: Bool {
        !pendingConflicts.isEmpty
    }

    /// Number of pending conflicts
    public var conflictCount: Int {
        pendingConflicts.count
    }

    /// Number of pending conflicts (alias for conflictCount)
    public var count: Int {
        conflictCount
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Queue Management

    /// Add a conflict to the queue
    public func enqueue(_ conflict: SyncConflict) {
        Logger.sync.info("Enqueuing conflict: \(conflict.id)")
        pendingConflicts.append(conflict)

        // Post notification for UI
        NotificationCenter.default.post(name: .syncConflictDetected, object: conflict)
    }

    /// Remove a conflict from the queue (after resolution)
    public func dequeue(_ conflict: SyncConflict) {
        pendingConflicts.removeAll { $0.id == conflict.id }
        Logger.sync.info("Dequeued conflict: \(conflict.id)")
    }

    /// Remove a conflict by ID
    public func dequeue(id: String) {
        pendingConflicts.removeAll { $0.id == id }
    }

    /// Clear all conflicts
    public func clearAll() {
        pendingConflicts.removeAll()
        Logger.sync.info("Cleared all sync conflicts")
    }

    /// Get the next conflict to resolve (oldest first)
    public func nextConflict() -> SyncConflict? {
        pendingConflicts.first
    }

    /// Get all cite key conflicts
    public var citeKeyConflicts: [CiteKeyConflict] {
        pendingConflicts.compactMap {
            if case .citeKey(let c) = $0 { return c }
            return nil
        }
    }

    /// Get all PDF conflicts
    public var pdfConflicts: [PDFConflict] {
        pendingConflicts.compactMap {
            if case .pdf(let c) = $0 { return c }
            return nil
        }
    }
}

// MARK: - Conflict Resolution

extension SyncConflictQueue {

    /// Resolve a cite key conflict with the given resolution
    public func resolveCiteKeyConflict(
        _ conflict: CiteKeyConflict,
        with resolution: CiteKeyResolution,
        context: NSManagedObjectContext
    ) async throws {
        Logger.sync.info("Resolving cite key conflict \(conflict.id) with \(resolution.id)")

        // Fetch the publications
        let incomingRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
        incomingRequest.predicate = NSPredicate(format: "id == %@", conflict.incomingPublicationID as CVarArg)

        let existingRequest = NSFetchRequest<CDPublication>(entityName: "Publication")
        existingRequest.predicate = NSPredicate(format: "id == %@", conflict.existingPublicationID as CVarArg)

        guard let incoming = try context.fetch(incomingRequest).first else {
            throw SyncError.publicationNotFound(conflict.incomingPublicationID)
        }

        guard let existing = try context.fetch(existingRequest).first else {
            throw SyncError.publicationNotFound(conflict.existingPublicationID)
        }

        switch resolution {
        case .renameIncoming(let newCiteKey):
            incoming.citeKey = newCiteKey
            incoming.dateModified = Date()

        case .renameExisting(let newCiteKey):
            existing.citeKey = newCiteKey
            existing.dateModified = Date()

        case .merge:
            // Merge incoming into existing, then delete incoming
            let _ = await FieldMerger.shared.merge(local: existing, remote: incoming, context: context)
            context.delete(incoming)

        case .keepBoth:
            // Rename both with unique suffixes
            let newIncomingKey = "\(conflict.citeKey)_\(UUID().uuidString.prefix(4))"
            let newExistingKey = existing.citeKey // Keep existing as-is
            incoming.citeKey = newIncomingKey
            incoming.dateModified = Date()
            _ = newExistingKey // Silence unused variable warning

        case .keepExisting:
            // Delete incoming
            context.delete(incoming)

        case .keepIncoming:
            // Delete existing
            context.delete(existing)
        }

        try context.save()
        dequeue(.citeKey(conflict))
    }

    /// Resolve a PDF conflict with the given resolution
    public func resolvePDFConflict(
        _ conflict: PDFConflict,
        with resolution: PDFConflictResolution,
        context: NSManagedObjectContext
    ) async throws {
        Logger.sync.info("Resolving PDF conflict \(conflict.id) with \(resolution)")

        // Fetch the publication and its linked file
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", conflict.publicationID as CVarArg)
        request.fetchLimit = 1

        guard let publication = try context.fetch(request).first,
              let library = publication.libraries?.first else {
            throw SyncError.publicationNotFound(conflict.publicationID)
        }

        // Find the linked file with the remote data
        let linkedFile = publication.linkedFiles?.first { $0.relativePath == conflict.remoteFilePath }

        switch resolution {
        case .keepLocal:
            // Nothing to do - local file is already in place
            // Just clear the remote fileData to save space
            if let linkedFile = linkedFile {
                linkedFile.fileData = nil
            }
            Logger.sync.info("PDF conflict resolved: kept local file")

        case .keepRemote:
            // Replace local with remote file data
            guard let linkedFile = linkedFile,
                  let remoteData = linkedFile.fileData else {
                Logger.sync.error("Cannot resolve keepRemote: no remote file data available")
                throw SyncError.fileNotFound(conflict.remoteFilePath)
            }

            // Get the local file path
            let localURL = library.containerURL.appendingPathComponent(conflict.localFilePath)

            // Write the remote data to the local path
            do {
                try remoteData.write(to: localURL)
                Logger.sync.info("PDF conflict resolved: replaced local with remote (\(remoteData.count) bytes)")

                // Update the linked file to point to local path and clear remote data
                linkedFile.relativePath = conflict.localFilePath
                linkedFile.fileData = nil
                linkedFile.dateAdded = conflict.remoteModifiedDate
            } catch {
                Logger.sync.error("Failed to write remote PDF data: \(error.localizedDescription)")
                throw SyncError.fileNotFound(conflict.localFilePath)
            }

        case .keepBoth:
            // Create a conflict copy with timestamp in filename
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
            let timestamp = dateFormatter.string(from: conflict.remoteModifiedDate)
                .replacingOccurrences(of: ":", with: "-")

            // Build conflict filename: Einstein_1905_Paper_conflict_2026-01-28T14-30-45Z.pdf
            let localPathStr = conflict.localFilePath
            let basePath = String(localPathStr.dropLast(4)) // Remove .pdf
            let conflictRelativePath = "\(basePath)_conflict_\(timestamp).pdf"
            let conflictURL = library.containerURL.appendingPathComponent(conflictRelativePath)

            // If we have remote data, write it to the conflict path
            if let linkedFile = linkedFile,
               let remoteData = linkedFile.fileData {
                do {
                    // Ensure parent directory exists
                    let parentDir = conflictURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                    // Write the remote data to the conflict path
                    try remoteData.write(to: conflictURL)
                    Logger.sync.info("PDF conflict resolved with keepBoth: created \(conflictURL.lastPathComponent)")

                    // Create a new CDLinkedFile for the conflict copy
                    let conflictFile = CDLinkedFile(context: context)
                    conflictFile.id = UUID()
                    conflictFile.relativePath = conflictRelativePath
                    conflictFile.filename = conflictURL.lastPathComponent
                    conflictFile.fileType = "pdf"
                    conflictFile.dateAdded = conflict.remoteModifiedDate
                    conflictFile.publication = publication
                    conflictFile.fileSize = Int64(remoteData.count)

                    // Clear the original file's remote data since we've saved it
                    linkedFile.fileData = nil
                } catch {
                    Logger.sync.error("Failed to create conflict copy: \(error.localizedDescription)")
                    throw SyncError.fileNotFound(conflictRelativePath)
                }
            } else {
                // No remote data available - just log the intended path
                Logger.sync.warning("PDF conflict keepBoth: no remote data to copy, path would be \(conflictRelativePath)")
            }
        }

        try context.save()
        dequeue(.pdf(conflict))

        // Post notification for conflict resolved
        NotificationCenter.default.post(name: .syncConflictResolved, object: conflict)
    }
}

// MARK: - Sync Error

public enum SyncError: LocalizedError {
    case publicationNotFound(UUID)
    case fileNotFound(String)
    case mergeFailure(String)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .publicationNotFound(let id):
            return "Publication not found: \(id)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .mergeFailure(let reason):
            return "Merge failed: \(reason)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when a sync conflict is detected
    static let syncConflictDetected = Notification.Name("syncConflictDetected")

    /// Posted when a sync conflict is resolved
    static let syncConflictResolved = Notification.Name("syncConflictResolved")

    // NOTE: syncDidComplete is defined in SyncHealthMonitor.swift
}

// MARK: - Import CoreData

import CoreData
