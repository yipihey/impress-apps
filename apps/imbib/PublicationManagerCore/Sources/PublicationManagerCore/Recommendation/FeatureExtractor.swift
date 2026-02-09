//
//  FeatureExtractor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import OSLog

// MARK: - Feature Extractor (ADR-020)

/// Extracts feature values from publications for the recommendation engine.
///
/// Each feature is computed independently and returns a normalized value in [0, 1]
/// (or [-1, 0] for negative features like muted items).
public struct FeatureExtractor {

    // MARK: - Full Feature Extraction

    /// Extract all features for a publication.
    ///
    /// - Parameters:
    ///   - publication: The publication detail to score
    ///   - profile: The user's learned preferences
    ///   - libraryPublications: Publications in the library for context
    /// - Returns: Dictionary of feature type to raw value (0-1 range)
    @MainActor public static func extract(
        from publication: PublicationModel,
        profile: RecommendationProfile?,
        libraryPublications: [PublicationRowData]
    ) -> [FeatureType: Double] {
        var features: [FeatureType: Double] = [:]

        // Explicit signals
        features[.authorStarred] = authorStarredScore(publication, profile: profile)
        features[.collectionMatch] = collectionMatchScore(publication, profile: profile)
        features[.tagMatch] = tagMatchScore(publication, profile: profile)
        features[.mutedAuthor] = mutedAuthorPenalty(publication)
        features[.mutedCategory] = mutedCategoryPenalty(publication)
        features[.mutedVenue] = mutedVenuePenalty(publication)

        // Behavioral signals
        features[.saveRateAuthor] = saveRateAuthorScore(publication, profile: profile)
        features[.saveRateVenue] = saveRateVenueScore(publication, profile: profile)
        features[.dismissRateAuthor] = dismissRateAuthorPenalty(publication, profile: profile)
        features[.readingTimeTopic] = readingTimeTopicScore(publication, profile: profile)
        features[.pdfDownloadAuthor] = pdfDownloadAuthorScore(publication, profile: profile)

        // Content signals
        features[.citationOverlap] = citationOverlapScore(publication)
        features[.authorCoauthorship] = authorCoauthorshipScore(publication, libraryPublications: libraryPublications)
        features[.venueFrequency] = venueFrequencyScore(publication, libraryPublications: libraryPublications)
        features[.recency] = recencyScore(publication)
        features[.fieldCitationVelocity] = citationVelocityScore(publication)
        features[.smartSearchMatch] = 0.0  // Computed separately if needed

        // Semantic similarity computed asynchronously by EmbeddingService
        features[.librarySimilarity] = 0.0

        return features
    }

    /// Extract features from PublicationRowData (lightweight, for batch operations).
    @MainActor public static func extract(
        from row: PublicationRowData,
        profile: RecommendationProfile?,
        libraryPublications: [PublicationRowData]
    ) -> [FeatureType: Double] {
        var features: [FeatureType: Double] = [:]

        features[.authorStarred] = authorStarredScoreFromRow(row, profile: profile)
        features[.collectionMatch] = collectionMatchScoreFromRow(row, profile: profile)
        features[.tagMatch] = 0.0  // Simplified for row data
        features[.mutedAuthor] = mutedAuthorPenaltyFromRow(row)
        features[.mutedCategory] = mutedCategoryPenaltyFromRow(row)
        features[.mutedVenue] = mutedVenuePenaltyFromRow(row)

        features[.saveRateAuthor] = authorStarredScoreFromRow(row, profile: profile)
        features[.saveRateVenue] = saveRateVenueFromRow(row, profile: profile)
        features[.dismissRateAuthor] = dismissRateAuthorPenaltyFromRow(row, profile: profile)
        features[.readingTimeTopic] = readingTimeTopicScoreFromRow(row, profile: profile)
        features[.pdfDownloadAuthor] = authorStarredScoreFromRow(row, profile: profile) * 0.8

        features[.citationOverlap] = 0.0
        features[.authorCoauthorship] = authorCoauthorshipFromRow(row, libraryPublications: libraryPublications)
        features[.venueFrequency] = venueFrequencyFromRow(row, libraryPublications: libraryPublications)
        features[.recency] = recencyScoreFromRow(row)
        features[.fieldCitationVelocity] = citationVelocityFromRow(row)
        features[.smartSearchMatch] = 0.0
        features[.librarySimilarity] = 0.0

        return features
    }

    /// Extract features with a pre-computed similarity score.
    @MainActor public static func extractWithSimilarity(
        from publication: PublicationModel,
        profile: RecommendationProfile?,
        libraryPublications: [PublicationRowData],
        similarityScore: Double
    ) -> [FeatureType: Double] {
        var features = extract(from: publication, profile: profile, libraryPublications: libraryPublications)
        features[.librarySimilarity] = similarityScore
        return features
    }

    // MARK: - Explicit Signals (PublicationModel)

    public static func authorStarredScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        var maxAffinity = 0.0
        for author in publication.authors {
            let affinity = profile.authorAffinity(for: author.familyName)
            maxAffinity = max(maxAffinity, affinity)
        }

        return tanh(maxAffinity)
    }

    public static func collectionMatchScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        let titleKeywords = extractKeywords(from: publication.title)
        var topicScore = 0.0
        for keyword in titleKeywords {
            topicScore += profile.topicAffinity(for: keyword)
        }

        return tanh(topicScore / max(1.0, Double(titleKeywords.count)))
    }

    public static func tagMatchScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard !publication.tags.isEmpty, let profile = profile else {
            return 0.0
        }

        var totalAffinity = 0.0
        for tag in publication.tags {
            totalAffinity += profile.topicAffinity(for: tag.leaf)
        }

        return tanh(totalAffinity / Double(publication.tags.count))
    }

    @MainActor public static func mutedAuthorPenalty(_ publication: PublicationModel) -> Double {
        let mutedAuthors = fetchMutedItems(type: "author")
        for author in publication.authors {
            if mutedAuthors.contains(author.familyName.lowercased()) {
                return -1.0
            }
        }
        return 0.0
    }

    @MainActor public static func mutedCategoryPenalty(_ publication: PublicationModel) -> Double {
        let mutedCategories = fetchMutedItems(type: "arxivCategory")
        if let primaryClass = publication.fields["primaryclass"] {
            if mutedCategories.contains(primaryClass.lowercased()) {
                return -1.0
            }
        }
        return 0.0
    }

    @MainActor public static func mutedVenuePenalty(_ publication: PublicationModel) -> Double {
        let mutedVenues = fetchMutedItems(type: "venue")
        if let journal = publication.journal?.lowercased() {
            if mutedVenues.contains(journal) {
                return -1.0
            }
        }
        return 0.0
    }

    // MARK: - Behavioral Signals (PublicationModel)

    public static func saveRateAuthorScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        var maxAffinity = 0.0
        for author in publication.authors {
            let affinity = profile.authorAffinity(for: author.familyName)
            if affinity > 0 {
                maxAffinity = max(maxAffinity, affinity)
            }
        }

        return tanh(maxAffinity)
    }

    public static func saveRateVenueScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard let profile = profile,
              let journal = publication.journal else { return 0.0 }

        let affinity = profile.venueAffinity(for: journal)
        return affinity > 0 ? tanh(affinity) : 0.0
    }

    public static func dismissRateAuthorPenalty(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        var minAffinity = 0.0
        for author in publication.authors {
            let affinity = profile.authorAffinity(for: author.familyName)
            if affinity < 0 {
                minAffinity = min(minAffinity, affinity)
            }
        }

        return minAffinity < 0 ? tanh(minAffinity) : 0.0
    }

    public static func readingTimeTopicScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        let titleKeywords = extractKeywords(from: publication.title)
        var totalAffinity = 0.0

        for keyword in titleKeywords {
            let affinity = profile.topicAffinity(for: keyword)
            if affinity > 0 {
                totalAffinity += affinity
            }
        }

        return titleKeywords.isEmpty ? 0.0 : tanh(totalAffinity / Double(titleKeywords.count))
    }

    public static func pdfDownloadAuthorScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        return saveRateAuthorScore(publication, profile: profile) * 0.8
    }

    // MARK: - Content Signals (PublicationModel)

    public static func citationOverlapScore(_ publication: PublicationModel) -> Double {
        return 0.0
    }

    public static func authorCoauthorshipScore(
        _ publication: PublicationModel,
        libraryPublications: [PublicationRowData]
    ) -> Double {
        guard !libraryPublications.isEmpty else { return 0.0 }

        // Build set of author family names from library
        var libraryAuthors = Set<String>()
        for pub in libraryPublications {
            // Parse author string into family names
            for name in pub.authorString.components(separatedBy: ",") {
                let familyName = name.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first ?? ""
                if !familyName.isEmpty {
                    libraryAuthors.insert(familyName.lowercased())
                }
            }
        }

        var matchCount = 0
        for author in publication.authors {
            if libraryAuthors.contains(author.familyName.lowercased()) {
                matchCount += 1
            }
        }

        let authorCount = publication.authors.count
        return authorCount > 0 ? Double(matchCount) / Double(authorCount) : 0.0
    }

    public static func venueFrequencyScore(
        _ publication: PublicationModel,
        libraryPublications: [PublicationRowData]
    ) -> Double {
        guard let journal = publication.journal?.lowercased() else { return 0.0 }

        var venueCount = 0
        for pub in libraryPublications {
            if pub.venue?.lowercased() == journal {
                venueCount += 1
            }
        }

        return tanh(Double(venueCount) / 5.0)
    }

    public static func recencyScore(_ publication: PublicationModel) -> Double {
        guard let year = publication.year, year > 0 else { return 0.5 }

        let currentYear = Calendar.current.component(.year, from: Date())
        let age = currentYear - year

        return exp(-Double(age) / 2.0)
    }

    public static func citationVelocityScore(_ publication: PublicationModel) -> Double {
        let citationCount = publication.citationCount
        guard citationCount > 0 else { return 0.0 }

        guard let year = publication.year, year > 0 else { return 0.0 }

        let currentYear = Calendar.current.component(.year, from: Date())
        let age = max(1, currentYear - year)

        let velocity = Double(citationCount) / Double(age)

        return tanh(velocity / 10.0)
    }

    // MARK: - Row-based feature extractors (lightweight)

    private static func authorStarredScoreFromRow(_ row: PublicationRowData, profile: RecommendationProfile?) -> Double {
        guard let profile = profile else { return 0.0 }
        // Parse author string for family names
        var maxAffinity = 0.0
        for name in row.authorString.components(separatedBy: ",") {
            let familyName = name.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            let affinity = profile.authorAffinity(for: familyName)
            maxAffinity = max(maxAffinity, affinity)
        }
        return tanh(maxAffinity)
    }

    private static func collectionMatchScoreFromRow(_ row: PublicationRowData, profile: RecommendationProfile?) -> Double {
        guard let profile = profile else { return 0.0 }
        let titleKeywords = extractKeywords(from: row.title)
        var topicScore = 0.0
        for keyword in titleKeywords {
            topicScore += profile.topicAffinity(for: keyword)
        }
        return tanh(topicScore / max(1.0, Double(titleKeywords.count)))
    }

    @MainActor private static func mutedAuthorPenaltyFromRow(_ row: PublicationRowData) -> Double {
        let mutedAuthors = fetchMutedItems(type: "author")
        for name in row.authorString.components(separatedBy: ",") {
            let familyName = name.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            if mutedAuthors.contains(familyName.lowercased()) { return -1.0 }
        }
        return 0.0
    }

    @MainActor private static func mutedCategoryPenaltyFromRow(_ row: PublicationRowData) -> Double {
        let mutedCategories = fetchMutedItems(type: "arxivCategory")
        if let category = row.primaryCategory?.lowercased() {
            if mutedCategories.contains(category) { return -1.0 }
        }
        return 0.0
    }

    @MainActor private static func mutedVenuePenaltyFromRow(_ row: PublicationRowData) -> Double {
        let mutedVenues = fetchMutedItems(type: "venue")
        if let venue = row.venue?.lowercased() {
            if mutedVenues.contains(venue) { return -1.0 }
        }
        return 0.0
    }

    private static func saveRateVenueFromRow(_ row: PublicationRowData, profile: RecommendationProfile?) -> Double {
        guard let profile = profile, let venue = row.venue else { return 0.0 }
        let affinity = profile.venueAffinity(for: venue)
        return affinity > 0 ? tanh(affinity) : 0.0
    }

    private static func dismissRateAuthorPenaltyFromRow(_ row: PublicationRowData, profile: RecommendationProfile?) -> Double {
        guard let profile = profile else { return 0.0 }
        var minAffinity = 0.0
        for name in row.authorString.components(separatedBy: ",") {
            let familyName = name.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            let affinity = profile.authorAffinity(for: familyName)
            if affinity < 0 { minAffinity = min(minAffinity, affinity) }
        }
        return minAffinity < 0 ? tanh(minAffinity) : 0.0
    }

    private static func readingTimeTopicScoreFromRow(_ row: PublicationRowData, profile: RecommendationProfile?) -> Double {
        guard let profile = profile else { return 0.0 }
        let titleKeywords = extractKeywords(from: row.title)
        var totalAffinity = 0.0
        for keyword in titleKeywords {
            let affinity = profile.topicAffinity(for: keyword)
            if affinity > 0 { totalAffinity += affinity }
        }
        return titleKeywords.isEmpty ? 0.0 : tanh(totalAffinity / Double(titleKeywords.count))
    }

    private static func authorCoauthorshipFromRow(_ row: PublicationRowData, libraryPublications: [PublicationRowData]) -> Double {
        guard !libraryPublications.isEmpty else { return 0.0 }
        var libraryAuthors = Set<String>()
        for pub in libraryPublications {
            for name in pub.authorString.components(separatedBy: ",") {
                let familyName = name.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
                if !familyName.isEmpty { libraryAuthors.insert(familyName.lowercased()) }
            }
        }
        var matchCount = 0
        let authorNames = row.authorString.components(separatedBy: ",")
        for name in authorNames {
            let familyName = name.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            if libraryAuthors.contains(familyName.lowercased()) { matchCount += 1 }
        }
        return authorNames.isEmpty ? 0.0 : Double(matchCount) / Double(authorNames.count)
    }

    private static func venueFrequencyFromRow(_ row: PublicationRowData, libraryPublications: [PublicationRowData]) -> Double {
        guard let venue = row.venue?.lowercased() else { return 0.0 }
        var venueCount = 0
        for pub in libraryPublications {
            if pub.venue?.lowercased() == venue { venueCount += 1 }
        }
        return tanh(Double(venueCount) / 5.0)
    }

    private static func recencyScoreFromRow(_ row: PublicationRowData) -> Double {
        guard let year = row.year, year > 0 else { return 0.5 }
        let currentYear = Calendar.current.component(.year, from: Date())
        let age = currentYear - year
        return exp(-Double(age) / 2.0)
    }

    private static func citationVelocityFromRow(_ row: PublicationRowData) -> Double {
        let citationCount = row.citationCount
        guard citationCount > 0 else { return 0.0 }
        guard let year = row.year, year > 0 else { return 0.0 }
        let currentYear = Calendar.current.component(.year, from: Date())
        let age = max(1, currentYear - year)
        let velocity = Double(citationCount) / Double(age)
        return tanh(velocity / 10.0)
    }

    // MARK: - Semantic Similarity

    /// Compute library similarity score from ANN search results.
    public static func librarySimilarityScore(from similarities: [Float]) -> Double {
        guard !similarities.isEmpty else { return 0.0 }

        let maxSimilarity = Double(similarities.max() ?? 0)
        let count = Double(similarities.count)
        let avgSimilarity = Double(similarities.reduce(0, +)) / count
        let countBonus = tanh(count / 5.0) * 0.2

        let score = maxSimilarity * 0.8 + avgSimilarity * 0.2 + countBonus
        return min(1.0, score)
    }

    // MARK: - Helpers

    /// Fetch muted items of a specific type via RustStoreAdapter.
    @MainActor
    private static func fetchMutedItems(type: String) -> Set<String> {
        let items = RustStoreAdapter.shared.listMutedItems(muteType: type)
        return Set(items.map { $0.value.lowercased() })
    }

    /// Extract keywords from text.
    static func extractKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "as", "is", "was", "are", "were", "been",
            "using", "via", "based", "new", "novel", "approach", "method", "study"
        ]

        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    /// Hyperbolic tangent for normalizing unbounded values to [-1, 1].
    private static func tanh(_ x: Double) -> Double {
        return Darwin.tanh(x)
    }
}
