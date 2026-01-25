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
public enum FeatureType: String, Codable, CaseIterable, Sendable, Identifiable {
    // MARK: - Explicit Signals (User Actions)

    /// Author of this paper has starred papers from the user
    case authorStarred

    /// Paper matches a collection the user has added papers to
    case collectionMatch

    /// Paper has tags the user frequently uses
    case tagMatch

    /// Author is muted by the user (negative signal)
    case mutedAuthor

    /// arXiv category is muted by the user (negative signal)
    case mutedCategory

    /// Venue/journal is muted by the user (negative signal)
    case mutedVenue

    // MARK: - Implicit Signals (Behavioral)

    /// User's historical keep rate for this author
    case keepRateAuthor

    /// User's historical keep rate for this venue
    case keepRateVenue

    /// User's historical dismiss rate for this author (negative signal)
    case dismissRateAuthor

    /// User has read/spent time on papers with similar topics
    case readingTimeTopic

    /// User frequently downloads PDFs from this author
    case pdfDownloadAuthor

    // MARK: - Content Signals (Paper Properties)

    /// Paper cites or is cited by papers in user's library
    case citationOverlap

    /// Author has co-authored with authors in user's library
    case authorCoauthorship

    /// User has papers from this venue in their library
    case venueFrequency

    /// Paper recency (newer papers score higher)
    case recency

    /// Citation velocity (citations per year, indicates field impact)
    case fieldCitationVelocity

    /// Matches a saved smart search query
    case smartSearchMatch

    /// Similarity to papers in user's library (via embedding vectors)
    case librarySimilarity

    public var id: String { rawValue }

    /// Human-readable name for UI display
    public var displayName: String {
        switch self {
        case .authorStarred: return "Author Starred"
        case .collectionMatch: return "Collection Match"
        case .tagMatch: return "Tag Match"
        case .mutedAuthor: return "Muted Author"
        case .mutedCategory: return "Muted Category"
        case .mutedVenue: return "Muted Venue"
        case .keepRateAuthor: return "Author Keep Rate"
        case .keepRateVenue: return "Venue Keep Rate"
        case .dismissRateAuthor: return "Author Dismiss Rate"
        case .readingTimeTopic: return "Reading Time (Topic)"
        case .pdfDownloadAuthor: return "PDF Downloads (Author)"
        case .citationOverlap: return "Citation Overlap"
        case .authorCoauthorship: return "Co-author Network"
        case .venueFrequency: return "Venue Frequency"
        case .recency: return "Recency"
        case .fieldCitationVelocity: return "Citation Velocity"
        case .smartSearchMatch: return "Smart Search Match"
        case .librarySimilarity: return "Library Similarity"
        }
    }

    /// Description of what this feature measures
    public var featureDescription: String {
        switch self {
        case .authorStarred:
            return "Papers by authors whose work you've starred"
        case .collectionMatch:
            return "Papers matching collections you've curated"
        case .tagMatch:
            return "Papers with tags you frequently apply"
        case .mutedAuthor:
            return "Papers by authors you've muted (reduces score)"
        case .mutedCategory:
            return "Papers in categories you've muted (reduces score)"
        case .mutedVenue:
            return "Papers from venues you've muted (reduces score)"
        case .keepRateAuthor:
            return "Your historical rate of keeping papers by this author"
        case .keepRateVenue:
            return "Your historical rate of keeping papers from this venue"
        case .dismissRateAuthor:
            return "Your historical rate of dismissing papers by this author (reduces score)"
        case .readingTimeTopic:
            return "Topics you spend time reading about"
        case .pdfDownloadAuthor:
            return "Authors whose PDFs you frequently download"
        case .citationOverlap:
            return "Papers connected to your library through citations"
        case .authorCoauthorship:
            return "Authors who've collaborated with authors in your library"
        case .venueFrequency:
            return "Venues/journals represented in your library"
        case .recency:
            return "Recently published papers (exponential decay)"
        case .fieldCitationVelocity:
            return "Highly-cited papers relative to their age"
        case .smartSearchMatch:
            return "Papers matching your saved smart searches"
        case .librarySimilarity:
            return "Papers semantically similar to those in your library (AI-powered)"
        }
    }

    /// Default weight for this feature (used in cold start)
    public var defaultWeight: Double {
        switch self {
        // Explicit positive signals: high weight
        case .authorStarred: return 0.8
        case .collectionMatch: return 0.7
        case .tagMatch: return 0.6
        case .smartSearchMatch: return 0.6

        // Explicit negative signals: strong negative weight
        case .mutedAuthor: return -1.0
        case .mutedCategory: return -0.8
        case .mutedVenue: return -0.6

        // Behavioral signals: moderate weight
        case .keepRateAuthor: return 0.5
        case .keepRateVenue: return 0.3
        case .dismissRateAuthor: return -0.4
        case .readingTimeTopic: return 0.4
        case .pdfDownloadAuthor: return 0.5

        // Content signals: lower weight (let user preferences dominate)
        case .citationOverlap: return 0.4
        case .authorCoauthorship: return 0.3
        case .venueFrequency: return 0.2
        case .recency: return 0.3
        case .fieldCitationVelocity: return 0.2
        case .librarySimilarity: return 0.6  // Higher weight for semantic similarity
        }
    }

    /// Whether this is a negative feature (penalties)
    public var isNegativeFeature: Bool {
        switch self {
        case .mutedAuthor, .mutedCategory, .mutedVenue, .dismissRateAuthor:
            return true
        default:
            return false
        }
    }

    /// Category for grouping in settings UI
    public var category: FeatureCategory {
        switch self {
        case .authorStarred, .collectionMatch, .tagMatch, .mutedAuthor, .mutedCategory, .mutedVenue:
            return .explicit
        case .keepRateAuthor, .keepRateVenue, .dismissRateAuthor, .readingTimeTopic, .pdfDownloadAuthor:
            return .implicit
        case .citationOverlap, .authorCoauthorship, .venueFrequency, .recency, .fieldCitationVelocity, .smartSearchMatch, .librarySimilarity:
            return .content
        }
    }
}

/// Categories for feature types (for settings UI grouping)
public enum FeatureCategory: String, CaseIterable, Sendable {
    case explicit = "Explicit Signals"
    case implicit = "Behavioral Signals"
    case content = "Content Signals"

    public var description: String {
        switch self {
        case .explicit:
            return "Actions you've taken (stars, mutes, collections)"
        case .implicit:
            return "Patterns from your usage (keeps, dismisses, reading)"
        case .content:
            return "Properties of the paper itself"
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
    /// User kept the paper (moved from inbox to library)
    case kept

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
        case .kept: return "Kept"
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
        case .kept: return 1.0
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
        case .kept, .starred, .read, .pdfDownloaded, .moreLikeThis, .addedToCollection:
            return true
        case .dismissed, .unstarred, .lessLikeThis:
            return false
        }
    }

    /// SF Symbol for this action
    public var icon: String {
        switch self {
        case .kept: return "tray.and.arrow.down"
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

    public init(
        total: Double,
        breakdown: [FeatureType: Double],
        explanation: String,
        isSerendipitySlot: Bool = false
    ) {
        self.total = total
        self.breakdown = breakdown
        self.explanation = explanation
        self.isSerendipitySlot = isSerendipitySlot
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

    public var id: String { feature.rawValue }

    public init(feature: FeatureType, rawValue: Double, weight: Double) {
        self.feature = feature
        self.rawValue = rawValue
        self.weight = weight
        self.contribution = rawValue * weight
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

    /// Citation-heavy, good for literature reviews
    case research

    /// Reset all weights to defaults
    case defaults

    public var displayName: String {
        switch self {
        case .focused: return "Focused"
        case .balanced: return "Balanced"
        case .exploratory: return "Exploratory"
        case .research: return "Research Mode"
        case .defaults: return "Reset to Defaults"
        }
    }

    public var description: String {
        switch self {
        case .focused:
            return "Prioritize authors and venues you know"
        case .balanced:
            return "Mix of familiar and new content"
        case .exploratory:
            return "Discover new authors and topics"
        case .research:
            return "Emphasize citation connections"
        case .defaults:
            return "Reset all weights to default values"
        }
    }

    /// Get the weights for this preset
    public var weights: [FeatureType: Double] {
        switch self {
        case .focused:
            return [
                .authorStarred: 1.0,
                .collectionMatch: 0.9,
                .keepRateAuthor: 0.8,
                .venueFrequency: 0.7,
                .recency: 0.2,
                .citationOverlap: 0.3,
                .fieldCitationVelocity: 0.1,
                // Negative features
                .mutedAuthor: -1.0,
                .mutedCategory: -0.8,
                .mutedVenue: -0.6,
                .dismissRateAuthor: -0.6,
            ]
        case .balanced:
            // Use default weights
            return Dictionary(uniqueKeysWithValues: FeatureType.allCases.map { ($0, $0.defaultWeight) })
        case .exploratory:
            return [
                .authorStarred: 0.3,
                .collectionMatch: 0.3,
                .keepRateAuthor: 0.2,
                .venueFrequency: 0.1,
                .recency: 0.6,
                .citationOverlap: 0.5,
                .fieldCitationVelocity: 0.7,
                .authorCoauthorship: 0.6,
                .librarySimilarity: 0.5,  // Moderate weight for discovery
                // Negative features (weaker)
                .mutedAuthor: -1.0,
                .mutedCategory: -0.4,
                .mutedVenue: -0.3,
                .dismissRateAuthor: -0.3,
            ]
        case .research:
            return [
                .citationOverlap: 0.9,
                .authorCoauthorship: 0.7,
                .fieldCitationVelocity: 0.8,
                .librarySimilarity: 0.8,  // High weight for semantic similarity in research mode
                .authorStarred: 0.6,
                .collectionMatch: 0.5,
                .recency: 0.4,
                .smartSearchMatch: 0.7,
                // Negative features
                .mutedAuthor: -1.0,
                .mutedCategory: -0.8,
                .mutedVenue: -0.6,
                .dismissRateAuthor: -0.5,
            ]
        case .defaults:
            return Dictionary(uniqueKeysWithValues: FeatureType.allCases.map { ($0, $0.defaultWeight) })
        }
    }
}

// MARK: - Recommendation Engine Type

/// Available recommendation engine types.
///
/// Users can choose which engine to use based on their preferences:
/// - Classic: Fast, rule-based scoring using explicit signals
/// - Semantic (ANN): AI-powered embedding similarity for deeper content matching
/// - Hybrid: Combines both approaches for best results
public enum RecommendationEngineType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Classic rule-based recommendation using feature weights
    case classic

    /// Semantic similarity using embedding vectors and ANN search
    case semantic

    /// Hybrid approach combining classic and semantic signals
    case hybrid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .semantic: return "AI-Powered"
        case .hybrid: return "Hybrid"
        }
    }

    public var description: String {
        switch self {
        case .classic:
            return "Fast, rule-based ranking using your reading history and preferences"
        case .semantic:
            return "AI-powered semantic similarity finds papers related to your library"
        case .hybrid:
            return "Best of both: combines rule-based signals with AI similarity"
        }
    }

    public var icon: String {
        switch self {
        case .classic: return "slider.horizontal.3"
        case .semantic: return "brain"
        case .hybrid: return "sparkles"
        }
    }

    /// Whether this engine type requires embedding computation
    public var requiresEmbeddings: Bool {
        switch self {
        case .classic: return false
        case .semantic, .hybrid: return true
        }
    }
}
