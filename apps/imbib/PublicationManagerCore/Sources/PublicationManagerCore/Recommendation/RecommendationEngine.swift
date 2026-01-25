//
//  RecommendationEngine.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData
import OSLog

// MARK: - Recommendation Engine (ADR-020)

/// Scores and ranks publications for Inbox and Exploration views.
///
/// Uses a transparent linear weighted sum: `score = Σ (weight_i × feature_i)`
///
/// Key principles:
/// - All weights are user-adjustable
/// - Score breakdown is visible for every paper ("Why this ranking?")
/// - Serendipity slots prevent filter bubble
/// - Cache invalidation on training events
public actor RecommendationEngine {

    // MARK: - Singleton

    public static let shared = RecommendationEngine()

    // MARK: - Properties

    private var lastRankDate: Date?
    private var cachedRanking: [UUID: RecommendationScore] = [:]
    private let settingsStore = RecommendationSettingsStore.shared
    private let embeddingService = EmbeddingService.shared
    private let persistenceController: PersistenceController

    // MARK: - Initialization

    private init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController

        // Observe training events to invalidate cache
        Task {
            await setupNotificationObservers()
        }
    }

    private func setupNotificationObservers() async {
        // Note: NotificationCenter observation setup happens on main actor
        await MainActor.run {
            NotificationCenter.default.addObserver(
                forName: .recommendationTrainingEventRecorded,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task {
                    await self?.invalidateCache()
                }
            }
        }
    }

    // MARK: - Single Publication Scoring

    /// Score a single publication.
    ///
    /// Uses cached score if available and recent enough.
    /// The scoring approach depends on the selected engine type:
    /// - Classic: Uses only rule-based features
    /// - Semantic: Uses embedding similarity from ANN index
    /// - Hybrid: Combines both approaches
    public func score(_ publication: CDPublication) async -> RecommendationScore {
        // Capture publication ID on main actor since CDPublication isn't thread-safe
        let publicationID = await MainActor.run { publication.id }

        // Check cache
        if let cached = cachedRanking[publicationID],
           let lastRank = lastRankDate,
           Date().timeIntervalSince(lastRank) < 300 {  // 5 minute cache
            return cached
        }

        // Compute fresh score
        let profile = await getGlobalProfile()
        let library = await getDefaultLibrary()
        let settings = await settingsStore.settings()
        let weights = await settingsStore.allWeights()
        let engineType = settings.engineType

        // Run feature extraction on main actor since CDPublication isn't thread-safe
        var rawFeatures = await MainActor.run {
            FeatureExtractor.extract(from: publication, profile: profile, library: library)
        }

        // Add semantic similarity if engine type requires it
        if engineType.requiresEmbeddings {
            let hasIndex = await embeddingService.hasIndex
            if hasIndex {
                let similarityScore = await embeddingService.similarityScore(for: publication)
                rawFeatures[.librarySimilarity] = similarityScore
            }
        }

        let score = computeScore(rawFeatures: rawFeatures, weights: weights, settings: settings, engineType: engineType)

        // Cache result
        cachedRanking[publicationID] = score

        return score
    }

    /// Get detailed score breakdown for UI display.
    public func scoreBreakdown(_ publication: CDPublication) async -> ScoreBreakdown {
        let profile = await getGlobalProfile()
        let library = await getDefaultLibrary()
        let settings = await settingsStore.settings()
        let engineType = settings.engineType

        // Run feature extraction on main actor since CDPublication isn't thread-safe
        var rawFeatures = await MainActor.run {
            FeatureExtractor.extract(from: publication, profile: profile, library: library)
        }

        // Add semantic similarity if engine type requires it
        if engineType.requiresEmbeddings {
            let hasIndex = await embeddingService.hasIndex
            if hasIndex {
                let similarityScore = await embeddingService.similarityScore(for: publication)
                rawFeatures[.librarySimilarity] = similarityScore
            }
        }

        var components: [ScoreComponent] = []
        var total = 0.0

        for feature in FeatureType.allCases {
            let rawValue = rawFeatures[feature] ?? 0.0
            var weight = settings.weight(for: feature)

            // Adjust weight display based on engine type (matching computeScore)
            switch engineType {
            case .classic:
                if feature == .librarySimilarity { weight = 0.0 }
            case .semantic:
                if feature == .librarySimilarity {
                    weight = weight * 2.0
                } else if !feature.isNegativeFeature {
                    weight = weight * 0.5
                }
            case .hybrid:
                break
            }

            let contribution = rawValue * weight
            total += contribution

            // Only include non-zero contributions
            if abs(contribution) > 0.001 {
                components.append(ScoreComponent(
                    feature: feature,
                    rawValue: rawValue,
                    weight: weight
                ))
            }
        }

        // Sort by absolute contribution (most impactful first)
        components.sort { abs($0.contribution) > abs($1.contribution) }

        return ScoreBreakdown(total: total, components: components)
    }

    // MARK: - Batch Ranking

    /// Rank publications for Inbox display.
    ///
    /// Returns publications sorted by score, with serendipity slots inserted.
    public func rank(_ publications: [CDPublication]) async -> [RankedPublication] {
        // Extract publication IDs on main actor for thread safety
        let publicationIDs = await MainActor.run {
            publications.map { $0.id }
        }

        let enabled = await settingsStore.isEnabled()
        guard enabled else {
            // If disabled, return in original order
            return publicationIDs.map { id in
                RankedPublication(
                    publicationID: id,
                    score: RecommendationScore(total: 0, breakdown: [:], explanation: "Ranking disabled"),
                    isSerendipitySlot: false
                )
            }
        }

        // Score all publications (score() handles thread safety internally)
        var scoredPubs: [(UUID, RecommendationScore)] = []
        for (index, pub) in publications.enumerated() {
            let pubScore = await score(pub)
            scoredPubs.append((publicationIDs[index], pubScore))
        }

        // Sort by score (descending)
        scoredPubs.sort { $0.1.total > $1.1.total }

        // Insert serendipity slots
        let serendipityFrequency = await settingsStore.serendipityFrequency()
        var result: [RankedPublication] = []
        var serendipityPool = findSerendipityCandidatesFromIDs(from: scoredPubs)
        var nextSerendipityIndex = serendipityFrequency

        for (index, (pubID, pubScore)) in scoredPubs.enumerated() {
            // Insert serendipity slot at regular intervals
            if index == nextSerendipityIndex && !serendipityPool.isEmpty {
                let serendipityItem = serendipityPool.removeFirst()
                let serendipityScore = RecommendationScore(
                    total: serendipityItem.1.total,
                    breakdown: serendipityItem.1.breakdown,
                    explanation: "Serendipity: High potential discovery",
                    isSerendipitySlot: true
                )
                result.append(RankedPublication(
                    publicationID: serendipityItem.0,
                    score: serendipityScore,
                    isSerendipitySlot: true
                ))
                nextSerendipityIndex += serendipityFrequency + 1
            }

            // Skip if this pub was used as serendipity
            if serendipityPool.contains(where: { $0.0 == pubID }) {
                continue
            }

            result.append(RankedPublication(
                publicationID: pubID,
                score: pubScore,
                isSerendipitySlot: false
            ))
        }

        // Update cache timestamp
        lastRankDate = Date()

        Logger.recommendation.debug("Ranked \(publications.count) publications")

        return result
    }

    /// Find serendipity candidates: high citation velocity but low topic match.
    /// Uses UUIDs for thread safety.
    private func findSerendipityCandidatesFromIDs(
        from scoredPubs: [(UUID, RecommendationScore)]
    ) -> [(UUID, RecommendationScore)] {
        // Serendipity = high potential (citation velocity, recency) + low familiarity
        return scoredPubs.filter { _, score in
            let citationVelocity = score.breakdown[.fieldCitationVelocity] ?? 0
            let authorStarred = score.breakdown[.authorStarred] ?? 0
            let topicMatch = score.breakdown[.readingTimeTopic] ?? 0

            // High velocity/recency, low familiarity
            return citationVelocity > 0.3 && authorStarred < 0.2 && topicMatch < 0.2
        }
        .shuffled()  // Randomize to avoid always showing same papers
        .prefix(10)  // Limit pool size
        .map { ($0, $1) }
    }

    // MARK: - Score Computation

    private func computeScore(
        rawFeatures: [FeatureType: Double],
        weights: [FeatureType: Double],
        settings: RecommendationSettingsStore.Settings,
        engineType: RecommendationEngineType = .classic
    ) -> RecommendationScore {
        var breakdown: [FeatureType: Double] = [:]
        var total = 0.0

        for feature in FeatureType.allCases {
            let rawValue = rawFeatures[feature] ?? 0.0
            var weight = weights[feature] ?? feature.defaultWeight

            // Adjust weights based on engine type
            switch engineType {
            case .classic:
                // Classic mode: ignore librarySimilarity
                if feature == .librarySimilarity {
                    weight = 0.0
                }
            case .semantic:
                // Semantic mode: heavily weight librarySimilarity, reduce others
                if feature == .librarySimilarity {
                    weight = weight * 2.0  // Boost semantic similarity
                } else if !feature.isNegativeFeature {
                    weight = weight * 0.5  // Reduce other positive features
                }
            case .hybrid:
                // Hybrid: use weights as-is (balanced)
                break
            }

            let contribution = rawValue * weight
            breakdown[feature] = contribution
            total += contribution
        }

        // Generate explanation from top contributors
        let explanation = generateExplanation(breakdown: breakdown, engineType: engineType)

        return RecommendationScore(
            total: total,
            breakdown: breakdown,
            explanation: explanation
        )
    }

    private func generateExplanation(breakdown: [FeatureType: Double], engineType: RecommendationEngineType = .classic) -> String {
        let topPositive = breakdown
            .filter { $0.value > 0.1 }
            .sorted { $0.value > $1.value }
            .prefix(2)

        if topPositive.isEmpty {
            return "No strong signals"
        }

        var reasons = topPositive.map { $0.key.displayName }

        // Add engine type indicator for semantic/hybrid
        switch engineType {
        case .semantic:
            if breakdown[.librarySimilarity] ?? 0 > 0.1 {
                reasons = ["AI: " + reasons.joined(separator: ", ")]
            }
        case .hybrid:
            if breakdown[.librarySimilarity] ?? 0 > 0.3 {
                reasons.insert("AI-enhanced", at: 0)
            }
        case .classic:
            break
        }

        return reasons.joined(separator: ", ")
    }

    // MARK: - Embedding Index Management

    /// Build the embedding index for semantic/hybrid recommendation modes.
    ///
    /// Call this when switching to semantic or hybrid mode, or when the library changes.
    /// - Parameter library: The library to index
    /// - Returns: Number of publications indexed
    @discardableResult
    public func buildEmbeddingIndex(from library: CDLibrary) async -> Int {
        let count = await embeddingService.buildIndex(from: library)
        await invalidateCache()
        Logger.recommendation.info("Built embedding index with \(count) publications")
        return count
    }

    /// Build the embedding index from multiple libraries.
    ///
    /// Use this to index all libraries except system libraries like "Dismissed".
    /// - Parameter libraries: The libraries to index
    /// - Returns: Number of publications indexed
    @discardableResult
    public func buildEmbeddingIndex(from libraries: [CDLibrary]) async -> Int {
        let count = await embeddingService.buildIndex(from: libraries)
        await invalidateCache()
        Logger.recommendation.info("Built embedding index with \(count) publications from \(libraries.count) libraries")
        return count
    }

    /// Check if the embedding index is ready.
    public var isEmbeddingIndexReady: Bool {
        get async {
            await embeddingService.hasIndex
        }
    }

    /// Get the current engine type.
    public func currentEngineType() async -> RecommendationEngineType {
        let settings = await settingsStore.settings()
        return settings.engineType
    }

    // MARK: - Cache Management

    /// Invalidate the ranking cache.
    ///
    /// Called automatically when training events occur.
    public func invalidateCache() async {
        cachedRanking.removeAll()
        lastRankDate = nil
        await embeddingService.invalidateCache()
        Logger.recommendation.debug("Recommendation cache invalidated")
    }

    /// Clear cache for a specific publication.
    public func invalidateCache(for publicationID: UUID) async {
        cachedRanking.removeValue(forKey: publicationID)
    }

    // MARK: - Profile Access

    private func getGlobalProfile() async -> CDRecommendationProfile? {
        return await MainActor.run {
            let context = persistenceController.viewContext
            let request = NSFetchRequest<CDRecommendationProfile>(entityName: "RecommendationProfile")
            request.predicate = NSPredicate(format: "library == nil")
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }

    private func getDefaultLibrary() async -> CDLibrary? {
        return await MainActor.run {
            let context = persistenceController.viewContext
            let request = NSFetchRequest<CDLibrary>(entityName: "Library")
            request.predicate = NSPredicate(format: "isDefault == YES")
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when recommendation ranking is updated
    public static let recommendationRankingDidUpdate = Notification.Name("recommendationRankingDidUpdate")
}
