//
//  InboxSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation
import OSLog

// MARK: - Age Limit Preset

/// Preset values for Inbox paper age limit
public enum AgeLimitPreset: Int, Codable, CaseIterable, Sendable {
    case oneWeek = 7
    case twoWeeks = 14
    case oneMonth = 30
    case threeMonths = 90
    case sixMonths = 180
    case oneYear = 365
    case unlimited = 0

    public var displayName: String {
        switch self {
        case .oneWeek: return "1 week"
        case .twoWeeks: return "2 weeks"
        case .oneMonth: return "1 month"
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        case .oneYear: return "1 year"
        case .unlimited: return "Unlimited"
        }
    }

    /// Number of days for this preset (0 = unlimited)
    public var days: Int { rawValue }

    /// Whether this preset limits the age
    public var hasLimit: Bool { rawValue > 0 }
}

// MARK: - Inbox Settings

/// Settings for the Inbox feature
public struct InboxSettings: Codable, Equatable, Sendable {
    /// How long to keep papers in the Inbox (based on dateAddedToInbox)
    public var ageLimit: AgeLimitPreset

    public static let `default` = InboxSettings(ageLimit: .threeMonths)

    public init(ageLimit: AgeLimitPreset = .threeMonths) {
        self.ageLimit = ageLimit
    }
}

// MARK: - Inbox Settings Store

/// Actor-based store for Inbox settings.
/// Uses iCloud sync for cross-device consistency.
public actor InboxSettingsStore {

    // MARK: - Singleton

    public static let shared = InboxSettingsStore(userDefaults: .forCurrentEnvironment)

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let legacySettingsKey = "inboxSettings"
    private var cachedSettings: InboxSettings?
    private var syncObserver: NSObjectProtocol?

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    // MARK: - Public Interface

    /// Get current settings
    public var settings: InboxSettings {
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

            let inboxKeys = [SyncedSettingsKey.inboxAgeLimit.rawValue]
            if changedKeys.contains(where: { inboxKeys.contains($0) }) {
                Task { await self?.reloadFromSync() }
            }
        }
    }

    private func reloadFromSync() {
        cachedSettings = nil
        _ = settings
        Logger.inbox.info("Inbox settings reloaded from sync")
    }

    /// Update the age limit
    public func updateAgeLimit(_ ageLimit: AgeLimitPreset) {
        var current = settings
        current.ageLimit = ageLimit
        saveSettings(current)
        Logger.inbox.infoCapture("Inbox age limit set to \(ageLimit.displayName)", category: "settings")
    }

    /// Reset to default settings
    public func reset() {
        SyncedSettingsStore.shared.remove(forKey: .inboxAgeLimit)
        cachedSettings = nil
        Logger.inbox.infoCapture("Inbox settings reset to defaults", category: "settings")
    }

    /// Clear cache (for testing)
    public func clearCache() {
        cachedSettings = nil
    }

    // MARK: - Private Helpers

    private func loadSettings() -> InboxSettings {
        migrateFromLocalIfNeeded()

        let store = SyncedSettingsStore.shared
        let ageLimit: AgeLimitPreset = {
            if let rawValue = store.int(forKey: .inboxAgeLimit),
               let preset = AgeLimitPreset(rawValue: rawValue) {
                return preset
            }
            return .threeMonths
        }()

        return InboxSettings(ageLimit: ageLimit)
    }

    private func migrateFromLocalIfNeeded() {
        let store = SyncedSettingsStore.shared

        guard store.int(forKey: .inboxAgeLimit) == nil,
              let data = userDefaults.data(forKey: legacySettingsKey),
              let legacy = try? JSONDecoder().decode(InboxSettings.self, from: data) else {
            return
        }

        Logger.inbox.info("Migrating inbox settings from local to synced storage")
        store.set(legacy.ageLimit.rawValue, forKey: .inboxAgeLimit)
        userDefaults.removeObject(forKey: legacySettingsKey)
    }

    private func saveSettings(_ settings: InboxSettings) {
        cachedSettings = settings
        SyncedSettingsStore.shared.set(settings.ageLimit.rawValue, forKey: .inboxAgeLimit)
    }
}
