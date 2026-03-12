//
//  AutoTagSettings.swift
//  PublicationManagerCore
//
//  Settings for Apple Intelligence auto-tagging of enriched papers.
//

import Foundation
import OSLog

/// Settings controlling AI auto-tagging behavior after paper enrichment.
public struct AutoTagSettings: Codable, Equatable, Sendable {
    /// Whether auto-tagging is enabled (requires Apple Intelligence, macOS 26+)
    public var enabled: Bool = true

    /// Minimum confidence threshold for applying tags (0.5–1.0)
    public var confidenceThreshold: Double = 0.7

    /// Tag field classification (e.g., ai/field/cosmology)
    public var includeFieldTag: Bool = true

    /// Tag paper type (e.g., ai/type/review) — off by default to reduce noise
    public var includeTypeTag: Bool = false

    /// Tag topic keywords (e.g., ai/topic/dark-energy)
    public var includeTopicTags: Bool = true

    public init() {}
}

/// Actor-based persistent store for auto-tag settings.
///
/// Follows the same pattern as `ListViewSettingsStore`.
public actor AutoTagSettingsStore {

    // MARK: - Shared Instance

    public static let shared = AutoTagSettingsStore(userDefaults: .forCurrentEnvironment)

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private let settingsKey = "autoTagSettings"
    private var cachedSettings: AutoTagSettings?

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    // MARK: - Public API

    /// Get current settings (cached or loaded from UserDefaults)
    public var settings: AutoTagSettings {
        if let cached = cachedSettings {
            return cached
        }
        let loaded = loadSettings()
        cachedSettings = loaded
        return loaded
    }

    /// Load settings synchronously (for @State initialization)
    public nonisolated static func loadSettingsSync() -> AutoTagSettings {
        guard let data = UserDefaults.forCurrentEnvironment.data(forKey: "autoTagSettings"),
              let settings = try? JSONDecoder().decode(AutoTagSettings.self, from: data) else {
            return AutoTagSettings()
        }
        return settings
    }

    /// Update all settings at once
    public func update(_ settings: AutoTagSettings) {
        saveSettings(settings)
    }

    /// Reset settings to defaults
    public func reset() {
        userDefaults.removeObject(forKey: settingsKey)
        cachedSettings = nil
    }

    // MARK: - Private

    private func loadSettings() -> AutoTagSettings {
        guard let data = userDefaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AutoTagSettings.self, from: data) else {
            return AutoTagSettings()
        }
        return settings
    }

    private func saveSettings(_ settings: AutoTagSettings) {
        cachedSettings = settings
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: settingsKey)
        }
    }
}
