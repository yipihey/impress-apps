//
//  FirstRunManager.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-17.
//

import Foundation
import OSLog

// MARK: - Reset Result

/// Result of a reset to first-run operation.
public struct ResetResult: Sendable {
    /// Error encountered during the reset (nil on success). CloudKit purge
    /// fields were removed with the dead CloudKit sharing stack (ADR-023 —
    /// imbib has no CloudKit sync; the store is local Rust SQLite).
    public let error: Error?

    /// Whether local data was successfully deleted
    public let localDataDeleted: Bool

    /// Whether the reset was fully successful.
    public var wasFullySuccessful: Bool {
        localDataDeleted && error == nil
    }

    public init(error: Error? = nil, localDataDeleted: Bool) {
        self.error = error
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

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - Initialization

    public init() {}

    // MARK: - First Run Detection

    /// Check if this is a first run (no libraries exist).
    ///
    /// Returns `true` if the database has no libraries, indicating either:
    /// - Fresh install
    /// - After a reset to first-run state
    public var isFirstRun: Bool {
        let libraries = store.listLibraries()
        return libraries.isEmpty
    }

    // MARK: - Reset to First Run

    /// Reset the app to first-run state.
    ///
    /// This method:
    /// 1. Clears UserDefaults (AppStateStore, ListViewStateStore, ReadingPositionStore, etc.)
    /// 2. Deletes Papers folder contents
    /// 3. Invalidates singleton caches (InboxManager, etc.)
    /// 4. Preserves Keychain API keys (intentionally kept for re-testing with same credentials)
    ///
    /// The CloudKit steps this flow used to run (purge zone, disable sync,
    /// set a pendingReset flag) were removed with the dead CloudKit stack:
    /// nothing ever consumed the flag at launch, the sync engine no longer
    /// runs, and the purge touched an unentitled container (the crash fixed
    /// in 5edde41 lived in exactly that dead path).
    ///
    /// KNOWN LIMITATION (pre-existing): the Rust store's SQLite files are
    /// NOT deleted here (they can't be removed while the store connection is
    /// open), and the old "delete on next launch" flag never had a consumer
    /// — so library items survive a reset. Tracked as a follow-up.
    ///
    /// - Returns: A `ResetResult` describing what was reset and any errors
    @discardableResult
    public func resetToFirstRun() async throws -> ResetResult {
        Logger.library.warningCapture("Resetting app to first-run state", category: "firstrun")

        // 1. Clear UserDefaults stores
        await clearAllUserDefaultsStores()

        // 2. Delete Papers folder contents
        deletePapersFolderContents()

        // 3. Invalidate singleton caches
        invalidateSingletonCaches()

        Logger.library.infoCapture("Reset phase 1 complete - app must restart to finish", category: "firstrun")

        return ResetResult(localDataDeleted: true)
    }

    /// Invalidate cached state in singleton managers and notify others.
    ///
    /// This prevents stale references from causing issues
    /// when the app re-initializes after reset.
    private func invalidateSingletonCaches() {
        // Clear InboxManager singleton cache
        InboxManager.shared.invalidateCaches()

        // Post notification for non-singleton managers (LibraryManager, etc.)
        NotificationCenter.default.post(name: .appDidResetToFirstRun, object: nil)

        Logger.library.debugCapture("Invalidated singleton caches and posted reset notification", category: "firstrun")
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

    public var errorDescription: String? {
        switch self {
        case .resetFailed(let error):
            return "Failed to reset to first-run state: \(error.localizedDescription)"
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the app has been reset to first-run state.
    ///
    /// Observers should invalidate any cached references.
    static let appDidResetToFirstRun = Notification.Name("appDidResetToFirstRun")
}
