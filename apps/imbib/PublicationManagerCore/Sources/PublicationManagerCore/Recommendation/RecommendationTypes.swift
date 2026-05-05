//
//  RecommendationTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation

// MARK: - Feature Types (ADR-020)

/// Features used to score publications for inbox/exploration ranking.
///
/// The recommendation engine uses a linear weighted sum: `score = Σ (weight_i × feature_i)`
/// Every feature type can be inspected and its weight adjusted by the user.
///
/// 9 tunable features + 3 binary mute filters.
public enum FeatureType: String, Codable, CaseIterable, Sendable, Identifiable {
    // MARK: - Tunable Features

    /// Learned preference for authors (merged: starred + save rate + dismiss rate)
    case authorAffinity

    /// Learned preference for topics (merged: reading time + collection match)
    case topicMatch

    /// Paper has tags matching the user's topic interests
    case tagAffinity

    /// Learned preference for journals/venues (merged: venue frequency + save rate)
    case venueAffinity

    /// Author has co-authored with authors in user's library
    case coauthorNetwork

    /// Paper recency (newer papers score higher)
    case recency

    /// Citation velocity (citations per year, indicates field impact)
    case citationVelocity

    /// Matches a saved smart search query
    case smartSearchMatch

    /// Similarity to papers in user's library (via embedding vectors)
    case aiSimilarity

    // MARK: - Mute Filters (binary on/off, not user-tunable weights)

    /// Author is muted by the user (negative signal)
    case mutedAuthor

    /// arXiv category is muted by the user (negative signal)
    case mutedCategory

    /// Venue/journal is muted by the user (negative signal)
    case mutedVenue

    public var id: String { rawValue }

    /// Human-readable name for UI display
    public var displayName: String {
        switch self {
        case .authorAffinity: return "Authors you follow"
        case .topicMatch: return "Topics you read"
        case .tagAffinity: return "Your tags"
        case .venueAffinity: return "Journals you read"
        case .coauthorNetwork: return "Collaborators of your authors"
        case .recency: return "Recently published"
        case .citationVelocity: return "Trending in the field"
        case .smartSearchMatch: return "Matches your searches"
        case .aiSimilarity: return "Similar to your library"
        case .mutedAuthor: return "Muted Author"
        case .mutedCategory: return "Muted Category"
        case .mutedVenue: return "Muted Venue"
        }
    }

    /// Description of what this feature measures
    public var featureDescription: String {
        switch self {
        case .authorAffinity:
            return "Papers by authors whose work you've kept, starred, or engaged with"
        case .topicMatch:
            return "Topics you spend time reading about and curate in collections"
        case .tagAffinity:
            return "Papers with tags matching your interests"
        case .venueAffinity:
            return "Venues and journals represented in your library"
        case .coauthorNetwork:
            return "Authors who've collaborated with authors in your library"
        case .recency:
            return "Recently published papers (exponential decay)"
        case .citationVelocity:
            return "Highly-cited papers relative to their age"
        case .smartSearchMatch:
            return "Papers matching your saved smart searches"
        case .aiSimilarity:
            return "Papers semantically similar to those in your library (AI-powered)"
        case .mutedAuthor:
            return "Papers by authors you've muted (reduces score)"
        case .mutedCategory:
            return "Papers in categories you've muted (reduces score)"
        case .mutedVenue:
            return "Papers from venues you've muted (reduces score)"
        }
    }

    /// Default weight for this feature (used in cold start)
    public var defaultWeight: Double {
        switch self {
        // Tunable features
        case .authorAffinity: return 0.8
        case .topicMatch: return 0.6
        case .tagAffinity: return 0.5
        case .venueAffinity: return 0.4
        case .coauthorNetwork: return 0.3
        case .recency: return 0.3
        case .citationVelocity: return 0.2
        case .smartSearchMatch: return 0.6
        case .aiSimilarity: return 0.5

        // Mute filters (fixed penalties)
        case .mutedAuthor: return -1.0
        case .mutedCategory: return -0.8
        case .mutedVenue: return -0.6
        }
    }

    /// Whether this is a mute filter (binary, not user-adjustable weight)
    public var isMuteFilter: Bool {
        switch self {
        case .mutedAuthor, .mutedCategory, .mutedVenue:
            return true
        default:
            return false
        }
    }

    /// Whether this is a negative feature (penalties)
    public var isNegativeFeature: Bool {
        isMuteFilter
    }

    /// Tunable features (excludes mute filters)
    public static var tunableFeatures: [FeatureType] {
        allCases.filter { !$0.isMuteFilter }
    }

    /// Category for grouping in settings UI
    public var category: FeatureCategory {
        switch self {
        case .authorAffinity, .topicMatch, .tagAffinity, .venueAffinity:
            return .preferences
        case .coauthorNetwork, .recency, .citationVelocity, .smartSearchMatch, .aiSimilarity:
            return .discovery
        case .mutedAuthor, .mutedCategory, .mutedVenue:
            return .filters
        }
    }

    // MARK: - Migration from old 18-feature keys

    /// Map old feature rawValues to new ones for settings migration.
    public static func migrateWeightKey(_ oldKey: String) -> String? {
        switch oldKey {
        // Merged into authorAffinity
        case "authorStarred", "saveRateAuthor", "dismissRateAuthor":
            return FeatureType.authorAffinity.rawValue
        // Merged into topicMatch
        case "readingTimeTopic", "collectionMatch":
            return FeatureType.topicMatch.rawValue
        // Merged into venueAffinity
        case "venueFrequency", "saveRateVenue":
            return FeatureType.venueAffinity.rawValue
        // Renamed
        case "tagMatch":
            return FeatureType.tagAffinity.rawValue
        case "authorCoauthorship":
            return FeatureType.coauthorNetwork.rawValue
        case "fieldCitationVelocity":
            return FeatureType.citationVelocity.rawValue
        case "librarySimilarity":
            return FeatureType.aiSimilarity.rawValue
        // Removed (phantom/dead)
        case "citationOverlap", "pdfDownloadAuthor":
            return nil
        // Already valid
        case "recency", "smartSearchMatch",
             "mutedAuthor", "mutedCategory", "mutedVenue":
            return oldKey
        default:
            return nil
        }
    }
}

/// Categories for feature types (for settings UI grouping)
public enum FeatureCategory: String, CaseIterable, Sendable {
    case preferences = "Your Preferences"
    case discovery = "Discovery"
    case filters = "Mute Filters"

    public var description: String {
        switch self {
        case .preferences:
            return "Learned from your reading patterns"
        case .discovery:
            return "Signals for finding new papers"
        case .filters:
            return "Binary filters (always active)"
        }
    }
}

// MARK: - Training Events

/// A recorded user action used to update recommendation weights.
///
/// Training events are stored in the profile and can be reviewed/undone by the user.
public struct TrainingEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let action: TrainingAction
    public let publicationID: UUID
    public let publicationTitle: String
    public let publicationAuthors: String
    public let weightDeltas: [String: Double]  // FeatureType.rawValue -> delta

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        action: TrainingAction,
        publicationID: UUID,
        publicationTitle: String,
        publicationAuthors: String,
        weightDeltas: [String: Double]
    ) {
        self.id = id
        self.date = date
        self.action = action
        self.publicationID = publicationID
        self.publicationTitle = publicationTitle
        self.publicationAuthors = publicationAuthors
        self.weightDeltas = weightDeltas
    }

    /// Summary for display in training history
    public var summary: String {
        "\(action.displayName): \(publicationTitle)"
    }
}

/// Actions that generate training events
public enum TrainingAction: String, Codable, Sendable {
    /// User saved the paper (moved from inbox to library)
    case saved

    /// User dismissed the paper
    case dismissed

    /// User starred the paper
    case starred

    /// User unstarred the paper
    case unstarred

    /// User marked the paper as read
    case read

    /// User downloaded the PDF
    case pdfDownloaded

    /// User explicitly requested "more like this"
    case moreLikeThis

    /// User explicitly requested "less like this"
    case lessLikeThis

    /// User added paper to a collection
    case addedToCollection

    /// Display name for UI
    public var displayName: String {
        switch self {
        case .saved: return "Saved"
        case .dismissed: return "Dismissed"
        case .starred: return "Starred"
        case .unstarred: return "Unstarred"
        case .read: return "Read"
        case .pdfDownloaded: return "PDF Downloaded"
        case .moreLikeThis: return "More Like This"
        case .lessLikeThis: return "Less Like This"
        case .addedToCollection: return "Added to Collection"
        }
    }

    /// Learning rate multiplier for this action
    public var learningMultiplier: Double {
        switch self {
        case .saved: return 1.0
        case .dismissed: return -1.0
        case .starred: return 2.0        // Stronger positive signal
        case .unstarred: return -1.0     // Reverse the star signal
        case .read: return 0.5           // Moderate positive
        case .pdfDownloaded: return 0.5  // Moderate positive
        case .moreLikeThis: return 2.5   // Strong explicit positive
        case .lessLikeThis: return -2.5  // Strong explicit negative
        case .addedToCollection: return 1.5  // Good positive signal
        }
    }

    /// Whether this is a positive action
    public var isPositive: Bool {
        switch self {
        case .saved, .starred, .read, .pdfDownloaded, .moreLikeThis, .addedToCollection:
            return true
        case .dismissed, .unstarred, .lessLikeThis:
            return false
        }
    }

    /// SF Symbol for this action
    public var icon: String {
        switch self {
        case .saved: return "tray.and.arrow.down"
        case .dismissed: return "xmark.circle"
        case .starred: return "star.fill"
        case .unstarred: return "star"
        case .read: return "book"
        case .pdfDownloaded: return "arrow.down.doc"
        case .moreLikeThis: return "hand.thumbsup"
        case .lessLikeThis: return "hand.thumbsdown"
        case .addedToCollection: return "folder.badge.plus"
        }
    }
}

// MARK: - Recommendation Score

/// A scored publication with breakdown of how the score was computed.
public struct RecommendationScore: Sendable {
    /// Total score (weighted sum of all features)
    public let total: Double

    /// Individual feature contributions (feature -> weighted value)
    public let breakdown: [FeatureType: Double]

    /// Human-readable explanation of the score
    public let explanation: String

    /// Whether this is a serendipity slot (high potential, low topic match)
    public let isSerendipitySlot: Bool

    /// Top reasons for the recommendation (human-readable strings)
    public let topReasons: [String]

    public init(
        total: Double,
        breakdown: [FeatureType: Double],
        explanation: String,
        isSerendipitySlot: Bool = false,
        topReasons: [String] = []
    ) {
        self.total = total
        self.breakdown = breakdown
        self.explanation = explanation
        self.isSerendipitySlot = isSerendipitySlot
        self.topReasons = topReasons
    }

    /// Top contributing features (positive contributions only)
    public var topContributors: [(FeatureType, Double)] {
        breakdown.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
    }

    /// Features that reduced the score (negative contributions)
    public var negativeContributors: [(FeatureType, Double)] {
        breakdown.filter { $0.value < 0 }
            .sorted { $0.value < $1.value }
    }
}

/// A "For You" personalized recommendation.
public struct ForYouRecommendation: Sendable, Identifiable {
    public let publicationID: UUID
    public let score: Double
    public let reason: String

    public var id: UUID { publicationID }

    public init(publicationID: UUID, score: Double, reason: String) {
        self.publicationID = publicationID
        self.score = score
        self.reason = reason
    }
}

/// A publication with its recommendation score for ranking display.
public struct RankedPublication: Sendable, Identifiable {
    public let publicationID: UUID
    public let score: RecommendationScore
    public let isSerendipitySlot: Bool

    public var id: UUID { publicationID }

    public init(publicationID: UUID, score: RecommendationScore, isSerendipitySlot: Bool = false) {
        self.publicationID = publicationID
        self.score = score
        self.isSerendipitySlot = isSerendipitySlot
    }
}

/// Detailed breakdown of a score for the "Why this ranking?" UI.
public struct ScoreBreakdown: Sendable {
    public let total: Double
    public let components: [ScoreComponent]

    public init(total: Double, components: [ScoreComponent]) {
        self.total = total
        self.components = components
    }
}

/// A single component of a score breakdown.
public struct ScoreComponent: Sendable, Identifiable {
    public let feature: FeatureType
    public let rawValue: Double      // The raw feature value (0-1)
    public let weight: Double        // The user's weight for this feature
    public let contribution: Double  // rawValue × weight
    public let detail: String?       // Optional contextual detail (e.g., "Smith, Jones")

    public var id: String { feature.rawValue }

    public init(feature: FeatureType, rawValue: Double, weight: Double, detail: String? = nil) {
        self.feature = feature
        self.rawValue = rawValue
        self.weight = weight
        self.contribution = rawValue * weight
        self.detail = detail
    }

    /// Whether this component adds to or subtracts from the score
    public var isPositiveContribution: Bool {
        contribution > 0
    }
}

// MARK: - Recommendation Settings Presets

/// Predefined weight configurations for different use cases.
public enum RecommendationPreset: String, CaseIterable, Sendable {
    /// Focus on familiar authors/venues, minimize serendipity
    case focused

    /// Balanced between familiar and discovery
    case balanced

    /// Prioritize diverse discovery, high serendipity
    case exploratory

    public var displayName: String {
        switch self {
        case .focused: return "Focused"
        case .balanced: return "Balanced"
        case .exploratory: return "Explorer"
        }
    }

    public var description: String {
        switch self {
        case .focused:
            return "Papers from authors and topics you know"
        case .balanced:
            return "Mix of familiar and new"
        case .exploratory:
            return "Surprise me with new directions"
        }
    }

    public var icon: String {
        switch self {
        case .focused: return "scope"
        case .balanced: return "scale.3d"
        case .exploratory: return "binoculars"
        }
    }

    /// Get the weights for this preset
    public var weights: [FeatureType: Double] {
        switch self {
        case .focused:
            return [
                .authorAffinity: 1.0,
                .topicMatch: 0.9,
                .tagAffinity: 0.7,
                .venueAffinity: 0.7,
                .coauthorNetwork: 0.3,
                .recency: 0.2,
                .citationVelocity: 0.1,
                .smartSearchMatch: 0.6,
                .aiSimilarity: 0.2,
                .mutedAuthor: -1.0,
                .mutedCategory: -0.8,
                .mutedVenue: -0.6,
            ]
        case .balanced:
            return Dictionary(uniqueKeysWithValues: FeatureType.allCases.map { ($0, $0.defaultWeight) })
        case .exploratory:
            return [
                .authorAffinity: 0.2,
                .topicMatch: 0.2,
                .tagAffinity: 0.3,
                .venueAffinity: 0.1,
                .coauthorNetwork: 0.5,
                .recency: 0.6,
                .citationVelocity: 0.7,
                .smartSearchMatch: 0.4,
                .aiSimilarity: 0.8,
                .mutedAuthor: -1.0,
                .mutedCategory: -0.4,
                .mutedVenue: -0.3,
            ]
        }
    }
}
