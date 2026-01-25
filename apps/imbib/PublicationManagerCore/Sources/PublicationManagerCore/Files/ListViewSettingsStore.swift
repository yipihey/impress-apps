//
//  ListViewSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import OSLog

/// Notification posted when list view settings change
public extension Notification.Name {
    static let listViewSettingsDidChange = Notification.Name("listViewSettingsDidChange")
}

/// Actor-based store for list view settings.
///
/// Uses UserDefaults for persistence with in-memory caching for performance.
/// Thread-safe for concurrent access from any async context.
///
/// Usage:
/// ```swift
/// let settings = await ListViewSettingsStore.shared.settings
/// await ListViewSettingsStore.shared.update(newSettings)
/// ```
public actor ListViewSettingsStore {

    // MARK: - Shared Instance

    public static let shared = ListViewSettingsStore(userDefaults: .forCurrentEnvironment)

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let settingsKey = "listViewSettings"
    private var cachedSettings: ListViewSettings?

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    // MARK: - Public API

    /// Get current settings (cached or loaded from UserDefaults)
    public var settings: ListViewSettings {
        if let cached = cachedSettings {
            return cached
        }
        let loaded = loadSettings()
        cachedSettings = loaded
        return loaded
    }

    /// Load settings synchronously for initial state (bypasses actor isolation).
    ///
    /// Use this for `@State` initialization to avoid first-render with defaults.
    /// For subsequent access, use the async `settings` property.
    public nonisolated static func loadSettingsSync() -> ListViewSettings {
        guard let data = UserDefaults.forCurrentEnvironment.data(forKey: "listViewSettings"),
              let settings = try? JSONDecoder().decode(ListViewSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Update all settings at once
    public func update(_ settings: ListViewSettings) {
        saveSettings(settings)
    }

    /// Update field visibility settings
    public func updateFieldVisibility(
        showYear: Bool? = nil,
        showTitle: Bool? = nil,
        showVenue: Bool? = nil,
        showCitationCount: Bool? = nil,
        showUnreadIndicator: Bool? = nil,
        showAttachmentIndicator: Bool? = nil
    ) {
        var current = settings
        if let showYear = showYear { current.showYear = showYear }
        if let showTitle = showTitle { current.showTitle = showTitle }
        if let showVenue = showVenue { current.showVenue = showVenue }
        if let showCitationCount = showCitationCount { current.showCitationCount = showCitationCount }
        if let showUnreadIndicator = showUnreadIndicator { current.showUnreadIndicator = showUnreadIndicator }
        if let showAttachmentIndicator = showAttachmentIndicator { current.showAttachmentIndicator = showAttachmentIndicator }
        saveSettings(current)
    }

    /// Update abstract line limit (clamped to 0-10)
    public func updateAbstractLineLimit(_ limit: Int) {
        var current = settings
        current.abstractLineLimit = max(0, min(10, limit))
        saveSettings(current)
    }

    /// Update row density
    public func updateRowDensity(_ density: RowDensity) {
        var current = settings
        current.rowDensity = density
        saveSettings(current)
    }

    /// Reset settings to defaults
    public func reset() {
        userDefaults.removeObject(forKey: settingsKey)
        cachedSettings = nil
        Logger.library.infoCapture("Reset list view settings to defaults", category: "settings")
    }

    /// Clear cached settings (for testing)
    public func clearCache() {
        cachedSettings = nil
    }

    // MARK: - Private

    private func loadSettings() -> ListViewSettings {
        guard let data = userDefaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(ListViewSettings.self, from: data) else {
            Logger.library.infoCapture("No list view settings found, using defaults", category: "settings")
            return .default
        }
        Logger.library.infoCapture("Loaded list view settings: abstractLines=\(settings.abstractLineLimit), density=\(settings.rowDensity.rawValue)", category: "settings")
        return settings
    }

    private func saveSettings(_ settings: ListViewSettings) {
        cachedSettings = settings
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: settingsKey)
            Logger.library.infoCapture("Saved list view settings: abstractLines=\(settings.abstractLineLimit), density=\(settings.rowDensity.rawValue)", category: "settings")

            // Post notification on main thread
            Task { @MainActor in
                NotificationCenter.default.post(name: .listViewSettingsDidChange, object: nil)
            }
        }
    }
}
