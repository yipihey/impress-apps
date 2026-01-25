//
//  QuickAnnotationSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import OSLog

// MARK: - Quick Annotation Settings Store

/// Actor-based store for quick annotation settings.
/// Uses iCloud sync for cross-device consistency.
public actor QuickAnnotationSettingsStore {
    public static let shared = QuickAnnotationSettingsStore(userDefaults: .forCurrentEnvironment)

    private let userDefaults: UserDefaults
    private let legacySettingsKey = "quickAnnotationSettings"
    private var cachedSettings: QuickAnnotationSettings?
    private var syncObserver: NSObjectProtocol?

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    /// Get current settings (cached or loaded from synced storage)
    public var settings: QuickAnnotationSettings {
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

            if changedKeys.contains(SyncedSettingsKey.quickAnnotationFields.rawValue) {
                Task { await self?.reloadFromSync() }
            }
        }
    }

    private func reloadFromSync() {
        cachedSettings = nil
        _ = settings
        Logger.notes.info("Quick annotation settings reloaded from sync")
    }

    /// Load settings from synced storage
    private func loadSettings() -> QuickAnnotationSettings {
        migrateFromLocalIfNeeded()

        let store = SyncedSettingsStore.shared
        if let settings: QuickAnnotationSettings = store.decodable(forKey: .quickAnnotationFields, as: QuickAnnotationSettings.self) {
            Logger.notes.infoCapture("Loaded quick annotation settings: \(settings.fields.count) fields", category: "notes")
            return settings
        }

        Logger.notes.infoCapture("No quick annotation settings found, using defaults", category: "notes")
        return .defaults
    }

    private func migrateFromLocalIfNeeded() {
        let store = SyncedSettingsStore.shared

        guard store.data(forKey: .quickAnnotationFields) == nil,
              let data = userDefaults.data(forKey: legacySettingsKey),
              let legacy = try? JSONDecoder().decode(QuickAnnotationSettings.self, from: data) else {
            return
        }

        Logger.notes.info("Migrating quick annotation settings from local to synced storage")
        store.set(legacy, forKey: .quickAnnotationFields)
        userDefaults.removeObject(forKey: legacySettingsKey)
    }

    /// Save settings to synced storage
    private func saveSettings(_ settings: QuickAnnotationSettings) {
        cachedSettings = settings
        SyncedSettingsStore.shared.set(settings, forKey: .quickAnnotationFields)
        Logger.notes.infoCapture("Saved quick annotation settings", category: "notes")
    }

    /// Update all settings
    public func update(_ settings: QuickAnnotationSettings) {
        saveSettings(settings)
    }

    /// Update a single field
    public func updateField(_ field: QuickAnnotationField) {
        var current = settings
        if let index = current.fields.firstIndex(where: { $0.id == field.id }) {
            current.fields[index] = field
            saveSettings(current)
        }
    }

    /// Add a new field
    public func addField(_ field: QuickAnnotationField) {
        var current = settings
        current.fields.append(field)
        saveSettings(current)
        Logger.notes.infoCapture("Added quick annotation field: \(field.label)", category: "notes")
    }

    /// Delete a field by ID
    public func deleteField(id: String) {
        var current = settings
        current.fields.removeAll { $0.id == id }
        saveSettings(current)
        Logger.notes.infoCapture("Deleted quick annotation field: \(id)", category: "notes")
    }

    /// Reorder fields
    public func reorderFields(from source: IndexSet, to destination: Int) {
        var current = settings
        current.fields.move(fromOffsets: source, toOffset: destination)
        saveSettings(current)
    }

    /// Reset settings to defaults
    public func resetToDefaults() {
        SyncedSettingsStore.shared.remove(forKey: .quickAnnotationFields)
        cachedSettings = nil
        Logger.notes.infoCapture("Reset quick annotation settings to defaults", category: "notes")
    }

    /// Clear cached settings (for testing)
    public func clearCache() {
        cachedSettings = nil
    }
}

// MARK: - Logger Extension

extension Logger {
    static let notes = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "notes")
}
