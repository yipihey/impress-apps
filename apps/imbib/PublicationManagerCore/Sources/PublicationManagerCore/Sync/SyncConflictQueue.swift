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

        switch resolution {
        case .keepLocal:
            // Nothing to do - local file is already in place
            break

        case .keepRemote:
            // Replace local with remote
            // This would require downloading the remote file
            // For now, we'll handle this at the file sync level
            break

        case .keepBoth:
            // Create a conflict copy with timestamp in filename
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
            let timestamp = dateFormatter.string(from: conflict.remoteModifiedDate)
                .replacingOccurrences(of: ":", with: "-")

            let basePath = conflict.localFilePath.dropLast(4) // Remove .pdf
            let conflictPath = "\(basePath)_conflict_\(timestamp).pdf"

            // The actual file copy would be handled by the file sync system
            Logger.sync.info("PDF conflict resolved with keepBoth: \(conflictPath)")
        }

        dequeue(.pdf(conflict))
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

    /// Posted when sync completes (with or without conflicts)
    static let syncDidComplete = Notification.Name("syncDidComplete")
}

// MARK: - Import CoreData

import CoreData
