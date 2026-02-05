//
//  ExplorationSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-03.
//

import Foundation
import OSLog

/// Stores Exploration library preferences.
///
/// Uses local UserDefaults because:
/// 1. User may want different exploration settings per device
/// 2. The setting controls sync behavior itself, so it must be local
///
/// ## Thread Safety
/// This class is thread-safe and can be called from any actor context.
public final class ExplorationSettingsStore: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = ExplorationSettingsStore()

    // MARK: - Keys

    private enum Keys {
        static let isLocalOnly = "exploration.isLocalOnly"
    }

    // MARK: - Properties

    private let defaults: UserDefaults

    // MARK: - Initialization

    private init() {
        self.defaults = UserDefaults.forCurrentEnvironment
        Logger.settings.info("ExplorationSettingsStore initialized")
    }

    // MARK: - Settings

    /// Whether the Exploration library should be local-only (not synced via CloudKit).
    ///
    /// When true:
    /// - Exploration collections and papers stay on this device only
    /// - Each device has independent exploration history
    /// - No CloudKit sync for exploration data
    ///
    /// When false:
    /// - Exploration syncs across devices via CloudKit
    /// - All devices share the same exploration history
    ///
    /// Default: true (local-only)
    public var isLocalOnly: Bool {
        get {
            // Default to true (local-only) if not set
            if defaults.object(forKey: Keys.isLocalOnly) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.isLocalOnly)
        }
        set {
            defaults.set(newValue, forKey: Keys.isLocalOnly)
            Logger.settings.info("Exploration local-only: \(newValue)")

            // Post notification so LibraryManager can update
            NotificationCenter.default.post(
                name: .explorationSyncSettingChanged,
                object: nil,
                userInfo: ["isLocalOnly": newValue]
            )
        }
    }

    // MARK: - Reset

    /// Resets all exploration settings to defaults.
    public func reset() {
        defaults.removeObject(forKey: Keys.isLocalOnly)
        Logger.settings.info("Exploration settings reset")
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when exploration sync setting changes.
    static let explorationSyncSettingChanged = Notification.Name("explorationSyncSettingChanged")
}
