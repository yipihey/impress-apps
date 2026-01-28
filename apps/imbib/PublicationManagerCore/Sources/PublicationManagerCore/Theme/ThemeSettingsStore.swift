//
//  ThemeSettingsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import Foundation
import OSLog

// MARK: - Notification

public extension Notification.Name {
    /// Posted when theme settings change
    static let themeSettingsDidChange = Notification.Name("themeSettingsDidChange")
}

// MARK: - Theme Settings Store

/// Actor-based store for theme settings.
///
/// Uses UserDefaults for persistence with in-memory caching for performance.
/// Thread-safe for concurrent access from any async context.
///
/// Usage:
/// ```swift
/// // Get current theme
/// let theme = await ThemeSettingsStore.shared.settings
///
/// // Apply a predefined theme
/// await ThemeSettingsStore.shared.applyTheme(.academicBlue)
///
/// // Update settings
/// await ThemeSettingsStore.shared.update(modifiedSettings)
/// ```
public actor ThemeSettingsStore {

    // MARK: - Singleton

    public static let shared = ThemeSettingsStore(userDefaults: .forCurrentEnvironment)

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let settingsKey = "themeSettings"
    private var cachedSettings: ThemeSettings?

    private static let logger = Logger(subsystem: "com.imbib.app", category: "theme")

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    // MARK: - Settings Access

    /// Get current settings (cached or loaded from UserDefaults)
    public var settings: ThemeSettings {
        if let cached = cachedSettings {
            return cached
        }
        let loaded = loadSettings()
        cachedSettings = loaded
        return loaded
    }

    /// Synchronous settings load for initial state (call from main thread during init)
    public nonisolated static func loadSettingsSync(from userDefaults: UserDefaults = .forCurrentEnvironment) -> ThemeSettings {
        guard let data = userDefaults.data(forKey: "themeSettings"),
              let settings = try? JSONDecoder().decode(ThemeSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    // MARK: - Settings Update

    /// Update theme settings
    public func update(_ settings: ThemeSettings) {
        saveSettings(settings)
        postNotification()
    }

    /// Apply a predefined theme by ID
    public func applyTheme(_ themeID: ThemeID) {
        let theme = ThemeSettings.predefined(themeID)
        update(theme)
        Self.logger.info("Applied theme: \(themeID.rawValue)")
    }

    /// Update just the accent color (creates custom theme if not already custom)
    public func updateAccentColor(_ hex: String) {
        var current = settings
        current.accentColorHex = hex
        if current.themeID != .custom {
            current.themeID = .custom
            current.isCustom = true
        }
        saveSettings(current)
        postNotification()
    }

    /// Update sidebar style
    public func updateSidebarStyle(_ style: SidebarStyle, tintHex: String? = nil) {
        var current = settings
        current.sidebarStyle = style
        current.sidebarTintHex = tintHex
        if current.themeID != .custom {
            current.themeID = .custom
            current.isCustom = true
        }
        saveSettings(current)
        postNotification()
    }

    /// Update list background tint
    public func updateListBackgroundTint(_ hex: String?, opacity: Double) {
        var current = settings
        current.listBackgroundTintHex = hex
        current.listBackgroundTintOpacity = opacity
        if current.themeID != .custom {
            current.themeID = .custom
            current.isCustom = true
        }
        saveSettings(current)
        postNotification()
    }

    /// Update typography setting
    public func updateUseSerifTitles(_ useSerif: Bool) {
        var current = settings
        current.useSerifTitles = useSerif
        if current.themeID != .custom {
            current.themeID = .custom
            current.isCustom = true
        }
        saveSettings(current)
        postNotification()
    }

    /// Update font scale (0.7 to 1.4)
    public func updateFontScale(_ scale: Double) {
        var current = settings
        current.fontScale = max(0.7, min(1.4, scale))
        saveSettings(current)
        postNotification()
        Self.logger.info("Updated font scale to \(current.fontScale)")
    }

    /// Increase font scale by one step (0.1)
    public func increaseFontScale() {
        let current = settings.fontScale
        let newScale = min(1.4, current + 0.1)
        updateFontScale(newScale)
    }

    /// Decrease font scale by one step (0.1)
    public func decreaseFontScale() {
        let current = settings.fontScale
        let newScale = max(0.7, current - 0.1)
        updateFontScale(newScale)
    }

    /// Reset font scale to default (1.0)
    public func resetFontScale() {
        updateFontScale(1.0)
    }

    /// Update appearance mode (system/light/dark)
    public func updateAppearanceMode(_ mode: AppearanceMode) {
        var current = settings
        current.appearanceMode = mode
        saveSettings(current)
        postNotification()
        Self.logger.info("Updated appearance mode to \(mode.rawValue)")
    }

    /// Reset settings to default (Mail theme)
    public func reset() {
        userDefaults.removeObject(forKey: settingsKey)
        cachedSettings = nil
        Self.logger.info("Reset theme settings to default")
        postNotification()
    }

    /// Clear cached settings (for testing)
    public func clearCache() {
        cachedSettings = nil
    }

    // MARK: - Private Methods

    private func loadSettings() -> ThemeSettings {
        guard let data = userDefaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(ThemeSettings.self, from: data) else {
            Self.logger.info("No theme settings found, using defaults")
            return .default
        }
        Self.logger.info("Loaded theme settings: \(settings.themeID.rawValue)")
        return settings
    }

    private func saveSettings(_ settings: ThemeSettings) {
        cachedSettings = settings
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: settingsKey)
            Self.logger.info("Saved theme settings: \(settings.themeID.rawValue)")
        }
    }

    private func postNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .themeSettingsDidChange, object: nil)
        }
    }
}
