//
//  FeatureExtractor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import OSLog
import ImbibRustCore

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

        // Tunable features
        features[.authorAffinity] = authorAffinityScore(publication, profile: profile)
        features[.topicMatch] = topicMatchScore(publication, profile: profile)
        features[.tagAffinity] = tagAffinityScore(publication, profile: profile)
        features[.venueAffinity] = venueAffinityScore(publication, profile: profile, libraryPublications: libraryPublications)
        features[.coauthorNetwork] = coauthorNetworkScore(publication, libraryPublications: libraryPublications)
        features[.recency] = recencyScore(publication)
        features[.citationVelocity] = citationVelocityScore(publication)
        features[.smartSearchMatch] = 0.0  // Computed separately if needed

        // Semantic similarity computed asynchronously by EmbeddingService
        features[.aiSimilarity] = 0.0

        // Mute filters
        features[.mutedAuthor] = mutedAuthorPenalty(publication)
        features[.mutedCategory] = mutedCategoryPenalty(publication)
        features[.mutedVenue] = mutedVenuePenalty(publication)

        return features
    }

    /// Extract features from PublicationRowData (lightweight, for batch operations).
    /// Delegates to Rust `extractFeaturesBatch()` for single-item extraction.
    @MainActor public static func extract(
        from row: PublicationRowData,
        profile: RecommendationProfile?,
        libraryPublications: [PublicationRowData]
    ) -> [FeatureType: Double] {
        let results = extractBatch(from: [row], profile: profile, libraryPublications: libraryPublications)
        return results.first ?? [:]
    }

    /// Batch extract features for multiple publications via Rust.
    /// Reduces FFI overhead by processing all publications in a single call.
    @MainActor public static func extractBatch(
        from rows: [PublicationRowData],
        profile: RecommendationProfile?,
        libraryPublications: [PublicationRowData]
    ) -> [[FeatureType: Double]] {
        let inputs = rows.map { Self.toFeatureInput($0) }
        let profileData = Self.toProfileData(profile)
        let libraryContext = Self.toLibraryContext(libraryPublications)
        let mutedItems = Self.buildMutedItems()

        let rustResults = ImbibRustCore.extractFeaturesBatch(
            publications: inputs,
            profile: profileData,
            library: libraryContext,
            muted: mutedItems
        )

        return rustResults.map { Self.fromFeatureVector($0) }
    }

    // MARK: - Rust FFI Conversion Helpers

    /// Convert PublicationRowData to Rust PublicationFeatureInput.
    private static func toFeatureInput(_ row: PublicationRowData) -> PublicationFeatureInput {
        let authorFamilyNames = row.authorString
            .components(separatedBy: ",")
            .compactMap { name -> String? in
                let familyName = name.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first ?? ""
                return familyName.isEmpty ? nil : familyName.lowercased()
            }

        return PublicationFeatureInput(
            authorFamilyNames: authorFamilyNames,
            title: row.title,
            tagNames: [],  // Row data doesn't carry tags
            primaryClass: row.primaryCategory,
            journal: row.venue?.lowercased(),
            year: row.year.map { Int32($0) },
            citationCount: Int32(row.citationCount),
            inSmartSearch: false,
            similarityScores: []
        )
    }

    /// Convert RecommendationProfile to Rust ProfileData.
    private static func toProfileData(_ profile: RecommendationProfile?) -> ProfileData {
        guard let profile = profile else {
            return ProfileData(authorAffinities: [:], topicAffinities: [:], venueAffinities: [:])
        }
        return ProfileData(
            authorAffinities: profile.authorAffinities,
            topicAffinities: profile.topicAffinities,
            venueAffinities: profile.venueAffinities
        )
    }

    /// Build Rust LibraryContext from library publications.
    private static func toLibraryContext(_ libraryPublications: [PublicationRowData]) -> LibraryContext {
        var authorNames: [String] = []
        var venueCounts: [String: Int32] = [:]

        for pub in libraryPublications {
            for name in pub.authorString.components(separatedBy: ",") {
                let familyName = name.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first ?? ""
                if !familyName.isEmpty {
                    authorNames.append(familyName.lowercased())
                }
            }
            if let venue = pub.venue?.lowercased() {
                venueCounts[venue, default: 0] += 1
            }
        }

        return LibraryContext(
            libraryAuthorNames: authorNames,
            venueCounts: venueCounts,
            currentYear: Int32(Calendar.current.component(.year, from: Date()))
        )
    }

    /// Build Rust MutedItems from RustStoreAdapter.
    @MainActor
    private static func buildMutedItems() -> MutedItems {
        let mutedAuthors = fetchMutedItems(type: "author").map { $0.lowercased() }
        let mutedCategories = fetchMutedItems(type: "arxivCategory").map { $0.lowercased() }
        let mutedVenues = fetchMutedItems(type: "venue").map { $0.lowercased() }
        return MutedItems(
            authors: Array(mutedAuthors),
            categories: Array(mutedCategories),
            venues: Array(mutedVenues)
        )
    }

    /// Map Rust FeatureType → Swift FeatureType.
    /// Rust still uses the old granular names; we map them to merged features here.
    private static let rustToSwiftFeatureMap: [ImbibRustCore.FeatureType: FeatureType] = [
        .authorStarred: .authorAffinity,
        .collectionMatch: .topicMatch,
        .tagMatch: .tagAffinity,
        .mutedAuthor: .mutedAuthor,
        .mutedCategory: .mutedCategory,
        .mutedVenue: .mutedVenue,
        .keepRateAuthor: .authorAffinity,   // merged — take max
        .keepRateVenue: .venueAffinity,     // merged — take max
        .dismissRateAuthor: .authorAffinity, // merged — contributes negatively
        .readingTimeTopic: .topicMatch,     // merged — take max
        .pdfDownloadAuthor: .authorAffinity, // absorbed
        .authorCoauthorship: .coauthorNetwork,
        .venueFrequency: .venueAffinity,    // merged — take max
        .recency: .recency,
        .fieldCitationVelocity: .citationVelocity,
        .smartSearchMatch: .smartSearchMatch,
        .librarySimilarity: .aiSimilarity,
    ]

    /// Convert Rust FeatureVector to Swift feature dictionary.
    /// When multiple Rust features map to the same Swift feature, take the max absolute value.
    private static func fromFeatureVector(_ vector: ImbibRustCore.FeatureVector) -> [FeatureType: Double] {
        var result: [FeatureType: Double] = [:]
        for (rustType, value) in vector.features {
            if let swiftType = rustToSwiftFeatureMap[rustType] {
                if let existing = result[swiftType] {
                    // For merged features, take the value with the largest absolute magnitude
                    if abs(value) > abs(existing) {
                        result[swiftType] = value
                    }
                } else {
                    result[swiftType] = value
                }
            }
        }
        return result
    }

    /// Extract features with a pre-computed similarity score.
    @MainActor public static func extractWithSimilarity(
        from publication: PublicationModel,
        profile: RecommendationProfile?,
        libraryPublications: [PublicationRowData],
        similarityScore: Double
    ) -> [FeatureType: Double] {
        var features = extract(from: publication, profile: profile, libraryPublications: libraryPublications)
        features[.aiSimilarity] = similarityScore
        return features
    }

    // MARK: - Merged Feature Extractors (PublicationModel)

    /// Author Affinity: merged from authorStarred + saveRateAuthor + dismissRateAuthor.
    /// Uses the max affinity across all authors (positive or negative).
    public static func authorAffinityScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        var maxAffinity = 0.0
        for author in publication.authors {
            let affinity = profile.authorAffinity(for: author.familyName)
            if abs(affinity) > abs(maxAffinity) {
                maxAffinity = affinity
            }
        }

        return tanh(maxAffinity)
    }

    /// Topic Match: merged from collectionMatch + readingTimeTopic.
    /// Extracts title keywords and looks up topic affinities.
    public static func topicMatchScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?
    ) -> Double {
        guard let profile = profile else { return 0.0 }

        let titleKeywords = extractKeywords(from: publication.title)
        guard !titleKeywords.isEmpty else { return 0.0 }

        var totalAffinity = 0.0
        for keyword in titleKeywords {
            totalAffinity += profile.topicAffinity(for: keyword)
        }

        return tanh(totalAffinity / Double(titleKeywords.count))
    }

    /// Tag Affinity: matches paper tags to topic interests.
    public static func tagAffinityScore(
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

    /// Venue Affinity: merged from venueFrequency + saveRateVenue.
    /// Combines profile affinity with library frequency.
    public static func venueAffinityScore(
        _ publication: PublicationModel,
        profile: RecommendationProfile?,
        libraryPublications: [PublicationRowData]
    ) -> Double {
        guard let journal = publication.journal?.lowercased() else { return 0.0 }

        // Profile-based venue affinity
        var score = 0.0
        if let profile = profile {
            let affinity = profile.venueAffinity(for: journal)
            if affinity > 0 {
                score = tanh(affinity)
            }
        }

        // Library frequency bonus
        var venueCount = 0
        for pub in libraryPublications {
            if pub.venue?.lowercased() == journal {
                venueCount += 1
            }
        }
        let frequencyScore = tanh(Double(venueCount) / 5.0)

        // Take the higher of the two signals
        return max(score, frequencyScore)
    }

    // MARK: - Mute Filters

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

    // MARK: - Content Signals

    public static func coauthorNetworkScore(
        _ publication: PublicationModel,
        libraryPublications: [PublicationRowData]
    ) -> Double {
        guard !libraryPublications.isEmpty else { return 0.0 }

        var libraryAuthors = Set<String>()
        for pub in libraryPublications {
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

    // MARK: - Semantic Similarity

    /// Compute library similarity score from ANN search results via Rust.
    public static func librarySimilarityScore(from similarities: [Float]) -> Double {
        return ImbibRustCore.computeLibrarySimilarityScore(similarities: similarities)
    }

    // MARK: - Helpers

    /// Fetch muted items of a specific type via RustStoreAdapter.
    @MainActor
    private static func fetchMutedItems(type: String) -> Set<String> {
        let items = RustStoreAdapter.shared.listMutedItems(muteType: type)
        return Set(items.map { $0.value.lowercased() })
    }

    /// Extract keywords from text via Rust.
    static func extractKeywords(from text: String) -> [String] {
        return ImbibRustCore.extractTitleKeywords(title: text)
    }

    /// Hyperbolic tangent for normalizing unbounded values to [-1, 1].
    private static func tanh(_ x: Double) -> Double {
        return Darwin.tanh(x)
    }
}
