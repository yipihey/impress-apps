//
//  RecommendationSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import OSLog

// MARK: - Recommendation Settings (ADR-020)

/// Actor that manages recommendation engine settings.
///
/// Settings are synced across devices via SyncedSettingsStore.
/// All weights are user-adjustable and changes take effect immediately.
public actor RecommendationSettingsStore {

    // MARK: - Singleton

    public static let shared = RecommendationSettingsStore()

    // MARK: - Settings Structure

    /// All recommendation settings bundled together.
    public struct Settings: Codable, Sendable, Equatable {
        /// Feature weights (user-adjustable)
        public var featureWeights: [String: Double]  // FeatureType.rawValue -> weight

        /// Serendipity slot frequency (1 per N papers)
        public var serendipitySlotFrequency: Int

        /// Minutes between re-ranking (throttle)
        public var reRankThrottleMinutes: Int

        /// Days after which negative preferences decay
        public var negativePrefDecayDays: Int

        /// Whether recommendation sorting is enabled
        public var isEnabled: Bool

        /// The recommendation engine type to use
        public var engineType: RecommendationEngineType

        public init(
            featureWeights: [String: Double] = [:],
            serendipitySlotFrequency: Int = 10,
            reRankThrottleMinutes: Int = 5,
            negativePrefDecayDays: Int = 90,
            isEnabled: Bool = true,
            engineType: RecommendationEngineType = .classic
        ) {
            // Initialize with defaults if empty
            if featureWeights.isEmpty {
                self.featureWeights = Dictionary(
                    uniqueKeysWithValues: FeatureType.allCases.map { ($0.rawValue, $0.defaultWeight) }
                )
            } else {
                self.featureWeights = featureWeights
            }
            self.serendipitySlotFrequency = serendipitySlotFrequency
            self.reRankThrottleMinutes = reRankThrottleMinutes
            self.negativePrefDecayDays = negativePrefDecayDays
            self.isEnabled = isEnabled
            self.engineType = engineType
        }

        /// Get weight for a specific feature type
        public func weight(for feature: FeatureType) -> Double {
            featureWeights[feature.rawValue] ?? feature.defaultWeight
        }

        /// Set weight for a specific feature type
        public mutating func setWeight(_ weight: Double, for feature: FeatureType) {
            featureWeights[feature.rawValue] = weight
        }

        /// Reset all weights to defaults
        public mutating func resetToDefaults() {
            featureWeights = Dictionary(
                uniqueKeysWithValues: FeatureType.allCases.map { ($0.rawValue, $0.defaultWeight) }
            )
        }

        /// Apply a preset
        public mutating func apply(preset: RecommendationPreset) {
            for (feature, weight) in preset.weights {
                featureWeights[feature.rawValue] = weight
            }
        }

        /// Default settings
        public static let `default` = Settings()
    }

    // MARK: - Properties

    private var cachedSettings: Settings?
    private let syncedStore = SyncedSettingsStore.shared

    // MARK: - Initialization

    private init() {
        // Load settings on init
        Task {
            _ = await loadSettings()
        }
    }

    // MARK: - Public API

    /// Get current settings
    public func settings() async -> Settings {
        if let cached = cachedSettings {
            return cached
        }
        return await loadSettings()
    }

    /// Update settings
    public func update(_ settings: Settings) async {
        cachedSettings = settings
        await saveSettings(settings)
        Logger.settings.info("Recommendation settings updated")
    }

    /// Check if recommendations are enabled
    public func isEnabled() async -> Bool {
        let settings = await settings()
        return settings.isEnabled
    }

    /// Set enabled state
    public func setEnabled(_ enabled: Bool) async {
        var settings = await settings()
        settings.isEnabled = enabled
        await update(settings)
    }

    /// Get weight for a specific feature
    public func weight(for feature: FeatureType) async -> Double {
        let settings = await settings()
        return settings.weight(for: feature)
    }

    /// Set weight for a specific feature
    public func setWeight(_ weight: Double, for feature: FeatureType) async {
        var settings = await settings()
        settings.setWeight(weight, for: feature)
        await update(settings)
    }

    /// Get all weights as a dictionary
    public func allWeights() async -> [FeatureType: Double] {
        let settings = await settings()
        var weights: [FeatureType: Double] = [:]
        for feature in FeatureType.allCases {
            weights[feature] = settings.weight(for: feature)
        }
        return weights
    }

    /// Apply a preset
    public func applyPreset(_ preset: RecommendationPreset) async {
        var settings = await settings()
        settings.apply(preset: preset)
        await update(settings)
        Logger.settings.info("Applied recommendation preset: \(preset.rawValue)")
    }

    /// Reset to defaults
    public func resetToDefaults() async {
        var settings = await settings()
        settings.resetToDefaults()
        await update(settings)
        Logger.settings.info("Reset recommendation settings to defaults")
    }

    /// Get serendipity frequency
    public func serendipityFrequency() async -> Int {
        let settings = await settings()
        return settings.serendipitySlotFrequency
    }

    /// Set serendipity frequency
    public func setSerendipityFrequency(_ frequency: Int) async {
        var settings = await settings()
        settings.serendipitySlotFrequency = max(1, frequency)  // At least 1
        await update(settings)
    }

    /// Get re-rank throttle minutes
    public func reRankThrottleMinutes() async -> Int {
        let settings = await settings()
        return settings.reRankThrottleMinutes
    }

    /// Get negative preference decay days
    public func negativePrefDecayDays() async -> Int {
        let settings = await settings()
        return settings.negativePrefDecayDays
    }

    /// Set negative preference decay days
    public func setNegativePrefDecayDays(_ days: Int) async {
        var settings = await settings()
        settings.negativePrefDecayDays = max(1, days)
        await update(settings)
    }

    /// Get current engine type
    public func engineType() async -> RecommendationEngineType {
        let settings = await settings()
        return settings.engineType
    }

    /// Set engine type
    public func setEngineType(_ type: RecommendationEngineType) async {
        var settings = await settings()
        settings.engineType = type
        await update(settings)
        Logger.settings.info("Recommendation engine type changed to: \(type.rawValue)")
    }

    // MARK: - Private Methods

    @discardableResult
    private func loadSettings() async -> Settings {
        // Check for synced enabled state
        let enabled = syncedStore.bool(forKey: .recommendationEnabled) ?? true

        // Check for synced weights
        let weights: [String: Double]
        if let data = syncedStore.data(forKey: .recommendationWeights),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            weights = decoded
        } else {
            weights = [:]
        }

        // Check for other settings
        let serendipity = syncedStore.int(forKey: .recommendationSerendipityFrequency) ?? 10
        let decayDays = syncedStore.int(forKey: .recommendationDecayDays) ?? 90
        let throttle = syncedStore.int(forKey: .recommendationReRankThrottleMinutes) ?? 5

        // Check for engine type
        let engineTypeRaw = syncedStore.string(forKey: .recommendationEngineType)
        let engineType = engineTypeRaw.flatMap { RecommendationEngineType(rawValue: $0) } ?? .classic

        let settings = Settings(
            featureWeights: weights,
            serendipitySlotFrequency: serendipity,
            reRankThrottleMinutes: throttle,
            negativePrefDecayDays: decayDays,
            isEnabled: enabled,
            engineType: engineType
        )

        cachedSettings = settings
        return settings
    }

    private func saveSettings(_ settings: Settings) async {
        // Save enabled state
        syncedStore.set(settings.isEnabled, forKey: .recommendationEnabled)

        // Save weights
        if let data = try? JSONEncoder().encode(settings.featureWeights) {
            syncedStore.set(data, forKey: .recommendationWeights)
        }

        // Save other settings
        syncedStore.set(settings.serendipitySlotFrequency, forKey: .recommendationSerendipityFrequency)
        syncedStore.set(settings.negativePrefDecayDays, forKey: .recommendationDecayDays)
        syncedStore.set(settings.reRankThrottleMinutes, forKey: .recommendationReRankThrottleMinutes)
        syncedStore.set(settings.engineType.rawValue, forKey: .recommendationEngineType)
    }

    // MARK: - External Change Handling

    /// Called when synced settings change from another device.
    /// Invalidates the cache so next access reloads from store.
    public func handleExternalChange() async {
        cachedSettings = nil
        Logger.settings.info("Recommendation settings invalidated due to external change")
    }
}

// MARK: - Notification Support

public extension Notification.Name {
    /// Posted when recommendation settings change
    static let recommendationSettingsDidChange = Notification.Name("recommendationSettingsDidChange")
}
