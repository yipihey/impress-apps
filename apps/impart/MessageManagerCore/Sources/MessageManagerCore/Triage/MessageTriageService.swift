//
//  MessageTriageService.swift
//  MessageManagerCore
//
//  Triage operations for messages: dismiss, save, star.
//  Follows imbib's InboxTriageService pattern with selection advancement.
//

import CoreData
import Foundation
import OSLog

private let triageLogger = Logger(subsystem: "com.impart", category: "triage")

// MARK: - Triage Errors

public enum TriageError: LocalizedError {
    case folderNotFound
    case messageNotFound

    public var errorDescription: String? {
        switch self {
        case .folderNotFound: return "Folder not found"
        case .messageNotFound: return "Message not found"
        }
    }
}

// MARK: - Triage Result

/// Result of a triage operation.
public struct MessageTriageResult: Sendable {
    /// Number of messages affected.
    public let affectedCount: Int

    /// The next message to select (if available).
    public let nextSelection: UUID?

    /// Whether the operation succeeded.
    public let success: Bool

    /// Error message if failed.
    public let errorMessage: String?

    public init(affectedCount: Int, nextSelection: UUID?, success: Bool = true, errorMessage: String? = nil) {
        self.affectedCount = affectedCount
        self.nextSelection = nextSelection
        self.success = success
        self.errorMessage = errorMessage
    }

    public static func failure(_ message: String) -> MessageTriageResult {
        MessageTriageResult(affectedCount: 0, nextSelection: nil, success: false, errorMessage: message)
    }
}

// MARK: - Selection Advancement

/// Compute next selection after removing items from a list.
public struct SelectionAdvancement {

    /// Compute the next ID to select after removing selected IDs from a list.
    /// Prefers advancing forward, falls back to previous item.
    public static func nextSelection(
        removing selectedIds: Set<UUID>,
        from orderedIds: [UUID],
        currentSelection: UUID?
    ) -> UUID? {
        guard !orderedIds.isEmpty else { return nil }

        // Find remaining IDs after removal
        let remainingIds = orderedIds.filter { !selectedIds.contains($0) }
        guard !remainingIds.isEmpty else { return nil }

        // If we have a current selection, try to find a nearby remaining item
        if let current = currentSelection,
           let currentIndex = orderedIds.firstIndex(of: current) {

            // Look forward from current position
            for i in (currentIndex + 1)..<orderedIds.count {
                let id = orderedIds[i]
                if !selectedIds.contains(id) {
                    return id
                }
            }

            // Look backward from current position
            for i in (0..<currentIndex).reversed() {
                let id = orderedIds[i]
                if !selectedIds.contains(id) {
                    return id
                }
            }
        }

        // Fallback: return first remaining
        return remainingIds.first
    }
}

// MARK: - Message Triage Service

/// Actor-based service for message triage operations.
public actor MessageTriageService {

    private let persistenceController: PersistenceController

    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    /// Convenience initializer using shared persistence controller.
    @MainActor
    public init() {
        self.persistenceController = .shared
    }

    // MARK: - Dismiss

    /// Dismiss (archive) messages.
    /// - Parameters:
    ///   - ids: Message IDs to dismiss.
    ///   - orderedIds: All message IDs in current view order.
    ///   - currentSelection: Currently selected message ID.
    /// - Returns: Triage result with next selection.
    public func dismiss(
        ids: Set<UUID>,
        from orderedIds: [UUID],
        currentSelection: UUID?
    ) async -> MessageTriageResult {
        guard !ids.isEmpty else {
            return MessageTriageResult(affectedCount: 0, nextSelection: currentSelection)
        }

        let nextSelection = SelectionAdvancement.nextSelection(
            removing: ids,
            from: orderedIds,
            currentSelection: currentSelection
        )

        do {
            let count = try await persistenceController.performBackgroundTask { context in
                let fetchRequest: NSFetchRequest<CDMessage> = NSFetchRequest(entityName: "CDMessage")
                fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

                let messages = try context.fetch(fetchRequest)
                for message in messages {
                    message.isDismissed = true
                    message.isRead = true  // Dismissing marks as read
                }

                try context.save()
                return messages.count
            }

            triageLogger.info("Dismissed \(count) messages")
            return MessageTriageResult(affectedCount: count, nextSelection: nextSelection)
        } catch {
            triageLogger.error("Failed to dismiss messages: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Save

    /// Save (keep) messages.
    /// - Parameters:
    ///   - ids: Message IDs to save.
    ///   - orderedIds: All message IDs in current view order.
    ///   - currentSelection: Currently selected message ID.
    /// - Returns: Triage result with next selection.
    public func save(
        ids: Set<UUID>,
        from orderedIds: [UUID],
        currentSelection: UUID?
    ) async -> MessageTriageResult {
        guard !ids.isEmpty else {
            return MessageTriageResult(affectedCount: 0, nextSelection: currentSelection)
        }

        let nextSelection = SelectionAdvancement.nextSelection(
            removing: ids,
            from: orderedIds,
            currentSelection: currentSelection
        )

        do {
            let count = try await persistenceController.performBackgroundTask { context in
                let fetchRequest: NSFetchRequest<CDMessage> = NSFetchRequest(entityName: "CDMessage")
                fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

                let messages = try context.fetch(fetchRequest)
                for message in messages {
                    message.isSaved = true
                    message.isRead = true  // Saving marks as read
                }

                try context.save()
                return messages.count
            }

            triageLogger.info("Saved \(count) messages")
            return MessageTriageResult(affectedCount: count, nextSelection: nextSelection)
        } catch {
            triageLogger.error("Failed to save messages: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Toggle Star

    /// Toggle star status on messages.
    /// - Parameters:
    ///   - ids: Message IDs to toggle.
    ///   - orderedIds: All message IDs in current view order.
    public func toggleStar(
        ids: Set<UUID>,
        from orderedIds: [UUID]
    ) async -> MessageTriageResult {
        guard !ids.isEmpty else {
            return MessageTriageResult(affectedCount: 0, nextSelection: nil)
        }

        do {
            let count = try await persistenceController.performBackgroundTask { context in
                let fetchRequest: NSFetchRequest<CDMessage> = NSFetchRequest(entityName: "CDMessage")
                fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

                let messages = try context.fetch(fetchRequest)

                // If any are unstarred, star all. Otherwise unstar all.
                let anyUnstarred = messages.contains { !$0.isStarred }
                for message in messages {
                    message.isStarred = anyUnstarred
                }

                try context.save()
                return messages.count
            }

            triageLogger.info("Toggled star on \(count) messages")
            return MessageTriageResult(affectedCount: count, nextSelection: nil)
        } catch {
            triageLogger.error("Failed to toggle star: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Mark Read

    /// Mark messages as read.
    public func markRead(ids: Set<UUID>) async -> MessageTriageResult {
        guard !ids.isEmpty else {
            return MessageTriageResult(affectedCount: 0, nextSelection: nil)
        }

        do {
            let count = try await persistenceController.performBackgroundTask { context in
                let fetchRequest: NSFetchRequest<CDMessage> = NSFetchRequest(entityName: "CDMessage")
                fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

                let messages = try context.fetch(fetchRequest)
                for message in messages {
                    message.isRead = true
                }

                try context.save()
                return messages.count
            }

            triageLogger.info("Marked \(count) messages as read")
            return MessageTriageResult(affectedCount: count, nextSelection: nil)
        } catch {
            triageLogger.error("Failed to mark read: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Mark Unread

    /// Mark messages as unread.
    public func markUnread(ids: Set<UUID>) async -> MessageTriageResult {
        guard !ids.isEmpty else {
            return MessageTriageResult(affectedCount: 0, nextSelection: nil)
        }

        do {
            let count = try await persistenceController.performBackgroundTask { context in
                let fetchRequest: NSFetchRequest<CDMessage> = NSFetchRequest(entityName: "CDMessage")
                fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

                let messages = try context.fetch(fetchRequest)
                for message in messages {
                    message.isRead = false
                }

                try context.save()
                return messages.count
            }

            triageLogger.info("Marked \(count) messages as unread")
            return MessageTriageResult(affectedCount: count, nextSelection: nil)
        } catch {
            triageLogger.error("Failed to mark unread: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Move to Folder

    /// Move messages to a folder.
    public func moveToFolder(
        ids: Set<UUID>,
        folderId: UUID,
        from orderedIds: [UUID],
        currentSelection: UUID?
    ) async -> MessageTriageResult {
        guard !ids.isEmpty else {
            return MessageTriageResult(affectedCount: 0, nextSelection: currentSelection)
        }

        let nextSelection = SelectionAdvancement.nextSelection(
            removing: ids,
            from: orderedIds,
            currentSelection: currentSelection
        )

        do {
            let count = try await persistenceController.performBackgroundTask { context in
                // Fetch the target folder
                let folderFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
                folderFetch.predicate = NSPredicate(format: "id == %@", folderId as CVarArg)
                guard let folder = try context.fetch(folderFetch).first else {
                    throw TriageError.folderNotFound
                }

                // Fetch and move messages
                let fetchRequest: NSFetchRequest<CDMessage> = NSFetchRequest(entityName: "CDMessage")
                fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

                let messages = try context.fetch(fetchRequest)
                for message in messages {
                    message.folder = folder
                }

                try context.save()
                return messages.count
            }

            triageLogger.info("Moved \(count) messages to folder")
            return MessageTriageResult(affectedCount: count, nextSelection: nextSelection)
        } catch {
            triageLogger.error("Failed to move messages: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Delete

    /// Delete messages (move to trash).
    public func delete(
        ids: Set<UUID>,
        from orderedIds: [UUID],
        currentSelection: UUID?
    ) async -> MessageTriageResult {
        guard !ids.isEmpty else {
            return MessageTriageResult(affectedCount: 0, nextSelection: currentSelection)
        }

        let nextSelection = SelectionAdvancement.nextSelection(
            removing: ids,
            from: orderedIds,
            currentSelection: currentSelection
        )

        do {
            let count = try await persistenceController.performBackgroundTask { context in
                // Find trash folder for the account
                let fetchRequest: NSFetchRequest<CDMessage> = NSFetchRequest(entityName: "CDMessage")
                fetchRequest.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)

                let messages = try context.fetch(fetchRequest)

                for message in messages {
                    // Find trash folder in same account
                    if let account = message.folder?.account {
                        let trashFetch: NSFetchRequest<CDFolder> = NSFetchRequest(entityName: "CDFolder")
                        trashFetch.predicate = NSPredicate(
                            format: "account == %@ AND roleRaw == %@",
                            account,
                            FolderRole.trash.rawValue
                        )
                        if let trash = try context.fetch(trashFetch).first {
                            message.folder = trash
                        }
                    }
                }

                try context.save()
                return messages.count
            }

            triageLogger.info("Deleted \(count) messages")
            return MessageTriageResult(affectedCount: count, nextSelection: nextSelection)
        } catch {
            triageLogger.error("Failed to delete messages: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }
}
