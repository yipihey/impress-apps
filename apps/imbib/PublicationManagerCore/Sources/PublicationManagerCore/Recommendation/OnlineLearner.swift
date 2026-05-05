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
    /// Per-entry decay: each negative affinity is decayed by 0.95 per week of inactivity
    /// since the profile was last updated. This prevents old dismissals from permanently
    /// affecting rankings, and unlike the old approach, it works for active users too.
    ///
    /// Called periodically (e.g., on app launch).
    public func applyDecay() async {
        let decayDays = await settingsStore.negativePrefDecayDays()
        let decayPerWeek = 0.95  // 5% decay per week of inactivity

        await MainActor.run {
            var profile = getOrCreateProfile()

            // Calculate weeks since last update
            let daysSinceUpdate = Calendar.current.dateComponents(
                [.day], from: profile.lastUpdated, to: Date()
            ).day ?? 0

            // Only apply if at least 1 week has passed since last decay
            guard daysSinceUpdate >= 7 else { return }

            let weeksSinceUpdate = Double(daysSinceUpdate) / 7.0
            let decayFactor = pow(decayPerWeek, weeksSinceUpdate)

            var decayCount = 0
            let threshold = 0.01  // Remove entries that have decayed to near-zero

            // Decay negative author affinities
            for (key, value) in profile.authorAffinities where value < 0 {
                let decayed = value * decayFactor
                if abs(decayed) < threshold {
                    profile.authorAffinities.removeValue(forKey: key)
                } else {
                    profile.authorAffinities[key] = decayed
                }
                decayCount += 1
            }

            // Decay negative venue affinities
            for (key, value) in profile.venueAffinities where value < 0 {
                let decayed = value * decayFactor
                if abs(decayed) < threshold {
                    profile.venueAffinities.removeValue(forKey: key)
                } else {
                    profile.venueAffinities[key] = decayed
                }
                decayCount += 1
            }

            // Decay negative topic affinities
            for (key, value) in profile.topicAffinities where value < 0 {
                let decayed = value * decayFactor
                if abs(decayed) < threshold {
                    profile.topicAffinities.removeValue(forKey: key)
                } else {
                    profile.topicAffinities[key] = decayed
                }
                decayCount += 1
            }

            guard decayCount > 0 else { return }

            profile.lastUpdated = Date()
            saveProfile(profile)

            Logger.recommendation.info("Applied negative preference decay to \(decayCount) entries (factor: \(String(format: "%.3f", decayFactor)))")
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
