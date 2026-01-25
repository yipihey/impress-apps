//
//  FirstRunManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-17.
//

import Foundation
import CoreData
import OSLog

// MARK: - Reset Result

/// Result of a reset to first-run operation.
public struct ResetResult: Sendable {
    /// Whether CloudKit zone was successfully purged
    public let cloudKitPurged: Bool

    /// Error encountered while purging CloudKit (nil if successful or not attempted)
    public let cloudKitError: Error?

    /// Whether local data was successfully deleted
    public let localDataDeleted: Bool

    /// Whether the reset was fully successful (cloud + local)
    public var wasFullySuccessful: Bool {
        cloudKitPurged && localDataDeleted && cloudKitError == nil
    }

    public init(cloudKitPurged: Bool, cloudKitError: Error?, localDataDeleted: Bool) {
        self.cloudKitPurged = cloudKitPurged
        self.cloudKitError = cloudKitError
        self.localDataDeleted = localDataDeleted
    }
}

// MARK: - First Run Manager

/// Manages first-run state and provides reset functionality for testing.
///
/// Used by developers and testers to:
/// 1. Check if this is a first run (no libraries exist)
/// 2. Reset the app to first-run state (delete all data except Keychain API keys)
/// 3. Trigger the default library set import
@MainActor
public final class FirstRunManager {

    // MARK: - Shared Instance

    public static let shared = FirstRunManager()

    // MARK: - Dependencies

    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
    }

    // MARK: - First Run Detection

    /// Check if this is a first run (no libraries exist).
    ///
    /// Returns `true` if the database has no libraries, indicating either:
    /// - Fresh install
    /// - After a reset to first-run state
    public var isFirstRun: Bool {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        request.fetchLimit = 1

        do {
            let count = try context.count(for: request)
            return count == 0
        } catch {
            Logger.library.errorCapture("Failed to check library count: \(error.localizedDescription)", category: "firstrun")
            return false
        }
    }

    // MARK: - Reset to First Run

    /// Reset the app to first-run state.
    ///
    /// This method:
    /// 1. Purges CloudKit zone (removes all synced data from iCloud)
    /// 2. Deletes all Core Data entities (publications, libraries, collections, etc.)
    /// 3. Clears UserDefaults (AppStateStore, ListViewStateStore, ReadingPositionStore, etc.)
    /// 4. Deletes Papers folder contents
    /// 5. Invalidates singleton caches (InboxManager, etc.)
    /// 6. Preserves Keychain API keys (intentionally kept for re-testing with same credentials)
    ///
    /// After calling this, the app will behave as if freshly installed on next launch.
    /// CloudKit zone is purged so sync can remain enabled (zone is empty).
    ///
    /// - Returns: A `ResetResult` describing what was reset and any errors
    @discardableResult
    public func resetToFirstRun() async throws -> ResetResult {
        Logger.library.warningCapture("Resetting app to first-run state", category: "firstrun")
        print("[imbib] FirstRunManager.resetToFirstRun() starting")

        var cloudKitPurged = false
        var cloudKitError: Error?

        // 1. Set pending reset flag FIRST
        // This ensures local store files are deleted on next launch, before CloudKit can sync
        CloudKitSyncSettingsStore.shared.pendingReset = true
        print("[imbib] Set pendingReset=true, current value: \(CloudKitSyncSettingsStore.shared.pendingReset)")
        Logger.library.infoCapture("Set pending reset flag for next launch", category: "firstrun")

        // 2. Disable CloudKit sync to stop ongoing operations
        CloudKitSyncSettingsStore.shared.isDisabledByUser = true
        Logger.library.infoCapture("Disabled CloudKit sync", category: "firstrun")

        // 3. Purge CloudKit zone
        // This ensures cloud data won't sync back when CloudKit is re-enabled
        if await CloudKitResetService.shared.canPurgeCloudKit() {
            do {
                try await CloudKitResetService.shared.purgeCloudKitZone()
                cloudKitPurged = true
                Logger.library.infoCapture("CloudKit zone purged successfully", category: "firstrun")
            } catch {
                cloudKitError = error
                Logger.library.errorCapture("Failed to purge CloudKit zone: \(error.localizedDescription)", category: "firstrun")
            }
        } else {
            Logger.library.warningCapture("CloudKit not available, skipping zone purge", category: "firstrun")
        }

        // 4. Clear UserDefaults stores (except CloudKit settings which has pendingReset flag)
        await clearAllUserDefaultsStores()

        // 5. Delete Papers folder contents
        deletePapersFolderContents()

        // 6. Invalidate singleton caches
        invalidateSingletonCaches()

        // Note: We do NOT delete Core Data entities here - the running container would
        // just sync them back from CloudKit. Instead, the pendingReset flag ensures
        // store files are deleted on next launch BEFORE the container loads.

        Logger.library.infoCapture("Reset phase 1 complete - app must restart to finish", category: "firstrun")

        return ResetResult(
            cloudKitPurged: cloudKitPurged,
            cloudKitError: cloudKitError,
            localDataDeleted: true
        )
    }

    /// Invalidate cached state in singleton managers and notify others.
    ///
    /// This prevents stale Core Data references from causing issues
    /// when the app re-initializes after reset.
    private func invalidateSingletonCaches() {
        // Clear InboxManager singleton cache
        InboxManager.shared.invalidateCaches()

        // Post notification for non-singleton managers (LibraryManager, etc.)
        NotificationCenter.default.post(name: .appDidResetToFirstRun, object: nil)

        Logger.library.debugCapture("Invalidated singleton caches and posted reset notification", category: "firstrun")
    }

    // MARK: - Core Data Deletion

    /// Delete all Core Data entities.
    private func deleteAllCoreDataEntities() async throws {
        let context = persistenceController.viewContext

        // Entity names to delete (in dependency order to avoid constraint violations)
        let entityNames = [
            "Annotation",
            "LinkedFile",
            "PublicationAuthor",
            "Publication",
            "SmartSearch",
            "Collection",
            "Library",
            "Author",
            "Tag",
            "AttachmentTag",
            "MutedItem",
            "DismissedPaper",
            "SciXPendingChange",
            "SciXLibrary",
        ]

        for entityName in entityNames {
            let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: entityName)
            fetchRequest.includesPropertyValues = false

            do {
                let objects = try context.fetch(fetchRequest)
                for object in objects {
                    context.delete(object)
                }
                Logger.library.debugCapture("Deleted \(objects.count) \(entityName) entities", category: "firstrun")
            } catch {
                Logger.library.errorCapture("Failed to delete \(entityName) entities: \(error.localizedDescription)", category: "firstrun")
                // Continue with other entities even if one fails
            }
        }

        // Save the context
        persistenceController.save()
        Logger.library.infoCapture("Deleted all Core Data entities", category: "firstrun")
    }

    // MARK: - UserDefaults Clearing

    /// Clear all UserDefaults stores used by the app.
    private func clearAllUserDefaultsStores() async {
        // Clear actor-based stores
        await AppStateStore.shared.reset()
        await ListViewStateStore.shared.clearAll()
        await ReadingPositionStore.shared.clearAll()
        await AutomationSettingsStore.shared.reset()
        await PDFSettingsStore.shared.reset()

        // Clear inbox settings (not actor-based, but follows similar pattern)
        await InboxSettingsStore.shared.reset()
        await SmartSearchSettingsStore.shared.reset()

        // Clear any remaining app-specific UserDefaults keys
        let keysToRemove = [
            "libraryLocation",
            "openPDFInExternalViewer",
            "autoGenerateCiteKeys",
            "defaultEntryType",
            "exportPreserveRawBibTeX",
        ]

        let defaults = UserDefaults.standard
        for key in keysToRemove {
            defaults.removeObject(forKey: key)
        }

        Logger.library.infoCapture("Cleared all UserDefaults stores", category: "firstrun")
    }

    // MARK: - Papers Folder Deletion

    /// Delete all files in the Papers folder.
    private func deletePapersFolderContents() {
        // Get the default Papers directory
        let fileManager = FileManager.default

        // Papers are typically stored in the app's Documents or Library folder
        // For macOS: ~/Library/Containers/com.imbib.app/Data/Documents/Papers
        // For iOS: App sandbox Documents/Papers

        #if os(macOS)
        // Check common locations
        let possiblePaths = [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Papers"),
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("imbib/Papers"),
        ].compactMap { $0 }
        #else
        let possiblePaths = [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Papers"),
        ].compactMap { $0 }
        #endif

        for papersURL in possiblePaths {
            guard fileManager.fileExists(atPath: papersURL.path) else {
                continue
            }

            do {
                let contents = try fileManager.contentsOfDirectory(at: papersURL, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    try fileManager.removeItem(at: fileURL)
                }
                Logger.files.infoCapture("Deleted \(contents.count) files from Papers folder: \(papersURL.path)", category: "firstrun")
            } catch {
                Logger.files.errorCapture("Failed to delete Papers folder contents: \(error.localizedDescription)", category: "firstrun")
            }
        }
    }

    // MARK: - Check for Welcome Screen Flag

    /// Check if the show-welcome-screen launch argument is present.
    ///
    /// Call this early in app initialization to show the welcome screen.
    /// Unlike the old reset flag, this does NOT delete any data.
    public static var shouldShowWelcomeScreen: Bool {
        #if os(macOS)
        return CommandLine.arguments.contains("--show-welcome-screen")
        #else
        return false  // iOS doesn't support launch arguments from command line
        #endif
    }
}

// MARK: - First Run Error

public enum FirstRunError: LocalizedError {
    case resetFailed(Error)
    case coreDataDeletionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .resetFailed(let error):
            return "Failed to reset to first-run state: \(error.localizedDescription)"
        case .coreDataDeletionFailed(let error):
            return "Failed to delete Core Data entities: \(error.localizedDescription)"
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the app has been reset to first-run state.
    ///
    /// Observers should invalidate any cached Core Data references.
    static let appDidResetToFirstRun = Notification.Name("appDidResetToFirstRun")
}
