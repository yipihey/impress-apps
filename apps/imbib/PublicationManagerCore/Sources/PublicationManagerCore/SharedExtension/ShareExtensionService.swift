//
//  ShareExtensionService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation
import OSLog

/// Service for communication between the share extension and main app via App Groups.
///
/// Uses `UserDefaults(suiteName:)` to share data between the extension and main app.
/// The main app should call `processPendingSharedURLs()` on launch and when receiving
/// the `sharedURLReceived` notification.
public final class ShareExtensionService: Sendable {

    // MARK: - Singleton

    /// Shared instance
    public static let shared = ShareExtensionService()

    // MARK: - Constants

    /// App Group identifier for sharing data between app and extension
    public static let appGroupIdentifier = "group.com.imbib.app"

    /// UserDefaults key for pending shared items
    private static let pendingItemsKey = "pendingSharedItems"

    /// Notification posted when a URL is shared (for Darwin notification center)
    public static let sharedURLReceivedNotification = Notification.Name("com.imbib.sharedURLReceived")

    // MARK: - Types

    /// A shared item queued for processing by the main app
    public struct SharedItem: Codable, Sendable, Identifiable, Equatable {
        public let id: UUID
        public let url: URL
        public let type: ItemType
        public let name: String?
        public let query: String?  // The actual query to use (from page title via JS preprocessing)
        public let libraryID: UUID?
        public let createdAt: Date

        public enum ItemType: String, Codable, Sendable {
            case smartSearch
            case paper
            case docsSelection  // Temporary paper selection to import to Inbox
        }

        public init(
            id: UUID = UUID(),
            url: URL,
            type: ItemType,
            name: String?,
            query: String? = nil,
            libraryID: UUID?,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.url = url
            self.type = type
            self.name = name
            self.query = query
            self.libraryID = libraryID
            self.createdAt = createdAt
        }
    }

    // MARK: - Properties

    /// UserDefaults instance for the app group
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupIdentifier)
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Share Extension API

    /// Queue a smart search URL for creation when the main app opens.
    ///
    /// Called from the share extension after user confirms the smart search details.
    ///
    /// - Parameters:
    ///   - url: The ADS search URL
    ///   - name: The name for the smart search
    ///   - libraryID: The target library UUID (nil for default library)
    public func queueSmartSearch(url: URL, name: String, libraryID: UUID?) {
        let item = SharedItem(
            url: url,
            type: .smartSearch,
            name: name,
            libraryID: libraryID,
            createdAt: Date()
        )
        appendItem(item)
        postNotification()
    }

    /// Queue a paper URL for import when the main app opens.
    ///
    /// Called from the share extension after user confirms the import.
    ///
    /// - Parameters:
    ///   - url: The ADS paper URL
    ///   - libraryID: The target library UUID (nil for Inbox)
    public func queuePaperImport(url: URL, libraryID: UUID?) {
        let item = SharedItem(
            url: url,
            type: .paper,
            name: nil,
            libraryID: libraryID,
            createdAt: Date()
        )
        appendItem(item)
        postNotification()
    }

    /// Queue a docs() selection for bulk import to Inbox when the main app opens.
    ///
    /// Called from the share extension after user confirms the docs() import.
    ///
    /// - Parameters:
    ///   - url: The ADS docs() URL
    ///   - query: The docs() query string
    public func queueDocsSelection(url: URL, query: String) {
        Logger.shareExtension.infoCapture("Queueing docs() selection: \(query)", category: "shareext")
        let item = SharedItem(
            url: url,
            type: .docsSelection,
            name: nil,
            query: query,
            libraryID: nil,  // Always to Inbox
            createdAt: Date()
        )
        appendItem(item)
        postNotification()
        Logger.shareExtension.infoCapture("docs() selection queued successfully", category: "shareext")
    }

    // MARK: - Main App API

    /// Get all pending shared items.
    ///
    /// Called by the main app to retrieve queued items for processing.
    public func getPendingItems() -> [SharedItem] {
        guard let defaults = sharedDefaults else {
            Logger.shareExtension.warningCapture("Cannot access App Group UserDefaults", category: "shareext")
            return []
        }

        guard let data = defaults.data(forKey: Self.pendingItemsKey) else {
            Logger.shareExtension.debugCapture("No pending items in UserDefaults", category: "shareext")
            return []
        }

        do {
            let items = try JSONDecoder().decode([SharedItem].self, from: data)
            Logger.shareExtension.infoCapture("Retrieved \(items.count) pending items from queue", category: "shareext")
            for item in items {
                Logger.shareExtension.debugCapture("  - \(item.type.rawValue): \(item.query ?? item.url.absoluteString)", category: "shareext")
            }
            return items
        } catch {
            Logger.shareExtension.errorCapture("Failed to decode pending items: \(error.localizedDescription)", category: "shareext")
            return []
        }
    }

    /// Remove a processed item from the queue.
    ///
    /// Called after the main app successfully processes an item.
    ///
    /// - Parameter item: The item to remove
    public func removeItem(_ item: SharedItem) {
        Logger.shareExtension.debugCapture("Removing processed item: \(item.type.rawValue)", category: "shareext")
        var items = getPendingItems()
        items.removeAll { $0.id == item.id }
        saveItems(items)
    }

    /// Clear all pending items.
    ///
    /// Called after the main app processes all items or to reset state.
    public func clearPendingItems() {
        sharedDefaults?.removeObject(forKey: Self.pendingItemsKey)
    }

    /// Check if there are pending items to process.
    public var hasPendingItems: Bool {
        !getPendingItems().isEmpty
    }

    // MARK: - Private Helpers

    private func appendItem(_ item: SharedItem) {
        var items = getPendingItems()
        items.append(item)
        saveItems(items)
    }

    private func saveItems(_ items: [SharedItem]) {
        guard let defaults = sharedDefaults else {
            Logger.shareExtension.warningCapture("Cannot access App Group UserDefaults for saving", category: "shareext")
            return
        }

        do {
            let data = try JSONEncoder().encode(items)
            defaults.set(data, forKey: Self.pendingItemsKey)
            Logger.shareExtension.debugCapture("Saved \(items.count) items to queue", category: "shareext")
        } catch {
            Logger.shareExtension.errorCapture("Failed to encode shared items: \(error.localizedDescription)", category: "shareext")
        }
    }

    private func postNotification() {
        // Post notification via Darwin notification center
        // This works across processes (extension → main app)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName("com.imbib.sharedURLReceived" as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)

        // Also post local notification for same-process testing
        NotificationCenter.default.post(name: Self.sharedURLReceivedNotification, object: nil)
    }
}

// MARK: - Library Info for Extension UI

/// Minimal library info that can be passed to the share extension.
///
/// This is used to populate the library picker in the extension UI without
/// needing full Core Data access.
public struct SharedLibraryInfo: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let isDefault: Bool

    public init(id: UUID, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

extension ShareExtensionService {

    /// Key for storing available libraries
    private static let librariesKey = "availableLibraries"

    /// Update the list of available libraries for the share extension.
    ///
    /// Called by the main app when libraries change.
    ///
    /// - Parameter libraries: The current list of libraries
    public func updateAvailableLibraries(_ libraries: [SharedLibraryInfo]) {
        guard let defaults = sharedDefaults else {
            Logger.shareExtension.warningCapture("Cannot access App Group UserDefaults for libraries", category: "shareext")
            return
        }

        do {
            let data = try JSONEncoder().encode(libraries)
            defaults.set(data, forKey: Self.librariesKey)
            Logger.shareExtension.debugCapture("Updated available libraries: \(libraries.count)", category: "shareext")
        } catch {
            Logger.shareExtension.errorCapture("Failed to encode libraries: \(error.localizedDescription)", category: "shareext")
        }
    }

    /// Get the list of available libraries for the extension UI.
    public func getAvailableLibraries() -> [SharedLibraryInfo] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: Self.librariesKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([SharedLibraryInfo].self, from: data)
        } catch {
            Logger.shareExtension.errorCapture("Failed to decode libraries: \(error.localizedDescription)", category: "shareext")
            return []
        }
    }
}
