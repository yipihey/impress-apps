//
//  PersistenceController.swift
//  MessageManagerCore
//
//  Core Data persistence for email messages, accounts, and mailboxes.
//

import CoreData
import Foundation
import OSLog

private let persistenceLogger = Logger(subsystem: "com.imbib.impart", category: "persistence")

// MARK: - Persistence Controller

/// Manages Core Data stack for impart.
///
/// Provides:
/// - Local persistent store for offline access
/// - CloudKit sync for cross-device continuity
/// - Background contexts for import operations
@MainActor
public final class PersistenceController: Sendable {

    // MARK: - Singleton

    /// Shared persistence controller.
    public static let shared = PersistenceController()

    // MARK: - Preview Support

    /// In-memory controller for SwiftUI previews.
    @MainActor
    public static var preview: PersistenceController {
        let controller = PersistenceController(inMemory: true)
        // Add sample data for previews
        controller.createSampleData()
        return controller
    }

    // MARK: - Properties

    /// The Core Data container.
    public let container: NSPersistentCloudKitContainer

    /// Main view context (main queue).
    public var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    // MARK: - Initialization

    /// Initialize the persistence controller.
    /// - Parameter inMemory: Use in-memory store for testing/previews.
    public init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Impart")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        // Configure for CloudKit sync
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("Failed to retrieve persistent store description")
        }

        // Enable persistent history tracking for CloudKit
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        // CloudKit container
        if !inMemory {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.imbib.shared"
            )
        }

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                persistenceLogger.error("Failed to load persistent store: \(error), \(error.userInfo)")
                // In production, handle this gracefully
                fatalError("Failed to load persistent store: \(error)")
            }
            persistenceLogger.info("Loaded persistent store: \(storeDescription.url?.absoluteString ?? "unknown")")
        }

        // Configure view context
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // Pin to current query generation for consistent reads
        try? container.viewContext.setQueryGenerationFrom(.current)
    }

    // MARK: - Background Context

    /// Create a new background context for import operations.
    public func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    /// Perform work on a background context.
    public func performBackgroundTask<T: Sendable>(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        try await container.performBackgroundTask { context in
            try block(context)
        }
    }

    // MARK: - Save

    /// Save the view context if there are changes.
    public func save() {
        let context = viewContext
        guard context.hasChanges else { return }

        do {
            try context.save()
        } catch {
            persistenceLogger.error("Failed to save view context: \(error.localizedDescription)")
        }
    }

    /// Save a context if there are changes.
    public func save(context: NSManagedObjectContext) {
        guard context.hasChanges else { return }

        do {
            try context.save()
        } catch {
            persistenceLogger.error("Failed to save context: \(error.localizedDescription)")
        }
    }

    // MARK: - Sample Data

    /// Create sample data for previews.
    private func createSampleData() {
        // TODO: Add sample accounts, mailboxes, messages for previews
        save()
    }
}

// MARK: - Core Data Model Notes
//
// The Core Data model (Impart.xcdatamodeld) should contain:
//
// CDAccount
// - id: UUID
// - email: String
// - displayName: String
// - imapHost: String
// - imapPort: Int16
// - smtpHost: String
// - smtpPort: Int16
// - isEnabled: Bool
// - lastSyncDate: Date?
// - signature: String?
// - keychainItemId: String (reference to Keychain credentials)
// - mailboxes: [CDMailbox] (to-many)
//
// CDMailbox
// - id: UUID
// - name: String
// - fullPath: String
// - role: String (enum raw value)
// - delimiter: String
// - messageCount: Int32
// - unreadCount: Int32
// - isSubscribed: Bool
// - account: CDAccount (to-one)
// - messages: [CDMessage] (to-many)
//
// CDMessage
// - id: UUID
// - uid: Int32
// - messageId: String?
// - inReplyTo: String?
// - references: String? (JSON array)
// - subject: String
// - snippet: String
// - fromJSON: String (JSON array of addresses)
// - toJSON: String
// - ccJSON: String?
// - date: Date
// - receivedDate: Date
// - isRead: Bool
// - isStarred: Bool
// - hasAttachments: Bool
// - labelsJSON: String? (JSON array)
// - mailbox: CDMailbox (to-one)
// - thread: CDThread? (to-one)
// - content: CDMessageContent? (to-one, optional for lazy loading)
//
// CDMessageContent
// - id: UUID
// - textBody: String?
// - htmlBody: String?
// - message: CDMessage (to-one)
// - attachments: [CDAttachment] (to-many)
//
// CDAttachment
// - id: UUID
// - filename: String
// - mimeType: String
// - size: Int64
// - contentId: String?
// - isInline: Bool
// - data: Data? (optional, may be fetched on demand)
// - content: CDMessageContent (to-one)
//
// CDThread
// - id: UUID
// - subject: String
// - latestDate: Date
// - messages: [CDMessage] (to-many)
