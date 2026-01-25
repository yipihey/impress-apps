//
//  ColdStartBootstrap.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData
import OSLog

// MARK: - Cold Start Bootstrap (ADR-020)

/// Initializes a recommendation profile from existing library data.
///
/// Used when the user has no training history but has library content.
/// Bootstrap sources:
/// 1. Library papers (≥20): Extract author/venue/topic frequencies
/// 2. Smart searches: Use query terms as topic indicators
/// 3. Muted items: Use as negative preferences
/// 4. Starred papers: Extract strong positive signals
/// 5. Fallback: Chronological + citation velocity only
public struct ColdStartBootstrap {

    /// Minimum papers needed for meaningful bootstrap
    private static let minimumPapersForBootstrap = 20

    /// Bootstrap a profile from existing library data.
    ///
    /// - Parameters:
    ///   - profile: The profile to populate
    ///   - library: The library to extract preferences from
    public static func bootstrap(
        profile: CDRecommendationProfile,
        from library: CDLibrary
    ) {
        guard let publications = library.publications,
              publications.count >= minimumPapersForBootstrap else {
            Logger.recommendation.info("Not enough papers for bootstrap (\(library.publications?.count ?? 0) < \(minimumPapersForBootstrap))")
            return
        }

        Logger.recommendation.info("Bootstrapping profile from \(publications.count) papers")

        // Extract author frequencies
        var authorCounts: [String: Int] = [:]
        var venueCounts: [String: Int] = [:]
        var topicCounts: [String: Int] = [:]

        for pub in publications {
            // Count authors
            for author in pub.sortedAuthors {
                let key = author.familyName.lowercased()
                authorCounts[key, default: 0] += 1
            }

            // Count venues
            if let journal = pub.fields["journal"]?.lowercased() {
                venueCounts[journal, default: 0] += 1
            }

            // Count title keywords as topics
            let keywords = extractKeywords(from: pub.title ?? "")
            for keyword in keywords {
                topicCounts[keyword, default: 0] += 1
            }

            // Count arXiv categories
            if let categories = pub.fields["primaryclass"] ?? pub.fields["categories"] {
                for category in categories.lowercased().split(separator: " ").map(String.init) {
                    topicCounts[category, default: 0] += 1
                }
            }
        }

        let totalPubs = Double(publications.count)

        // Convert counts to affinities (normalized log frequency)
        var authorAffinities: [String: Double] = [:]
        for (author, count) in authorCounts {
            // Log frequency normalized by total papers
            let frequency = Double(count) / totalPubs
            authorAffinities[author] = log(1 + frequency * 100)  // Scale up for visibility
        }

        var venueAffinities: [String: Double] = [:]
        for (venue, count) in venueCounts {
            let frequency = Double(count) / totalPubs
            venueAffinities[venue] = log(1 + frequency * 100)
        }

        var topicAffinities: [String: Double] = [:]
        for (topic, count) in topicCounts {
            let frequency = Double(count) / totalPubs
            topicAffinities[topic] = log(1 + frequency * 50)  // Topics get smaller boost
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
        extractSmartSearchSignals(
            library: library,
            topicAffinities: &topicAffinities
        )

        // Set the profile affinities
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
    }

    /// Bootstrap from multiple libraries (for global profile).
    public static func bootstrapGlobal(
        profile: CDRecommendationProfile,
        from libraries: [CDLibrary]
    ) {
        var allPubs: [CDPublication] = []
        for library in libraries where !library.isInbox && !library.isDismissedLibrary {
            if let pubs = library.publications {
                allPubs.append(contentsOf: pubs)
            }
        }

        guard allPubs.count >= minimumPapersForBootstrap else {
            Logger.recommendation.info("Not enough total papers for global bootstrap (\(allPubs.count))")
            return
        }

        // Use the first regular library as the source
        if let primaryLibrary = libraries.first(where: { !$0.isInbox && !$0.isSystemLibrary }) {
            bootstrap(profile: profile, from: primaryLibrary)
        }
    }

    // MARK: - Helpers

    private static func boostStarredPapers(
        publications: Set<CDPublication>,
        authorAffinities: inout [String: Double]
    ) {
        let starred = publications.filter { $0.isStarred }
        let boostFactor = 2.0

        for pub in starred {
            for author in pub.sortedAuthors {
                let key = author.familyName.lowercased()
                authorAffinities[key] = (authorAffinities[key] ?? 0) * boostFactor
            }
        }

        if !starred.isEmpty {
            Logger.recommendation.debug("Boosted affinities from \(starred.count) starred papers")
        }
    }

    private static func applyMutedItems(
        authorAffinities: inout [String: Double],
        topicAffinities: inout [String: Double],
        venueAffinities: inout [String: Double]
    ) {
        let context = PersistenceController.shared.viewContext
        let request = NSFetchRequest<CDMutedItem>(entityName: "MutedItem")

        guard let mutedItems = try? context.fetch(request) else { return }

        for item in mutedItems {
            let key = item.value.lowercased()

            switch item.muteType {
            case .author:
                authorAffinities[key] = -2.0  // Strong negative
            case .venue:
                venueAffinities[key] = -2.0
            case .arxivCategory:
                topicAffinities[key] = -1.5
            default:
                break
            }
        }

        if !mutedItems.isEmpty {
            Logger.recommendation.debug("Applied \(mutedItems.count) muted items as negative affinities")
        }
    }

    private static func extractSmartSearchSignals(
        library: CDLibrary,
        topicAffinities: inout [String: Double]
    ) {
        guard let smartSearches = library.smartSearches else { return }

        for search in smartSearches {
            // Extract keywords from search query
            let keywords = extractKeywords(from: search.query)
            for keyword in keywords {
                // Saved searches indicate topic interest
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
            let context = PersistenceController.shared.viewContext

            // Check if global profile exists and has data
            let request = NSFetchRequest<CDRecommendationProfile>(entityName: "RecommendationProfile")
            request.predicate = NSPredicate(format: "library == nil")
            request.fetchLimit = 1

            let profile: CDRecommendationProfile
            if let existing = try? context.fetch(request).first {
                // Check if it's a cold start
                if !existing.isColdStart {
                    Logger.recommendation.debug("Profile already has data, skipping bootstrap")
                    return
                }
                profile = existing
            } else {
                // Create new profile
                profile = CDRecommendationProfile(context: context)
                profile.id = UUID()
                profile.lastUpdated = Date()
            }

            // Fetch all libraries
            let libraryRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
            guard let libraries = try? context.fetch(libraryRequest),
                  !libraries.isEmpty else {
                Logger.recommendation.debug("No libraries found for bootstrap")
                return
            }

            // Bootstrap from libraries
            ColdStartBootstrap.bootstrapGlobal(profile: profile, from: libraries)
            PersistenceController.shared.save()
        }
    }
}
