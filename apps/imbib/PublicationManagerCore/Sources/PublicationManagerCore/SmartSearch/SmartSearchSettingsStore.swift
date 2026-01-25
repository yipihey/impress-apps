//
//  SmartSearchSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-05.
//

import Foundation
import OSLog

// MARK: - Smart Search Settings

/// Settings for smart search behavior
public struct SmartSearchSettings: Codable, Equatable, Sendable {
    /// Default maximum number of results to retrieve per smart search
    public var defaultMaxResults: Int16

    public init(defaultMaxResults: Int16 = 10000) {
        self.defaultMaxResults = defaultMaxResults
    }

    public static let `default` = SmartSearchSettings()
}

// MARK: - Smart Search Settings Store

/// Actor-based store for smart search settings
/// Uses iCloud sync for cross-device consistency
public actor SmartSearchSettingsStore {
    public static let shared = SmartSearchSettingsStore(userDefaults: .forCurrentEnvironment)

    private let userDefaults: UserDefaults
    private let legacySettingsKey = "smartSearchSettings"
    private var cachedSettings: SmartSearchSettings?
    private var syncObserver: NSObjectProtocol?

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    /// Get current settings (cached or loaded from synced storage)
    public var settings: SmartSearchSettings {
        if let cached = cachedSettings {
            return cached
        }
        let loaded = loadSettings()
        cachedSettings = loaded
        return loaded
    }

    /// Set up observer for sync changes from other devices
    public func setupSyncObserver() {
        syncObserver = NotificationCenter.default.addObserver(
            forName: .syncedSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let changedKeys = notification.userInfo?["changedKeys"] as? [String] else { return }

            if changedKeys.contains(SyncedSettingsKey.smartSearchMaxResults.rawValue) {
                Task { await self?.reloadFromSync() }
            }
        }
    }

    private func reloadFromSync() {
        cachedSettings = nil
        _ = settings
        Logger.smartSearch.info("Smart search settings reloaded from sync")
    }

    /// Load settings from synced storage
    private func loadSettings() -> SmartSearchSettings {
        migrateFromLocalIfNeeded()

        let store = SyncedSettingsStore.shared
        let maxResults = Int16(store.int(forKey: .smartSearchMaxResults) ?? 10000)

        Logger.smartSearch.infoCapture("Loaded smart search settings: maxResults=\(maxResults)", category: "smartsearch")
        return SmartSearchSettings(defaultMaxResults: maxResults)
    }

    private func migrateFromLocalIfNeeded() {
        let store = SyncedSettingsStore.shared

        guard store.int(forKey: .smartSearchMaxResults) == nil,
              let data = userDefaults.data(forKey: legacySettingsKey),
              let legacy = try? JSONDecoder().decode(SmartSearchSettings.self, from: data) else {
            return
        }

        Logger.smartSearch.info("Migrating smart search settings from local to synced storage")
        store.set(Int(legacy.defaultMaxResults), forKey: .smartSearchMaxResults)
        userDefaults.removeObject(forKey: legacySettingsKey)
    }

    /// Save settings to synced storage
    private func saveSettings(_ settings: SmartSearchSettings) {
        cachedSettings = settings
        SyncedSettingsStore.shared.set(Int(settings.defaultMaxResults), forKey: .smartSearchMaxResults)
        Logger.smartSearch.infoCapture("Saved smart search settings: maxResults=\(settings.defaultMaxResults)", category: "smartsearch")
    }

    /// Update default maximum results
    public func updateDefaultMaxResults(_ maxResults: Int16) {
        var current = settings
        current.defaultMaxResults = maxResults
        saveSettings(current)
    }

    /// Reset settings to defaults
    public func reset() {
        SyncedSettingsStore.shared.remove(forKey: .smartSearchMaxResults)
        cachedSettings = nil
        Logger.smartSearch.infoCapture("Reset smart search settings to defaults", category: "smartsearch")
    }

    /// Clear cached settings (for testing)
    public func clearCache() {
        cachedSettings = nil
    }
}
