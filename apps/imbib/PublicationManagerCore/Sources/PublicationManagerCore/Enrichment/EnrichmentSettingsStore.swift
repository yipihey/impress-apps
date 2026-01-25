//
//  EnrichmentSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Enrichment Settings Store

/// Persistent storage for enrichment settings using iCloud sync.
///
/// This actor provides thread-safe access to enrichment settings and
/// syncs changes across devices via iCloud.
///
/// ## Usage
///
/// ```swift
/// // Get shared instance
/// let store = EnrichmentSettingsStore.shared
///
/// // Read settings
/// let settings = await store.settings
///
/// // Update settings
/// await store.update(\.autoSyncEnabled, to: false)
/// await store.updateSettings(newSettings)
/// ```
public actor EnrichmentSettingsStore: EnrichmentSettingsProvider {

    // MARK: - Shared Instance

    /// Shared instance using environment-aware UserDefaults.
    public static let shared = EnrichmentSettingsStore(userDefaults: .forCurrentEnvironment)

    // MARK: - Constants

    /// Legacy UserDefaults key for migration.
    public static let userDefaultsKey = "com.imbib.enrichmentSettings"

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private var cachedSettings: EnrichmentSettings
    private var syncObserver: NSObjectProtocol?

    // MARK: - Initialization

    /// Create a settings store with the specified UserDefaults.
    ///
    /// - Parameter userDefaults: UserDefaults instance to use (defaults to environment-aware defaults)
    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
        self.cachedSettings = Self.loadSettingsFromSync(userDefaults: userDefaults)
    }

    /// Set up observer for sync changes from other devices
    public func setupSyncObserver() {
        syncObserver = NotificationCenter.default.addObserver(
            forName: .syncedSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let changedKeys = notification.userInfo?["changedKeys"] as? [String] else { return }

            let enrichmentKeys: [String] = [
                SyncedSettingsKey.enrichmentPreferredSource.rawValue,
                SyncedSettingsKey.enrichmentSourcePriority.rawValue,
                SyncedSettingsKey.enrichmentAutoSyncEnabled.rawValue,
                SyncedSettingsKey.enrichmentRefreshIntervalDays.rawValue
            ]

            if changedKeys.contains(where: { enrichmentKeys.contains($0) }) {
                Task { await self?.reloadFromSync() }
            }
        }
    }

    private func reloadFromSync() {
        cachedSettings = Self.loadSettingsFromSync(userDefaults: userDefaults)
        Logger.enrichment.info("Enrichment settings reloaded from sync")
    }

    // MARK: - Read Settings

    /// Current enrichment settings.
    public var settings: EnrichmentSettings {
        cachedSettings
    }

    // MARK: - EnrichmentSettingsProvider Conformance

    public var preferredSource: EnrichmentSource {
        cachedSettings.preferredSource
    }

    public var sourcePriority: [EnrichmentSource] {
        cachedSettings.sourcePriority
    }

    public var autoSyncEnabled: Bool {
        cachedSettings.autoSyncEnabled
    }

    public var refreshIntervalDays: Int {
        cachedSettings.refreshIntervalDays
    }

    // MARK: - Update Settings

    /// Update all settings at once.
    ///
    /// - Parameter newSettings: New settings to save
    public func updateSettings(_ newSettings: EnrichmentSettings) {
        cachedSettings = newSettings
        saveSettings()
        Logger.enrichment.info("EnrichmentSettingsStore: updated all settings")
    }

    /// Update the preferred source.
    ///
    /// - Parameter source: New preferred source
    public func updatePreferredSource(_ source: EnrichmentSource) {
        cachedSettings.preferredSource = source
        saveSettings()
        Logger.enrichment.debug("EnrichmentSettingsStore: preferred source -> \(source.rawValue)")
    }

    /// Update the source priority order.
    ///
    /// - Parameter priority: New priority order
    public func updateSourcePriority(_ priority: [EnrichmentSource]) {
        cachedSettings.sourcePriority = priority
        saveSettings()
        Logger.enrichment.debug("EnrichmentSettingsStore: source priority updated")
    }

    /// Update auto-sync enabled setting.
    ///
    /// - Parameter enabled: Whether auto-sync should be enabled
    public func updateAutoSyncEnabled(_ enabled: Bool) {
        cachedSettings.autoSyncEnabled = enabled
        saveSettings()
        Logger.enrichment.debug("EnrichmentSettingsStore: auto-sync -> \(enabled)")
    }

    /// Update refresh interval in days.
    ///
    /// - Parameter days: Number of days between enrichment refreshes
    public func updateRefreshIntervalDays(_ days: Int) {
        cachedSettings.refreshIntervalDays = max(1, days)  // Minimum 1 day
        saveSettings()
        Logger.enrichment.debug("EnrichmentSettingsStore: refresh interval -> \(days) days")
    }

    /// Move a source to a different position in the priority list.
    ///
    /// - Parameters:
    ///   - source: Source to move
    ///   - index: New position (clamped to valid range)
    public func moveSource(_ source: EnrichmentSource, to index: Int) {
        var priority = cachedSettings.sourcePriority
        guard let currentIndex = priority.firstIndex(of: source) else { return }

        priority.remove(at: currentIndex)
        let newIndex = max(0, min(index, priority.count))
        priority.insert(source, at: newIndex)

        cachedSettings.sourcePriority = priority
        saveSettings()
        Logger.enrichment.debug("EnrichmentSettingsStore: moved \(source.rawValue) to index \(newIndex)")
    }

    /// Reset settings to defaults.
    public func resetToDefaults() {
        cachedSettings = .default
        saveSettings()
        Logger.enrichment.info("EnrichmentSettingsStore: reset to defaults")
    }

    // MARK: - Private Helpers

    /// Save current settings to synced storage.
    private func saveSettings() {
        let store = SyncedSettingsStore.shared
        store.set(cachedSettings.preferredSource.rawValue, forKey: .enrichmentPreferredSource)
        store.set(cachedSettings.sourcePriority.map { $0.rawValue }, forKey: .enrichmentSourcePriority)
        store.set(cachedSettings.autoSyncEnabled, forKey: .enrichmentAutoSyncEnabled)
        store.set(cachedSettings.refreshIntervalDays, forKey: .enrichmentRefreshIntervalDays)
        Logger.enrichment.debug("EnrichmentSettingsStore: saved settings to sync")
    }

    /// Load settings from synced storage, migrating from local if needed.
    private static func loadSettingsFromSync(userDefaults: UserDefaults) -> EnrichmentSettings {
        let store = SyncedSettingsStore.shared

        // Migrate from legacy local storage if needed
        if store.string(forKey: .enrichmentPreferredSource) == nil,
           let data = userDefaults.data(forKey: userDefaultsKey),
           let legacy = try? JSONDecoder().decode(EnrichmentSettings.self, from: data) {
            Logger.enrichment.info("Migrating enrichment settings from local to synced storage")
            store.set(legacy.preferredSource.rawValue, forKey: .enrichmentPreferredSource)
            store.set(legacy.sourcePriority.map { $0.rawValue }, forKey: .enrichmentSourcePriority)
            store.set(legacy.autoSyncEnabled, forKey: .enrichmentAutoSyncEnabled)
            store.set(legacy.refreshIntervalDays, forKey: .enrichmentRefreshIntervalDays)
            userDefaults.removeObject(forKey: userDefaultsKey)
            return legacy
        }

        // Load from synced storage
        let preferredSource: EnrichmentSource = {
            if let rawValue = store.string(forKey: .enrichmentPreferredSource),
               let source = EnrichmentSource(rawValue: rawValue) {
                return source
            }
            return .ads
        }()

        let sourcePriority: [EnrichmentSource] = {
            if let rawValues = store.stringArray(forKey: .enrichmentSourcePriority) {
                return rawValues.compactMap { EnrichmentSource(rawValue: $0) }
            }
            return EnrichmentSource.allCases
        }()

        let autoSyncEnabled = store.bool(forKey: .enrichmentAutoSyncEnabled) ?? true
        let refreshIntervalDays = store.int(forKey: .enrichmentRefreshIntervalDays) ?? 7

        Logger.enrichment.debug("EnrichmentSettingsStore: loaded settings from sync")
        return EnrichmentSettings(
            preferredSource: preferredSource,
            sourcePriority: sourcePriority,
            autoSyncEnabled: autoSyncEnabled,
            refreshIntervalDays: refreshIntervalDays
        )
    }
}

// MARK: - Convenience Extensions

extension EnrichmentSettingsStore {
    /// Check if a source is in the priority list.
    public func isSourceEnabled(_ source: EnrichmentSource) -> Bool {
        cachedSettings.sourcePriority.contains(source)
    }

    /// Get the priority rank of a source (0 = highest priority).
    public func priorityRank(of source: EnrichmentSource) -> Int? {
        cachedSettings.sourcePriority.firstIndex(of: source)
    }

    /// Get the highest priority source that's enabled.
    public var topPrioritySource: EnrichmentSource? {
        cachedSettings.sourcePriority.first
    }
}
