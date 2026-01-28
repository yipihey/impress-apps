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
        static let featureFlags = "cloudKit.sync.featureFlags"
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
        defaults.removeObject(forKey: Keys.featureFlags)
        Logger.settings.info("CloudKit sync settings reset")
    }

    // MARK: - Feature Flags

    /// Feature flags for gating risky sync changes.
    public var featureFlags: SyncFeatureFlags {
        get {
            guard let data = defaults.data(forKey: Keys.featureFlags),
                  let flags = try? JSONDecoder().decode(SyncFeatureFlags.self, from: data) else {
                return SyncFeatureFlags()
            }
            return flags
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.featureFlags)
            }
        }
    }

    // MARK: - Emergency Rollback

    /// Perform emergency rollback of sync features.
    ///
    /// This disables new features and stops sync to prevent data issues.
    /// Use when detecting widespread sync problems.
    public func emergencyRollback() {
        // Reset feature flags to legacy
        featureFlags = .legacy

        // Disable sync
        isDisabledByUser = true

        // Clear any pending operations
        lastError = "Sync paused for safety. Please update the app."

        Logger.settings.warning("Emergency rollback performed - sync disabled, features reverted")

        // Notify the app
        NotificationCenter.default.post(name: .syncRolledBack, object: nil)
    }
}

// MARK: - Feature Flags

/// Feature flags for controlling sync behavior.
public struct SyncFeatureFlags: Codable, Sendable {
    /// Whether to use the new field-level conflict resolution.
    public var enableNewConflictResolution: Bool

    /// Whether to sync large PDF files (>10MB).
    public var enableLargePDFSync: Bool

    /// Sync schema version to use.
    public var syncSchemaVersion: Int

    public init(
        enableNewConflictResolution: Bool = true,
        enableLargePDFSync: Bool = true,
        syncSchemaVersion: Int = SchemaVersion.current.rawValue
    ) {
        self.enableNewConflictResolution = enableNewConflictResolution
        self.enableLargePDFSync = enableLargePDFSync
        self.syncSchemaVersion = syncSchemaVersion
    }

    /// Legacy feature flags (all new features disabled).
    public static let legacy = SyncFeatureFlags(
        enableNewConflictResolution: false,
        enableLargePDFSync: false,
        syncSchemaVersion: 100
    )
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when emergency rollback is performed.
    static let syncRolledBack = Notification.Name("syncRolledBack")
}
