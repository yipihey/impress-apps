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
    private var cachedRationale: [UUID: (InboxScoringRationale, Date)] = [:]
    private let settingsStore = RecommendationSettingsStore.shared
    private let embeddingService = EmbeddingService.shared

    // MARK: - Initialization

    private init() {
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

        let profile = await getRecommendationProfile()
        let weights = await settingsStore.allWeights()

        guard let pubDetail = await withStore({ $0.getPublicationDetail(id: publicationID) }) else {
            return RecommendationScore(total: 0, breakdown: [:], explanation: "Publication not found")
        }

        let libraryPubs = await getDefaultLibraryPublications()

        var rawFeatures = await MainActor.run {
            FeatureExtractor.extract(from: pubDetail, profile: profile, libraryPublications: libraryPubs)
        }

        // Add semantic similarity if weight > 0 and index exists
        let aiWeight = weights[.aiSimilarity] ?? FeatureType.aiSimilarity.defaultWeight
        if aiWeight > 0 {
            let hasIndex = await embeddingService.hasIndex
            if hasIndex {
                let similarityScore = await embeddingService.similarityScore(for: publicationID)
                rawFeatures[.aiSimilarity] = similarityScore
            }
        }

        let score = computeScore(rawFeatures: rawFeatures, weights: weights, publication: pubDetail)

        cachedRanking[publicationID] = score
        return score
    }

    /// Get detailed score breakdown for UI display.
    public func scoreBreakdown(_ publicationID: UUID) async -> ScoreBreakdown {
        let profile = await getRecommendationProfile()

        guard let pubDetail = await withStore({ $0.getPublicationDetail(id: publicationID) }) else {
            return ScoreBreakdown(total: 0, components: [])
        }

        let libraryPubs = await getDefaultLibraryPublications()
        var rawFeatures = await MainActor.run {
            FeatureExtractor.extract(from: pubDetail, profile: profile, libraryPublications: libraryPubs)
        }

        // Add semantic similarity if available
        let hasIndex = await embeddingService.hasIndex
        if hasIndex {
            let similarityScore = await embeddingService.similarityScore(for: publicationID)
            rawFeatures[.aiSimilarity] = similarityScore
        }

        let weights = await settingsStore.allWeights()

        var components: [ScoreComponent] = []
        var total = 0.0

        for feature in FeatureType.allCases {
            let rawValue = rawFeatures[feature] ?? 0.0
            let weight = weights[feature] ?? feature.defaultWeight
            let contribution = rawValue * weight
            total += contribution

            if abs(contribution) > 0.001 {
                let detail = contextDetail(for: feature, publication: pubDetail, profile: profile, libraryPublications: libraryPubs)
                components.append(ScoreComponent(
                    feature: feature,
                    rawValue: rawValue,
                    weight: weight,
                    detail: detail
                ))
            }
        }

        components.sort { abs($0.contribution) > abs($1.contribution) }

        return ScoreBreakdown(total: total, components: components)
    }

    // MARK: - Batch Ranking

    /// Rank publications for Inbox display.
    public func rank(_ publicationIDs: [UUID]) async -> [RankedPublication] {
        let enabled = await settingsStore.isEnabled()
        guard enabled else {
            return publicationIDs.map { id in
                RankedPublication(
                    publicationID: id,
                    score: RecommendationScore(total: 0, breakdown: [:], explanation: "Ranking disabled"),
                    isSerendipitySlot: false
                )
            }
        }

        var scoredPubs: [(UUID, RecommendationScore)] = []
        for pubID in publicationIDs {
            let pubScore = await score(pubID)
            scoredPubs.append((pubID, pubScore))
        }

        scoredPubs.sort { $0.1.total > $1.1.total }

        let serendipityFrequency = await settingsStore.serendipityFrequency()
        var result: [RankedPublication] = []
        var serendipityPool = findSerendipityCandidatesFromIDs(from: scoredPubs)
        var serendipityUsed: Set<UUID> = []
        var nextSerendipityIndex = serendipityFrequency

        for (index, (pubID, pubScore)) in scoredPubs.enumerated() {
            // Insert serendipity slot at regular intervals
            if index == nextSerendipityIndex && !serendipityPool.isEmpty {
                let serendipityItem = serendipityPool.removeFirst()
                serendipityUsed.insert(serendipityItem.0)
                let serendipityScore = RecommendationScore(
                    total: serendipityItem.1.total,
                    breakdown: serendipityItem.1.breakdown,
                    explanation: "Discovery: new area for you",
                    isSerendipitySlot: true,
                    topReasons: ["Discovery: outside your usual reading"]
                )
                result.append(RankedPublication(
                    publicationID: serendipityItem.0,
                    score: serendipityScore,
                    isSerendipitySlot: true
                ))
                nextSerendipityIndex += serendipityFrequency + 1
            }

            // Skip if this pub was used as serendipity
            if serendipityUsed.contains(pubID) { continue }

            result.append(RankedPublication(
                publicationID: pubID,
                score: pubScore,
                isSerendipitySlot: false
            ))
        }

        lastRankDate = Date()
        Logger.recommendation.debug("Ranked \(publicationIDs.count) publications")

        return result
    }

    /// Find serendipity candidates using raw feature values for novelty.
    /// Select papers that are unfamiliar but recent — true discovery, not just trending.
    private func findSerendipityCandidatesFromIDs(
        from scoredPubs: [(UUID, RecommendationScore)]
    ) -> [(UUID, RecommendationScore)] {
        return scoredPubs.filter { _, score in
            // Use raw contributions (not weighted) to find truly unfamiliar papers
            let authorAffinity = score.breakdown[.authorAffinity] ?? 0
            let topicMatch = score.breakdown[.topicMatch] ?? 0
            let recency = score.breakdown[.recency] ?? 0

            // Unfamiliar but recent
            return authorAffinity < 0.1 && topicMatch < 0.1 && recency > 0.1
        }
        .shuffled()
        .prefix(10)
        .map { ($0, $1) }
    }

    // MARK: - Score Computation (shared by score() and scoreBreakdown())

    private func computeScore(
        rawFeatures: [FeatureType: Double],
        weights: [FeatureType: Double],
        publication: PublicationModel? = nil
    ) -> RecommendationScore {
        var breakdown: [FeatureType: Double] = [:]
        var total = 0.0

        for feature in FeatureType.allCases {
            let rawValue = rawFeatures[feature] ?? 0.0
            let weight = weights[feature] ?? feature.defaultWeight
            let contribution = rawValue * weight
            breakdown[feature] = contribution
            total += contribution
        }

        let topReasons = generateTopReasons(breakdown: breakdown)
        let explanation = topReasons.isEmpty ? "No strong signals" : topReasons.prefix(2).joined(separator: " · ")

        return RecommendationScore(
            total: total,
            breakdown: breakdown,
            explanation: explanation,
            topReasons: topReasons
        )
    }

    /// Generate human-readable top reasons from score breakdown.
    private func generateTopReasons(breakdown: [FeatureType: Double]) -> [String] {
        let significant = breakdown
            .filter { !$0.key.isMuteFilter && $0.value > 0.05 }
            .sorted { $0.value > $1.value }

        return significant.prefix(3).map { feature, _ in
            feature.displayName.lowercased()
        }
    }

    /// Generate context-specific detail for a feature in the breakdown view.
    private func contextDetail(
        for feature: FeatureType,
        publication: PublicationModel,
        profile: RecommendationProfile?,
        libraryPublications: [PublicationRowData]
    ) -> String? {
        switch feature {
        case .authorAffinity:
            guard let profile = profile else { return nil }
            let matchingAuthors = publication.authors.filter {
                abs(profile.authorAffinity(for: $0.familyName)) > 0.1
            }
            if matchingAuthors.isEmpty { return nil }
            return matchingAuthors.prefix(3).map(\.familyName).joined(separator: ", ")

        case .topicMatch:
            guard let profile = profile else { return nil }
            let keywords = FeatureExtractor.extractKeywords(from: publication.title)
            let matchingTopics = keywords.filter { profile.topicAffinity(for: $0) > 0.1 }
            if matchingTopics.isEmpty { return nil }
            return matchingTopics.prefix(3).joined(separator: ", ")

        case .venueAffinity:
            return publication.journal

        case .coauthorNetwork:
            return nil // Would need co-author lookup

        case .recency:
            if let year = publication.year { return "Published \(year)" }
            return nil

        case .citationVelocity:
            let count = publication.citationCount
            if count > 0 { return "\(count) citations" }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Embedding Index Management

    @discardableResult
    public func buildEmbeddingIndex(from libraryID: UUID) async -> Int {
        let count = await embeddingService.buildIndex(from: libraryID)
        await invalidateCache()
        Logger.recommendation.info("Built embedding index with \(count) publications")
        return count
    }

    @discardableResult
    public func buildEmbeddingIndex(from libraryIDs: [UUID]) async -> Int {
        let count = await embeddingService.buildIndex(from: libraryIDs)
        await invalidateCache()
        Logger.recommendation.info("Built embedding index with \(count) publications from \(libraryIDs.count) libraries")
        return count
    }

    public var isEmbeddingIndexReady: Bool {
        get async {
            await embeddingService.hasIndex
        }
    }

    // MARK: - "For You" Recommendations

    public func forYouRecommendations(
        candidateIDs: [UUID],
        recentlyReadIDs: Set<UUID>,
        limit: Int = 10
    ) async -> [ForYouRecommendation] {
        guard !candidateIDs.isEmpty else { return [] }

        var recommendations: [ForYouRecommendation] = []
        var scored: [(UUID, Double, String)] = []

        for candidateID in candidateIDs {
            if recentlyReadIDs.contains(candidateID) { continue }

            let baseScore = await score(candidateID)

            var similarityBoost = 0.0
            var reason = baseScore.explanation

            if !recentlyReadIDs.isEmpty {
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

        scored.sort { $0.1 > $1.1 }

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

    public func forYouFromLibrary(
        _ libraryID: UUID,
        limit: Int = 10
    ) async -> [ForYouRecommendation] {
        let allPubs = await withStore({ $0.queryPublications(parentId: libraryID) })

        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        let recentlyReadIDs = Set(allPubs
            .filter { $0.isRead && $0.dateModified > thirtyDaysAgo }
            .map(\.id))

        let unreadIDs = allPubs.filter { !$0.isRead }.map(\.id)

        return await forYouRecommendations(
            candidateIDs: unreadIDs,
            recentlyReadIDs: recentlyReadIDs,
            limit: limit
        )
    }

    // MARK: - Inbox Scoring Rationale (Apple Intelligence)

    @available(macOS 26, iOS 26, *)
    public func rationale(for publicationID: UUID) async -> InboxScoringRationale? {
        if let (cached, ts) = cachedRationale[publicationID],
           Date().timeIntervalSince(ts) < 300 {
            return cached
        }

        let breakdown = await scoreBreakdown(publicationID)
        let topFeatures = breakdown.components
            .filter { $0.isPositiveContribution }
            .prefix(3)
            .map { (name: $0.feature.displayName, contribution: $0.contribution) }

        guard !topFeatures.isEmpty else { return nil }

        let profile = await getRecommendationProfile()
        let topTopics = profile?.topicAffinities
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
            ?? []
        let topicContext = topTopics.isEmpty
            ? "general research"
            : topTopics.joined(separator: ", ")

        guard let title = await withStore({ $0.getPublication(id: publicationID)?.title }) else {
            return nil
        }

        let fmService = FoundationModelsService.shared
        guard let rationale = await fmService.explainRecommendation(
            title: title,
            topFeatures: topFeatures,
            topicContext: topicContext
        ) else { return nil }

        cachedRationale[publicationID] = (rationale, Date())
        return rationale
    }

    // MARK: - Cache Management

    public func invalidateCache() async {
        cachedRanking.removeAll()
        cachedRationale.removeAll()
        lastRankDate = nil
        await embeddingService.invalidateCache()
        Logger.recommendation.debug("Recommendation cache invalidated")
    }

    public func invalidateCache(for publicationID: UUID) async {
        cachedRanking.removeValue(forKey: publicationID)
        cachedRationale.removeValue(forKey: publicationID)
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
