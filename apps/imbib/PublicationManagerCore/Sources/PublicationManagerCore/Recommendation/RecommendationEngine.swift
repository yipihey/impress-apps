//
//  RecommendationEngine.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
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

    // MARK: - Initialization

    private init() {
        // Observe training events to invalidate cache
        Task {
            await setupNotificationObservers()
        }
    }

    private func setupNotificationObservers() async {
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

    // MARK: - Store Access Helper

    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Single Publication Scoring

    /// Score a single publication by ID.
    public func score(_ publicationID: UUID) async -> RecommendationScore {
        // Check cache
        if let cached = cachedRanking[publicationID],
           let lastRank = lastRankDate,
           Date().timeIntervalSince(lastRank) < 300 {  // 5 minute cache
            return cached
        }

        // Compute fresh score
        let profile = await getRecommendationProfile()
        let settings = await settingsStore.settings()
        let weights = await settingsStore.allWeights()
        let engineType = settings.engineType

        // Get publication detail for feature extraction
        guard let pubDetail = await withStore({ $0.getPublicationDetail(id: publicationID) }) else {
            return RecommendationScore(total: 0, breakdown: [:], explanation: "Publication not found")
        }

        // Get default library publications for context
        let libraryPubs = await getDefaultLibraryPublications()

        var rawFeatures = await MainActor.run {
            FeatureExtractor.extract(from: pubDetail, profile: profile, libraryPublications: libraryPubs)
        }

        // Add semantic similarity if engine type requires it
        if engineType.requiresEmbeddings {
            let hasIndex = await embeddingService.hasIndex
            if hasIndex {
                let similarityScore = await embeddingService.similarityScore(for: publicationID)
                rawFeatures[.librarySimilarity] = similarityScore
            }
        }

        let score = computeScore(rawFeatures: rawFeatures, weights: weights, settings: settings, engineType: engineType)

        // Cache result
        cachedRanking[publicationID] = score

        return score
    }

    /// Get detailed score breakdown for UI display.
    public func scoreBreakdown(_ publicationID: UUID) async -> ScoreBreakdown {
        let profile = await getRecommendationProfile()
        let settings = await settingsStore.settings()
        let engineType = settings.engineType

        guard let pubDetail = await withStore({ $0.getPublicationDetail(id: publicationID) }) else {
            return ScoreBreakdown(total: 0, components: [])
        }

        let libraryPubs = await getDefaultLibraryPublications()
        var rawFeatures = await MainActor.run {
            FeatureExtractor.extract(from: pubDetail, profile: profile, libraryPublications: libraryPubs)
        }

        // Add semantic similarity if engine type requires it
        if engineType.requiresEmbeddings {
            let hasIndex = await embeddingService.hasIndex
            if hasIndex {
                let similarityScore = await embeddingService.similarityScore(for: publicationID)
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
    public func rank(_ publicationIDs: [UUID]) async -> [RankedPublication] {
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

        // Score all publications
        var scoredPubs: [(UUID, RecommendationScore)] = []
        for pubID in publicationIDs {
            let pubScore = await score(pubID)
            scoredPubs.append((pubID, pubScore))
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

        Logger.recommendation.debug("Ranked \(publicationIDs.count) publications")

        return result
    }

    /// Find serendipity candidates: high citation velocity but low topic match.
    private func findSerendipityCandidatesFromIDs(
        from scoredPubs: [(UUID, RecommendationScore)]
    ) -> [(UUID, RecommendationScore)] {
        return scoredPubs.filter { _, score in
            let citationVelocity = score.breakdown[.fieldCitationVelocity] ?? 0
            let authorStarred = score.breakdown[.authorStarred] ?? 0
            let topicMatch = score.breakdown[.readingTimeTopic] ?? 0

            return citationVelocity > 0.3 && authorStarred < 0.2 && topicMatch < 0.2
        }
        .shuffled()
        .prefix(10)
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

            switch engineType {
            case .classic:
                if feature == .librarySimilarity {
                    weight = 0.0
                }
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
            breakdown[feature] = contribution
            total += contribution
        }

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
    @discardableResult
    public func buildEmbeddingIndex(from libraryID: UUID) async -> Int {
        let count = await embeddingService.buildIndex(from: libraryID)
        await invalidateCache()
        Logger.recommendation.info("Built embedding index with \(count) publications")
        return count
    }

    /// Build the embedding index from multiple libraries.
    @discardableResult
    public func buildEmbeddingIndex(from libraryIDs: [UUID]) async -> Int {
        let count = await embeddingService.buildIndex(from: libraryIDs)
        await invalidateCache()
        Logger.recommendation.info("Built embedding index with \(count) publications from \(libraryIDs.count) libraries")
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

    // MARK: - "For You" Recommendations

    /// Generate personalized "For You" recommendations.
    public func forYouRecommendations(
        candidateIDs: [UUID],
        recentlyReadIDs: Set<UUID>,
        limit: Int = 10
    ) async -> [ForYouRecommendation] {
        guard !candidateIDs.isEmpty else { return [] }

        let settings = await settingsStore.settings()
        let engineType = settings.engineType
        var recommendations: [ForYouRecommendation] = []

        // Score each candidate
        var scored: [(UUID, Double, String)] = []

        for candidateID in candidateIDs {
            // Skip papers already in recently read
            if recentlyReadIDs.contains(candidateID) { continue }

            // Compute base score
            let baseScore = await score(candidateID)

            // Compute similarity to recently read papers (if semantic mode)
            var similarityBoost = 0.0
            var reason = baseScore.explanation

            if engineType.requiresEmbeddings && !recentlyReadIDs.isEmpty {
                let hasIndex = await embeddingService.hasIndex
                if hasIndex {
                    let simScore = await embeddingService.similarityScore(for: candidateID)
                    similarityBoost = simScore * 0.5
                    if simScore > 0.5 {
                        reason = "Related to your recent reading"
                    }
                }
            }

            let finalScore = baseScore.total + similarityBoost
            scored.append((candidateID, finalScore, reason))
        }

        // Sort by score descending
        scored.sort { $0.1 > $1.1 }

        // Take top recommendations
        for (candidateID, candidateScore, reason) in scored {
            guard recommendations.count < limit else { break }

            recommendations.append(ForYouRecommendation(
                publicationID: candidateID,
                score: candidateScore,
                reason: reason
            ))
        }

        Logger.recommendation.infoCapture("Generated \(recommendations.count) 'For You' recommendations", category: "recommendation")

        return recommendations
    }

    /// Get "For You" recommendations based on the user's library.
    public func forYouFromLibrary(
        _ libraryID: UUID,
        limit: Int = 10
    ) async -> [ForYouRecommendation] {
        // Get all publications in the library
        let allPubs = await withStore({ $0.queryPublications(parentId: libraryID) })

        // Recently read: read in last 30 days
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        let recentlyReadIDs = Set(allPubs
            .filter { $0.isRead && $0.dateModified > thirtyDaysAgo }
            .map(\.id))

        // Unread papers
        let unreadIDs = allPubs.filter { !$0.isRead }.map(\.id)

        return await forYouRecommendations(
            candidateIDs: unreadIDs,
            recentlyReadIDs: recentlyReadIDs,
            limit: limit
        )
    }

    // MARK: - Cache Management

    public func invalidateCache() async {
        cachedRanking.removeAll()
        lastRankDate = nil
        await embeddingService.invalidateCache()
        Logger.recommendation.debug("Recommendation cache invalidated")
    }

    public func invalidateCache(for publicationID: UUID) async {
        cachedRanking.removeValue(forKey: publicationID)
    }

    // MARK: - Profile Access

    private func getRecommendationProfile() async -> RecommendationProfile? {
        guard let defaultLib = await withStore({ $0.getDefaultLibrary() }) else { return nil }
        guard let json = await withStore({ $0.getRecommendationProfile(libraryId: defaultLib.id) }) else { return nil }
        return RecommendationProfile.fromJSON(json)
    }

    private func getDefaultLibraryPublications() async -> [PublicationRowData] {
        guard let defaultLib = await withStore({ $0.getDefaultLibrary() }) else { return [] }
        return await withStore({ $0.queryPublications(parentId: defaultLib.id) })
    }
}

// MARK: - Recommendation Profile (replaces CDRecommendationProfile)

/// In-memory profile structure backed by RustStoreAdapter JSON storage.
public struct RecommendationProfile: Codable, Sendable {
    public var authorAffinities: [String: Double]
    public var venueAffinities: [String: Double]
    public var topicAffinities: [String: Double]
    public var trainingEvents: [TrainingEvent]
    public var lastUpdated: Date

    public var isColdStart: Bool {
        authorAffinities.isEmpty && venueAffinities.isEmpty && topicAffinities.isEmpty
    }

    public init() {
        self.authorAffinities = [:]
        self.venueAffinities = [:]
        self.topicAffinities = [:]
        self.trainingEvents = []
        self.lastUpdated = Date()
    }

    public func authorAffinity(for name: String) -> Double {
        authorAffinities[name.lowercased()] ?? 0
    }

    public func venueAffinity(for venue: String) -> Double {
        venueAffinities[venue.lowercased()] ?? 0
    }

    public func topicAffinity(for topic: String) -> Double {
        topicAffinities[topic.lowercased()] ?? 0
    }

    public func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func fromJSON(_ json: String) -> RecommendationProfile? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RecommendationProfile.self, from: data)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when recommendation ranking is updated
    public static let recommendationRankingDidUpdate = Notification.Name("recommendationRankingDidUpdate")
}
