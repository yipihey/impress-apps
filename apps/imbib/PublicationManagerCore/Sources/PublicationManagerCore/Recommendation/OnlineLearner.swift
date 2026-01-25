//
//  OnlineLearner.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData
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

    private let persistenceController: PersistenceController
    private let settingsStore = RecommendationSettingsStore.shared

    // MARK: - Initialization

    private init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController

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

    // MARK: - Training

    /// Update profile based on a training event.
    public func train(on event: TrainingEvent) async {
        await MainActor.run {
            guard let profile = getOrCreateGlobalProfile() else {
                Logger.recommendation.error("Failed to get profile for training")
                return
            }

            let multiplier = event.action.learningMultiplier * learningRate

            // Apply weight deltas from the event
            for (key, baseDelta) in event.weightDeltas {
                let delta = baseDelta * multiplier

                // Parse the key to determine which affinity to update
                if key.hasPrefix("author:") {
                    let author = String(key.dropFirst("author:".count))
                    updateAffinity(profile: profile, type: .author, key: author, delta: delta)
                } else if key.hasPrefix("venue:") {
                    let venue = String(key.dropFirst("venue:".count))
                    updateAffinity(profile: profile, type: .venue, key: venue, delta: delta)
                } else if key.hasPrefix("topic:") {
                    let topic = String(key.dropFirst("topic:".count))
                    updateAffinity(profile: profile, type: .topic, key: topic, delta: delta)
                } else if key.hasPrefix("category:") {
                    let category = String(key.dropFirst("category:".count))
                    updateAffinity(profile: profile, type: .topic, key: category, delta: delta)
                }
            }

            profile.lastUpdated = Date()
            persistenceController.save()

            Logger.recommendation.debug("Applied training for: \(event.action.rawValue)")
        }

        // Invalidate recommendation cache
        await RecommendationEngine.shared.invalidateCache()
    }

    /// Reverse the effects of a training event (undo).
    public func undoTraining(for event: TrainingEvent) async {
        await MainActor.run {
            guard let profile = getOrCreateGlobalProfile() else { return }

            let multiplier = event.action.learningMultiplier * learningRate

            // Reverse the weight deltas
            for (key, baseDelta) in event.weightDeltas {
                let delta = -baseDelta * multiplier  // Negative to reverse

                if key.hasPrefix("author:") {
                    let author = String(key.dropFirst("author:".count))
                    updateAffinity(profile: profile, type: .author, key: author, delta: delta)
                } else if key.hasPrefix("venue:") {
                    let venue = String(key.dropFirst("venue:".count))
                    updateAffinity(profile: profile, type: .venue, key: venue, delta: delta)
                } else if key.hasPrefix("topic:") {
                    let topic = String(key.dropFirst("topic:".count))
                    updateAffinity(profile: profile, type: .topic, key: topic, delta: delta)
                } else if key.hasPrefix("category:") {
                    let category = String(key.dropFirst("category:".count))
                    updateAffinity(profile: profile, type: .topic, key: category, delta: delta)
                }
            }

            profile.lastUpdated = Date()
            persistenceController.save()

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

    // Note: This must be nonisolated because it's called from within MainActor.run
    // It only operates on the passed-in objects, not actor state.
    nonisolated private func updateAffinity(
        profile: CDRecommendationProfile,
        type: AffinityType,
        key: String,
        delta: Double
    ) {
        switch type {
        case .author:
            var affinities = profile.authorAffinities
            let current = affinities[key] ?? 0.0
            let new = clamp(current + delta, min: -maxAffinityMagnitude, max: maxAffinityMagnitude)
            affinities[key] = new
            profile.authorAffinities = affinities

        case .venue:
            var affinities = profile.venueAffinities
            let current = affinities[key] ?? 0.0
            let new = clamp(current + delta, min: -maxAffinityMagnitude, max: maxAffinityMagnitude)
            affinities[key] = new
            profile.venueAffinities = affinities

        case .topic:
            var affinities = profile.topicAffinities
            let current = affinities[key] ?? 0.0
            let new = clamp(current + delta, min: -maxAffinityMagnitude, max: maxAffinityMagnitude)
            affinities[key] = new
            profile.topicAffinities = affinities
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
            guard let profile = getOrCreateGlobalProfile() else { return }

            let cutoffDate = Calendar.current.date(byAdding: .day, value: -decayDays, to: Date()) ?? Date()

            // Only apply decay if profile is old enough
            guard profile.lastUpdated < cutoffDate else { return }

            // Decay negative author affinities
            var authorAffinities = profile.authorAffinities
            for (key, value) in authorAffinities where value < 0 {
                authorAffinities[key] = value * decayFactor
            }
            profile.authorAffinities = authorAffinities

            // Decay negative venue affinities
            var venueAffinities = profile.venueAffinities
            for (key, value) in venueAffinities where value < 0 {
                venueAffinities[key] = value * decayFactor
            }
            profile.venueAffinities = venueAffinities

            // Decay negative topic affinities
            var topicAffinities = profile.topicAffinities
            for (key, value) in topicAffinities where value < 0 {
                topicAffinities[key] = value * decayFactor
            }
            profile.topicAffinities = topicAffinities

            profile.lastUpdated = Date()
            persistenceController.save()

            Logger.recommendation.info("Applied negative preference decay")
        }

        await RecommendationEngine.shared.invalidateCache()
    }

    /// Clean up very small affinities (noise reduction).
    public func pruneSmallAffinities(threshold: Double = 0.01) async {
        await MainActor.run {
            guard let profile = getOrCreateGlobalProfile() else { return }

            // Prune author affinities
            var authorAffinities = profile.authorAffinities
            authorAffinities = authorAffinities.filter { abs($0.value) >= threshold }
            profile.authorAffinities = authorAffinities

            // Prune venue affinities
            var venueAffinities = profile.venueAffinities
            venueAffinities = venueAffinities.filter { abs($0.value) >= threshold }
            profile.venueAffinities = venueAffinities

            // Prune topic affinities
            var topicAffinities = profile.topicAffinities
            topicAffinities = topicAffinities.filter { abs($0.value) >= threshold }
            profile.topicAffinities = topicAffinities

            persistenceController.save()

            Logger.recommendation.debug("Pruned small affinities below threshold \(threshold)")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func getOrCreateGlobalProfile() -> CDRecommendationProfile? {
        let context = persistenceController.viewContext
        let request = NSFetchRequest<CDRecommendationProfile>(entityName: "RecommendationProfile")
        request.predicate = NSPredicate(format: "library == nil")
        request.fetchLimit = 1

        if let existing = try? context.fetch(request).first {
            return existing
        }

        // Create new profile
        let profile = CDRecommendationProfile(context: context)
        profile.id = UUID()
        profile.lastUpdated = Date()
        persistenceController.save()

        Logger.recommendation.info("Created new global recommendation profile")
        return profile
    }

    nonisolated private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        return Swift.min(Swift.max(value, min), max)
    }
}
