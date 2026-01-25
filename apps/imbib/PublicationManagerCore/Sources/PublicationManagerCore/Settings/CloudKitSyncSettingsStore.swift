//
//  CloudKitSyncSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation
import OSLog

/// Stores CloudKit sync preferences locally.
///
/// We use local UserDefaults (not iCloud sync) for these settings because:
/// 1. Can't use CloudKit to store CloudKit settings (circular dependency)
/// 2. User may want different sync settings per device
/// 3. Must be available immediately at app launch before sync is configured
///
/// ## Thread Safety
/// This class is thread-safe and can be called from any actor context.
public final class CloudKitSyncSettingsStore: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = CloudKitSyncSettingsStore()

    // MARK: - Keys

    private enum Keys {
        static let isDisabledByUser = "cloudKit.sync.disabledByUser"
        static let lastError = "cloudKit.sync.lastError"
        static let lastSyncDate = "cloudKit.sync.lastSyncDate"
        static let pendingReset = "cloudKit.sync.pendingReset"
    }

    // MARK: - Properties

    private let defaults: UserDefaults

    // MARK: - Initialization

    private init() {
        self.defaults = UserDefaults.forCurrentEnvironment
        Logger.settings.info("CloudKitSyncSettingsStore initialized")
    }

    // MARK: - User Preference

    /// Whether the user has explicitly disabled CloudKit sync.
    /// Default: false (sync enabled if available)
    public var isDisabledByUser: Bool {
        get { defaults.bool(forKey: Keys.isDisabledByUser) }
        set {
            defaults.set(newValue, forKey: Keys.isDisabledByUser)
            Logger.settings.info("CloudKit sync disabled by user: \(newValue)")
        }
    }

    // MARK: - Error Tracking

    /// Last error message encountered during sync, for UI display.
    /// Nil if sync is working normally.
    public var lastError: String? {
        get { defaults.string(forKey: Keys.lastError) }
        set {
            if let error = newValue {
                defaults.set(error, forKey: Keys.lastError)
                Logger.settings.warning("CloudKit sync error recorded: \(error)")
            } else {
                defaults.removeObject(forKey: Keys.lastError)
            }
        }
    }

    /// Clears the last error (call when sync succeeds).
    public func clearError() {
        lastError = nil
    }

    // MARK: - Sync Status

    /// Last successful sync date, for UI display.
    public var lastSyncDate: Date? {
        get { defaults.object(forKey: Keys.lastSyncDate) as? Date }
        set {
            if let date = newValue {
                defaults.set(date, forKey: Keys.lastSyncDate)
            } else {
                defaults.removeObject(forKey: Keys.lastSyncDate)
            }
        }
    }

    /// Records a successful sync.
    public func recordSuccessfulSync() {
        lastSyncDate = Date()
        clearError()
    }

    // MARK: - Computed Properties

    /// Whether CloudKit sync should be attempted based on user preference.
    /// Does not check if iCloud is actually available.
    public var shouldAttemptSync: Bool {
        !isDisabledByUser
    }

    // MARK: - Pending Reset (Two-Phase Reset)

    /// Whether a reset to first-run is pending.
    ///
    /// When true, the app should delete local Core Data store files on next launch
    /// before loading any data. This ensures CloudKit doesn't sync stale data back.
    ///
    /// The two-phase reset works as follows:
    /// 1. Set pendingReset = true
    /// 2. Purge CloudKit zone
    /// 3. App quits
    /// 4. On next launch, check pendingReset and delete local store files
    /// 5. Clear pendingReset flag
    /// 6. App loads with fresh empty store
    public var pendingReset: Bool {
        get { defaults.bool(forKey: Keys.pendingReset) }
        set {
            defaults.set(newValue, forKey: Keys.pendingReset)
            Logger.settings.info("CloudKit pending reset: \(newValue)")
        }
    }

    // MARK: - Reset

    /// Resets all CloudKit sync settings to defaults.
    public func reset() {
        defaults.removeObject(forKey: Keys.isDisabledByUser)
        defaults.removeObject(forKey: Keys.lastError)
        defaults.removeObject(forKey: Keys.lastSyncDate)
        defaults.removeObject(forKey: Keys.pendingReset)
        Logger.settings.info("CloudKit sync settings reset")
    }
}
