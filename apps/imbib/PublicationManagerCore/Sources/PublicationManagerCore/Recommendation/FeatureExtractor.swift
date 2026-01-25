//
//  FeatureExtractor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData
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
    ///   - publication: The publication to score
    ///   - profile: The user's learned preferences
    ///   - library: The library context (for venue frequency, etc.)
    /// - Returns: Dictionary of feature type to raw value (0-1 range)
    public static func extract(
        from publication: CDPublication,
        profile: CDRecommendationProfile?,
        library: CDLibrary?
    ) -> [FeatureType: Double] {
        var features: [FeatureType: Double] = [:]

        // Explicit signals
        features[.authorStarred] = authorStarredScore(publication, profile: profile)
        features[.collectionMatch] = collectionMatchScore(publication, profile: profile, library: library)
        features[.tagMatch] = tagMatchScore(publication, profile: profile)
        features[.mutedAuthor] = mutedAuthorPenalty(publication)
        features[.mutedCategory] = mutedCategoryPenalty(publication)
        features[.mutedVenue] = mutedVenuePenalty(publication)

        // Behavioral signals
        features[.keepRateAuthor] = keepRateAuthorScore(publication, profile: profile)
        features[.keepRateVenue] = keepRateVenueScore(publication, profile: profile)
        features[.dismissRateAuthor] = dismissRateAuthorPenalty(publication, profile: profile)
        features[.readingTimeTopic] = readingTimeTopicScore(publication, profile: profile)
        features[.pdfDownloadAuthor] = pdfDownloadAuthorScore(publication, profile: profile)

        // Content signals
        features[.citationOverlap] = citationOverlapScore(publication, library: library)
        features[.authorCoauthorship] = authorCoauthorshipScore(publication, library: library)
        features[.venueFrequency] = venueFrequencyScore(publication, library: library)
        features[.recency] = recencyScore(publication)
        features[.fieldCitationVelocity] = citationVelocityScore(publication)
        features[.smartSearchMatch] = smartSearchMatchScore(publication, library: library)

        // Note: librarySimilarity is computed asynchronously by EmbeddingService
        // and injected later via `extractWithSimilarity` or by the RecommendationEngine
        features[.librarySimilarity] = 0.0

        return features
    }

    /// Extract features with a pre-computed similarity score.
    ///
    /// Use this when the similarity score has been computed by the EmbeddingService.
    /// - Parameters:
    ///   - publication: The publication to score
    ///   - profile: The user's learned preferences
    ///   - library: The library context
    ///   - similarityScore: Pre-computed similarity score from ANN search (0-1 range)
    /// - Returns: Dictionary of feature type to raw value
    public static func extractWithSimilarity(
        from publication: CDPublication,
        profile: CDRecommendationProfile?,
        library: CDLibrary?,
        similarityScore: Double
    ) -> [FeatureType: Double] {
        var features = extract(from: publication, profile: profile, library: library)
        features[.librarySimilarity] = similarityScore
        return features
    }

    // MARK: - Explicit Signals

    /// Score based on author affinity from starred papers.
    public static func authorStarredScore(
        _ publication: CDPublication,
        profile: CDRecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        var maxAffinity = 0.0
        for author in publication.sortedAuthors {
            let affinity = profile.authorAffinity(for: author.familyName)
            maxAffinity = max(maxAffinity, affinity)
        }

        // Normalize to 0-1 (affinities can grow unbounded)
        return tanh(maxAffinity)
    }

    /// Score based on collection membership patterns.
    public static func collectionMatchScore(
        _ publication: CDPublication,
        profile: CDRecommendationProfile?,
        library: CDLibrary?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        // Check topic keywords against profile
        let titleKeywords = extractKeywords(from: publication.title ?? "")
        var topicScore = 0.0
        for keyword in titleKeywords {
            topicScore += profile.topicAffinity(for: keyword)
        }

        // Normalize
        return tanh(topicScore / max(1.0, Double(titleKeywords.count)))
    }

    /// Score based on tag affinity.
    public static func tagMatchScore(
        _ publication: CDPublication,
        profile: CDRecommendationProfile?
    ) -> Double {
        // If publication already has tags, check their affinity
        guard let tags = publication.tags, !tags.isEmpty, let profile = profile else {
            return 0.0
        }

        var totalAffinity = 0.0
        for tag in tags {
            totalAffinity += profile.topicAffinity(for: tag.name)
        }

        return tanh(totalAffinity / Double(tags.count))
    }

    /// Penalty for muted authors (-1.0 if muted, 0.0 otherwise).
    public static func mutedAuthorPenalty(_ publication: CDPublication) -> Double {
        let mutedAuthors = fetchMutedItems(type: .author)
        for author in publication.sortedAuthors {
            if mutedAuthors.contains(author.familyName.lowercased()) {
                return -1.0
            }
        }
        return 0.0
    }

    /// Penalty for muted arXiv categories.
    public static func mutedCategoryPenalty(_ publication: CDPublication) -> Double {
        let mutedCategories = fetchMutedItems(type: .arxivCategory)
        if let primaryClass = publication.fields["primaryclass"] {
            if mutedCategories.contains(primaryClass.lowercased()) {
                return -1.0
            }
        }
        return 0.0
    }

    /// Penalty for muted venues/journals.
    public static func mutedVenuePenalty(_ publication: CDPublication) -> Double {
        let mutedVenues = fetchMutedItems(type: .venue)
        if let journal = publication.fields["journal"]?.lowercased() {
            if mutedVenues.contains(journal) {
                return -1.0
            }
        }
        return 0.0
    }

    // MARK: - Behavioral Signals

    /// Score based on historical keep rate for this author.
    public static func keepRateAuthorScore(
        _ publication: CDPublication,
        profile: CDRecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        // Use author affinity as proxy (positive affinity = high keep rate)
        var maxAffinity = 0.0
        for author in publication.sortedAuthors {
            let affinity = profile.authorAffinity(for: author.familyName)
            if affinity > 0 {
                maxAffinity = max(maxAffinity, affinity)
            }
        }

        return tanh(maxAffinity)
    }

    /// Score based on historical keep rate for this venue.
    public static func keepRateVenueScore(
        _ publication: CDPublication,
        profile: CDRecommendationProfile?
    ) -> Double {
        guard let profile = profile,
              let journal = publication.fields["journal"] else { return 0.0 }

        let affinity = profile.venueAffinity(for: journal)
        return affinity > 0 ? tanh(affinity) : 0.0
    }

    /// Penalty based on historical dismiss rate for this author.
    public static func dismissRateAuthorPenalty(
        _ publication: CDPublication,
        profile: CDRecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        // Negative author affinity indicates dismiss rate
        var minAffinity = 0.0
        for author in publication.sortedAuthors {
            let affinity = profile.authorAffinity(for: author.familyName)
            if affinity < 0 {
                minAffinity = min(minAffinity, affinity)
            }
        }

        return minAffinity < 0 ? tanh(minAffinity) : 0.0  // Returns negative value
    }

    /// Score based on reading time spent on similar topics.
    public static func readingTimeTopicScore(
        _ publication: CDPublication,
        profile: CDRecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        let titleKeywords = extractKeywords(from: publication.title ?? "")
        var totalAffinity = 0.0

        for keyword in titleKeywords {
            let affinity = profile.topicAffinity(for: keyword)
            if affinity > 0 {
                totalAffinity += affinity
            }
        }

        return titleKeywords.isEmpty ? 0.0 : tanh(totalAffinity / Double(titleKeywords.count))
    }

    /// Score based on PDF download patterns for this author.
    public static func pdfDownloadAuthorScore(
        _ publication: CDPublication,
        profile: CDRecommendationProfile?
    ) -> Double {
        // Similar to keepRateAuthor - uses author affinity
        return keepRateAuthorScore(publication, profile: profile) * 0.8
    }

    // MARK: - Content Signals

    /// Score based on citation overlap with user's library.
    public static func citationOverlapScore(
        _ publication: CDPublication,
        library: CDLibrary?
    ) -> Double {
        // This would require citation graph data
        // For now, return 0 as placeholder (to be enhanced when citation data is available)
        return 0.0
    }

    /// Score based on co-authorship with authors in user's library.
    public static func authorCoauthorshipScore(
        _ publication: CDPublication,
        library: CDLibrary?
    ) -> Double {
        guard let library = library,
              let libraryPubs = library.publications else { return 0.0 }

        // Build set of authors in library
        var libraryAuthors = Set<String>()
        for pub in libraryPubs {
            for author in pub.sortedAuthors {
                libraryAuthors.insert(author.familyName.lowercased())
            }
        }

        // Check if any author of this publication is in the library
        var matchCount = 0
        for author in publication.sortedAuthors {
            if libraryAuthors.contains(author.familyName.lowercased()) {
                matchCount += 1
            }
        }

        // Normalize by author count
        let authorCount = publication.sortedAuthors.count
        return authorCount > 0 ? Double(matchCount) / Double(authorCount) : 0.0
    }

    /// Score based on venue frequency in user's library.
    public static func venueFrequencyScore(
        _ publication: CDPublication,
        library: CDLibrary?
    ) -> Double {
        guard let library = library,
              let libraryPubs = library.publications,
              let journal = publication.fields["journal"]?.lowercased() else { return 0.0 }

        // Count papers from this venue in library
        var venueCount = 0
        for pub in libraryPubs {
            if pub.fields["journal"]?.lowercased() == journal {
                venueCount += 1
            }
        }

        // Normalize (diminishing returns after 5 papers)
        return tanh(Double(venueCount) / 5.0)
    }

    /// Score based on publication recency (exponential decay).
    public static func recencyScore(_ publication: CDPublication) -> Double {
        let year = Int(publication.year)
        guard year > 0 else { return 0.5 }  // Unknown year gets neutral score

        let currentYear = Calendar.current.component(.year, from: Date())
        let age = currentYear - year

        // Exponential decay: 1.0 for current year, ~0.37 for 1 year old, ~0.14 for 2 years
        return exp(-Double(age) / 2.0)
    }

    /// Score based on citation velocity (citations per year).
    public static func citationVelocityScore(_ publication: CDPublication) -> Double {
        let citationCount = publication.citationCount
        guard citationCount > 0 else { return 0.0 }

        let year = Int(publication.year)
        guard year > 0 else { return 0.0 }

        let currentYear = Calendar.current.component(.year, from: Date())
        let age = max(1, currentYear - year)  // At least 1 year

        let velocity = Double(citationCount) / Double(age)

        // Normalize: 10 citations/year is considered high
        return tanh(velocity / 10.0)
    }

    /// Score based on matching saved smart searches.
    public static func smartSearchMatchScore(
        _ publication: CDPublication,
        library: CDLibrary?
    ) -> Double {
        // Check if paper is in any smart search result collection
        guard let collections = publication.collections else { return 0.0 }

        for collection in collections {
            if collection.isSmartSearchResults {
                return 1.0  // Paper matches at least one smart search
            }
        }

        return 0.0
    }

    // MARK: - Semantic Similarity

    /// Compute library similarity score from ANN search results.
    ///
    /// Takes the top-k similar papers and computes an aggregate score.
    /// Uses the maximum similarity as the primary signal, with a bonus
    /// for having multiple similar papers.
    ///
    /// - Parameter similarities: Similarity scores from ANN search (0-1 range)
    /// - Returns: Normalized score in 0-1 range
    public static func librarySimilarityScore(from similarities: [Float]) -> Double {
        guard !similarities.isEmpty else { return 0.0 }

        // Use max similarity as primary signal
        let maxSimilarity = Double(similarities.max() ?? 0)

        // Add bonus for having multiple similar papers (diminishing returns)
        let count = Double(similarities.count)
        let avgSimilarity = Double(similarities.reduce(0, +)) / count
        let countBonus = tanh(count / 5.0) * 0.2  // Up to 0.2 bonus for 5+ matches

        // Combine: 80% max + 20% average + count bonus, capped at 1.0
        let score = maxSimilarity * 0.8 + avgSimilarity * 0.2 + countBonus
        return min(1.0, score)
    }

    // MARK: - Helpers

    /// Fetch muted items of a specific type.
    private static func fetchMutedItems(type: CDMutedItem.MuteType) -> Set<String> {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDMutedItem>(entityName: "MutedItem")
        request.predicate = NSPredicate(format: "type == %@", type.rawValue)

        guard let items = try? context.fetch(request) else {
            return []
        }

        return Set(items.map { $0.value.lowercased() })
    }

    /// Extract keywords from text.
    private static func extractKeywords(from text: String) -> [String] {
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

