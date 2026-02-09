//
//  ColdStartBootstrap.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import OSLog

// MARK: - Cold Start Bootstrap (ADR-020)

/// Initializes a recommendation profile from existing library data.
///
/// Used when the user has no training history but has library content.
/// Bootstrap sources:
/// 1. Library papers (>=20): Extract author/venue/topic frequencies
/// 2. Smart searches: Use query terms as topic indicators
/// 3. Muted items: Use as negative preferences
/// 4. Starred papers: Extract strong positive signals
/// 5. Fallback: Chronological + citation velocity only
public struct ColdStartBootstrap {

    /// Minimum papers needed for meaningful bootstrap
    private static let minimumPapersForBootstrap = 20

    /// Bootstrap a profile from existing library publications.
    ///
    /// - Parameters:
    ///   - publications: The publications to extract preferences from
    /// - Returns: A populated RecommendationProfile, or nil if not enough data
    @MainActor
    public static func bootstrap(from publications: [PublicationRowData]) -> RecommendationProfile? {
        guard publications.count >= minimumPapersForBootstrap else {
            Logger.recommendation.info("Not enough papers for bootstrap (\(publications.count) < \(minimumPapersForBootstrap))")
            return nil
        }

        Logger.recommendation.info("Bootstrapping profile from \(publications.count) papers")

        var authorCounts: [String: Int] = [:]
        var venueCounts: [String: Int] = [:]
        var topicCounts: [String: Int] = [:]

        for pub in publications {
            // Count authors (parse from authorString)
            for name in pub.authorString.components(separatedBy: ",") {
                let familyName = name.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first ?? ""
                if !familyName.isEmpty {
                    authorCounts[familyName.lowercased(), default: 0] += 1
                }
            }

            // Count venues
            if let venue = pub.venue?.lowercased() {
                venueCounts[venue, default: 0] += 1
            }

            // Count title keywords as topics
            let keywords = extractKeywords(from: pub.title)
            for keyword in keywords {
                topicCounts[keyword, default: 0] += 1
            }

            // Count arXiv categories
            if let category = pub.primaryCategory {
                for cat in category.lowercased().split(separator: " ").map(String.init) {
                    topicCounts[cat, default: 0] += 1
                }
            }
        }

        let totalPubs = Double(publications.count)

        // Convert counts to affinities (normalized log frequency)
        var authorAffinities: [String: Double] = [:]
        for (author, count) in authorCounts {
            let frequency = Double(count) / totalPubs
            authorAffinities[author] = log(1 + frequency * 100)
        }

        var venueAffinities: [String: Double] = [:]
        for (venue, count) in venueCounts {
            let frequency = Double(count) / totalPubs
            venueAffinities[venue] = log(1 + frequency * 100)
        }

        var topicAffinities: [String: Double] = [:]
        for (topic, count) in topicCounts {
            let frequency = Double(count) / totalPubs
            topicAffinities[topic] = log(1 + frequency * 50)
        }

        // Boost starred papers' authors
        boostStarredPapers(publications: publications, authorAffinities: &authorAffinities)

        // Apply muted items as negative affinities
        applyMutedItems(
            authorAffinities: &authorAffinities,
            topicAffinities: &topicAffinities,
            venueAffinities: &venueAffinities
        )

        // Extract signals from smart searches
        extractSmartSearchSignals(topicAffinities: &topicAffinities)

        var profile = RecommendationProfile()
        profile.authorAffinities = authorAffinities
        profile.venueAffinities = venueAffinities
        profile.topicAffinities = topicAffinities
        profile.lastUpdated = Date()

        Logger.recommendation.info("""
            Bootstrap complete:
            - \(authorAffinities.count) author affinities
            - \(venueAffinities.count) venue affinities
            - \(topicAffinities.count) topic affinities
            """)

        return profile
    }

    // MARK: - Helpers

    private static func boostStarredPapers(
        publications: [PublicationRowData],
        authorAffinities: inout [String: Double]
    ) {
        let starred = publications.filter { $0.isStarred }
        let boostFactor = 2.0

        for pub in starred {
            for name in pub.authorString.components(separatedBy: ",") {
                let familyName = name.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first ?? ""
                if !familyName.isEmpty {
                    let key = familyName.lowercased()
                    authorAffinities[key] = (authorAffinities[key] ?? 0) * boostFactor
                }
            }
        }

        if !starred.isEmpty {
            Logger.recommendation.debug("Boosted affinities from \(starred.count) starred papers")
        }
    }

    @MainActor
    private static func applyMutedItems(
        authorAffinities: inout [String: Double],
        topicAffinities: inout [String: Double],
        venueAffinities: inout [String: Double]
    ) {
        let store = RustStoreAdapter.shared
        let mutedItems = store.listMutedItems()

        for item in mutedItems {
            let key = item.value.lowercased()

            switch item.muteType {
            case "author":
                authorAffinities[key] = -2.0
            case "venue":
                venueAffinities[key] = -2.0
            case "arxivCategory":
                topicAffinities[key] = -1.5
            default:
                break
            }
        }

        if !mutedItems.isEmpty {
            Logger.recommendation.debug("Applied \(mutedItems.count) muted items as negative affinities")
        }
    }

    @MainActor
    private static func extractSmartSearchSignals(
        topicAffinities: inout [String: Double]
    ) {
        let store = RustStoreAdapter.shared
        let smartSearches = store.listSmartSearches()

        for search in smartSearches {
            let keywords = extractKeywords(from: search.query)
            for keyword in keywords {
                topicAffinities[keyword] = (topicAffinities[keyword] ?? 0) + 0.5
            }
        }

        if !smartSearches.isEmpty {
            Logger.recommendation.debug("Extracted signals from \(smartSearches.count) smart searches")
        }
    }

    private static func extractKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "as", "is", "was", "are", "were", "been",
            "using", "via", "based", "new", "novel", "approach", "method", "study",
            "author", "title", "abstract", "arxiv", "year"
        ]

        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }
}

// MARK: - Bootstrap Coordinator

/// Coordinates cold start bootstrap on app launch.
public actor BootstrapCoordinator {

    public static let shared = BootstrapCoordinator()

    private var hasBootstrapped = false

    private init() {}

    /// Check if bootstrap is needed and perform it if so.
    public func checkAndBootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        await MainActor.run {
            let store = RustStoreAdapter.shared

            // Check if global profile exists and has data
            guard let defaultLibrary = store.getDefaultLibrary() else {
                Logger.recommendation.debug("No default library found for bootstrap")
                return
            }

            if let existingJSON = store.getRecommendationProfile(libraryId: defaultLibrary.id),
               let existing = RecommendationProfile.fromJSON(existingJSON),
               !existing.isColdStart {
                Logger.recommendation.debug("Profile already has data, skipping bootstrap")
                return
            }

            // Get publications for bootstrap
            let publications = store.queryPublications(parentId: defaultLibrary.id)

            guard let profile = ColdStartBootstrap.bootstrap(from: publications) else {
                Logger.recommendation.debug("Not enough data for bootstrap")
                return
            }

            // Save profile
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
    }
}
