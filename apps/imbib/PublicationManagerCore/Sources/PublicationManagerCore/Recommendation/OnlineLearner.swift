//
//  OnlineLearner.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import OSLog

// MARK: - Online Learner (ADR-020)

/// Updates the recommendation profile based on training events.
///
/// Implements online learning rules:
/// - Keep: `+η` for matching author/topic/venue affinities
/// - Dismiss: `−η` for matching affinities
/// - Star: `+2η` (stronger positive)
/// - Read/Download: `+0.5η` (moderate positive)
///
/// Also handles negative preference decay.
public actor OnlineLearner {

    // MARK: - Singleton

    public static let shared = OnlineLearner()

    // MARK: - Properties

    /// Base learning rate
    private let learningRate: Double = 0.05

    /// Maximum absolute affinity value (prevents runaway values)
    private nonisolated let maxAffinityMagnitude: Double = 5.0

    private let settingsStore = RecommendationSettingsStore.shared

    // MARK: - Initialization

    private init() {
        // Observe training events
        Task {
            await setupNotificationObservers()
        }
    }

    private func setupNotificationObservers() async {
        await MainActor.run {
            // Listen for new training events
            NotificationCenter.default.addObserver(
                forName: .recommendationTrainingEventRecorded,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let event = notification.object as? TrainingEvent else { return }
                Task {
                    await self?.train(on: event)
                }
            }

            // Listen for undone events
            NotificationCenter.default.addObserver(
                forName: .recommendationTrainingEventUndone,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let event = notification.object as? TrainingEvent else { return }
                Task {
                    await self?.undoTraining(for: event)
                }
            }
        }
    }

    // MARK: - Store Access Helper

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Profile Access

    @MainActor
    private func getOrCreateProfile() -> RecommendationProfile {
        let store = RustStoreAdapter.shared
        guard let defaultLibrary = store.getDefaultLibrary() else {
            return RecommendationProfile()
        }

        if let existingJSON = store.getRecommendationProfile(libraryId: defaultLibrary.id),
           let existing = RecommendationProfile.fromJSON(existingJSON) {
            return existing
        }

        return RecommendationProfile()
    }

    @MainActor
    private func saveProfile(_ profile: RecommendationProfile) {
        let store = RustStoreAdapter.shared
        guard let defaultLibrary = store.getDefaultLibrary() else { return }

        let authorJSON = (try? JSONEncoder().encode(profile.authorAffinities)).flatMap { String(data: $0, encoding: .utf8) }
        let venueJSON = (try? JSONEncoder().encode(profile.venueAffinities)).flatMap { String(data: $0, encoding: .utf8) }
        let topicJSON = (try? JSONEncoder().encode(profile.topicAffinities)).flatMap { String(data: $0, encoding: .utf8) }

        store.createOrUpdateRecommendationProfile(
            libraryId: defaultLibrary.id,
            topicAffinitiesJson: topicJSON,
            authorAffinitiesJson: authorJSON,
            venueAffinitiesJson: venueJSON
        )
    }

    // MARK: - Training

    /// Update profile based on a training event.
    public func train(on event: TrainingEvent) async {
        await MainActor.run {
            var profile = getOrCreateProfile()

            let multiplier = event.action.learningMultiplier * learningRate

            // Apply weight deltas from the event
            for (key, baseDelta) in event.weightDeltas {
                let delta = baseDelta * multiplier

                // Parse the key to determine which affinity to update
                if key.hasPrefix("author:") {
                    let author = String(key.dropFirst("author:".count))
                    updateAffinity(profile: &profile, type: .author, key: author, delta: delta)
                } else if key.hasPrefix("venue:") {
                    let venue = String(key.dropFirst("venue:".count))
                    updateAffinity(profile: &profile, type: .venue, key: venue, delta: delta)
                } else if key.hasPrefix("topic:") {
                    let topic = String(key.dropFirst("topic:".count))
                    updateAffinity(profile: &profile, type: .topic, key: topic, delta: delta)
                } else if key.hasPrefix("category:") {
                    let category = String(key.dropFirst("category:".count))
                    updateAffinity(profile: &profile, type: .topic, key: category, delta: delta)
                }
            }

            profile.lastUpdated = Date()
            saveProfile(profile)

            Logger.recommendation.debug("Applied training for: \(event.action.rawValue)")
        }

        // Invalidate recommendation cache
        await RecommendationEngine.shared.invalidateCache()
    }

    /// Reverse the effects of a training event (undo).
    public func undoTraining(for event: TrainingEvent) async {
        await MainActor.run {
            var profile = getOrCreateProfile()

            let multiplier = event.action.learningMultiplier * learningRate

            // Reverse the weight deltas
            for (key, baseDelta) in event.weightDeltas {
                let delta = -baseDelta * multiplier  // Negative to reverse

                if key.hasPrefix("author:") {
                    let author = String(key.dropFirst("author:".count))
                    updateAffinity(profile: &profile, type: .author, key: author, delta: delta)
                } else if key.hasPrefix("venue:") {
                    let venue = String(key.dropFirst("venue:".count))
                    updateAffinity(profile: &profile, type: .venue, key: venue, delta: delta)
                } else if key.hasPrefix("topic:") {
                    let topic = String(key.dropFirst("topic:".count))
                    updateAffinity(profile: &profile, type: .topic, key: topic, delta: delta)
                } else if key.hasPrefix("category:") {
                    let category = String(key.dropFirst("category:".count))
                    updateAffinity(profile: &profile, type: .topic, key: category, delta: delta)
                }
            }

            profile.lastUpdated = Date()
            saveProfile(profile)

            Logger.recommendation.debug("Undone training for: \(event.action.rawValue)")
        }

        await RecommendationEngine.shared.invalidateCache()
    }

    // MARK: - Affinity Types

    private enum AffinityType {
        case author
        case venue
        case topic
    }

    nonisolated private func updateAffinity(
        profile: inout RecommendationProfile,
        type: AffinityType,
        key: String,
        delta: Double
    ) {
        switch type {
        case .author:
            let current = profile.authorAffinities[key] ?? 0.0
            let new = clamp(current + delta, min: -maxAffinityMagnitude, max: maxAffinityMagnitude)
            profile.authorAffinities[key] = new

        case .venue:
            let current = profile.venueAffinities[key] ?? 0.0
            let new = clamp(current + delta, min: -maxAffinityMagnitude, max: maxAffinityMagnitude)
            profile.venueAffinities[key] = new

        case .topic:
            let current = profile.topicAffinities[key] ?? 0.0
            let new = clamp(current + delta, min: -maxAffinityMagnitude, max: maxAffinityMagnitude)
            profile.topicAffinities[key] = new
        }
    }

    // MARK: - Negative Preference Decay

    /// Apply decay to negative preferences over time.
    ///
    /// This prevents old dismissals from permanently affecting rankings.
    /// Called periodically (e.g., on app launch).
    public func applyDecay() async {
        let decayDays = await settingsStore.negativePrefDecayDays()
        let decayFactor = 0.9  // 10% decay per application

        await MainActor.run {
            var profile = getOrCreateProfile()

            let cutoffDate = Calendar.current.date(byAdding: .day, value: -decayDays, to: Date()) ?? Date()

            // Only apply decay if profile is old enough
            guard profile.lastUpdated < cutoffDate else { return }

            // Decay negative author affinities
            for (key, value) in profile.authorAffinities where value < 0 {
                profile.authorAffinities[key] = value * decayFactor
            }

            // Decay negative venue affinities
            for (key, value) in profile.venueAffinities where value < 0 {
                profile.venueAffinities[key] = value * decayFactor
            }

            // Decay negative topic affinities
            for (key, value) in profile.topicAffinities where value < 0 {
                profile.topicAffinities[key] = value * decayFactor
            }

            profile.lastUpdated = Date()
            saveProfile(profile)

            Logger.recommendation.info("Applied negative preference decay")
        }

        await RecommendationEngine.shared.invalidateCache()
    }

    /// Clean up very small affinities (noise reduction).
    public func pruneSmallAffinities(threshold: Double = 0.01) async {
        await MainActor.run {
            var profile = getOrCreateProfile()

            // Prune author affinities
            profile.authorAffinities = profile.authorAffinities.filter { abs($0.value) >= threshold }

            // Prune venue affinities
            profile.venueAffinities = profile.venueAffinities.filter { abs($0.value) >= threshold }

            // Prune topic affinities
            profile.topicAffinities = profile.topicAffinities.filter { abs($0.value) >= threshold }

            saveProfile(profile)

            Logger.recommendation.debug("Pruned small affinities below threshold \(threshold)")
        }
    }

    // MARK: - Helpers

    nonisolated private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        return Swift.min(Swift.max(value, min), max)
    }
}
