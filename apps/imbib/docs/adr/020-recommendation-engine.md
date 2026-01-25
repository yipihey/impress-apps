# ADR-020: Transparent Recommendation Engine for Inbox Sorting

**Status:** Proposed
**Date:** 2026-01-19
**Author:** Tom Abel, adapted by Claude

## Context

imbib users accumulate papers in their Inbox from RSS feeds, ADS alerts, smart searches, and manual additions. A chronological or alphabetical list becomes unwieldy as volume grows. Users need help prioritizing what to read next.

However, academics are justifiably skeptical of opaque recommendation systems. Black-box algorithms risk:

- Filter bubbles that narrow research exposure
- Missing important work due to unexplainable algorithmic decisions
- Loss of user agency over their own reading priorities

A recommendation system for imbib must be transparent, interpretable, and keep the user in control.

## Current imbib Architecture

The following existing infrastructure supports a recommendation engine:

### Signal Collection (Already Implemented)

| Signal | Source | Location |
|--------|--------|----------|
| Keep action | User keeps paper to library | `InboxTriageService.keepToLibrary()` |
| Dismiss action | User dismisses paper | `InboxTriageService.dismissFromInbox()` |
| Mark as read | User reads paper | `LibraryViewModel.markAsRead()` |
| Star/flag | User stars paper | `CDPublication.isStarred` |
| PDF download | User downloads PDF | `PDFManager.importPDF()` |
| Reading progress | User scrolls through PDF | `ReadingPositionStore` |
| Mute author/topic | User blocks content | `CDMutedItem` |

### Feature Data (Already Available)

| Feature | Source | Field |
|---------|--------|-------|
| Authors | `CDPublicationAuthor` relationship | `familyName`, `givenName`, `order` |
| Venue/Journal | `CDPublication.fields["journal"]` | String |
| Year | `CDPublication.year` | Int16 |
| Citation count | `CDPublication.citationCount` | Int32 (via EnrichmentService) |
| Reference count | `CDPublication.referenceCount` | Int32 (via EnrichmentService) |
| arXiv category | Extracted from `arxivIDNormalized` | String |
| Keywords | `CDPublication.title`, `abstract` | String |
| Tags | `CDTag` relationship | User-defined |
| Collections | `CDCollection` membership | Topic indicator |

### Settings Infrastructure (Reusable Pattern)

- `SyncedSettingsStore` - Actor-based iCloud sync via `NSUbiquitousKeyValueStore`
- `InboxSettingsStore` - Inbox-specific preferences
- `EnrichmentSettingsStore` - Source priority settings

## Decision

We will implement a transparent, local-first recommendation engine integrated with imbib's existing infrastructure.

### Core Principles

1. **Fully interpretable:** Every score decomposes into human-readable factors
2. **User-adjustable:** All weights exposed and modifiable via Settings
3. **Local-first:** All computation on-device; no behavioral data transmitted
4. **Serendipity-preserving:** Explicit mechanisms to prevent filter bubbles
5. **Non-engagement-optimized:** Optimize for research utility, not time-in-app

### Scoring Model

A linear weighted sum of normalized features:

```
score(paper) = Σ (weight_i × feature_i(paper))
```

No neural networks, embeddings, or latent features. Every component inspectable.

### Feature Set

#### Explicit Signals (User-Provided)

| Feature | Description | Default Weight | Data Source |
|---------|-------------|----------------|-------------|
| `author_starred` | Author of a starred paper | 0.9 | `CDPublication.isStarred` + author |
| `collection_match` | Topic matches user collection | 0.7 | `CDCollection` membership |
| `tag_match` | Matches user-applied tags | 0.8 | `CDTag` relationship |
| `muted_author` | Author is muted | -1.0 | `CDMutedItem` (type: author) |
| `muted_category` | arXiv category is muted | -1.0 | `CDMutedItem` (type: arxivCategory) |
| `muted_venue` | Venue is muted | -1.0 | `CDMutedItem` (type: venue) |

#### Implicit Signals (Observed Behavior)

| Feature | Description | Default Weight | Data Source |
|---------|-------------|----------------|-------------|
| `keep_rate_author` | Fraction of kept papers from author | 0.6 | `InboxTriageService` history |
| `keep_rate_venue` | Fraction of kept papers from venue | 0.3 | `InboxTriageService` history |
| `dismiss_rate_author` | Fraction dismissed from author | -0.4 | `CDDismissedPaper` |
| `reading_time_topic` | Time spent on similar topics | 0.5 | `ReadingPositionStore` |
| `pdf_download_author` | Downloaded PDFs from author | 0.7 | `CDLinkedFile` tracking |

#### Content Signals (Computed via Enrichment)

| Feature | Description | Default Weight | Data Source |
|---------|-------------|----------------|-------------|
| `citation_overlap` | Paper cites N papers in library | 0.7 | `EnrichmentService` + ADS |
| `author_coauthorship` | Author co-authored with library author | 0.6 | `CDPublicationAuthor` graph |
| `venue_frequency` | User reads this venue frequently | 0.3 | `CDPublication` history |
| `recency` | Days since publication (decayed) | 0.4 | `CDPublication.year` |
| `field_citation_velocity` | Citation rate vs field average | 0.3 | `citationCount` / age |
| `smart_search_match` | Matches user's smart search query | 0.5 | `CDSmartSearch.query` |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Recommendation Layer                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐  │
│  │ RecommendationEngine │←│ FeatureExtractor │←│ SignalCollector│ │
│  │     (scoring)    │  │   (CDPublication) │  │  (actions)    │  │
│  └────────┬─────────┘  └──────────────────┘  └───────────────┘  │
│           │                                                      │
│  ┌────────▼─────────┐  ┌──────────────────┐                     │
│  │ RecommendationProfile│  │ RecommendationSettings│             │
│  │   (learned prefs) │  │    (user weights) │                   │
│  └──────────────────┘  └──────────────────┘                     │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                      Existing imbib Infrastructure               │
├─────────────────────────────────────────────────────────────────┤
│  InboxTriageService │ EnrichmentService │ SyncedSettingsStore   │
│  CDPublication      │ CDMutedItem       │ ReadingPositionStore  │
└─────────────────────────────────────────────────────────────────┘
```

### New Components

#### 1. RecommendationProfile (Core Data Entity)

```swift
@objc(CDRecommendationProfile)
public class CDRecommendationProfile: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var topicAffinities: Data      // [String: Double] JSON
    @NSManaged public var authorAffinities: Data     // [String: Double] JSON
    @NSManaged public var venueAffinities: Data      // [String: Double] JSON
    @NSManaged public var lastUpdated: Date
    @NSManaged public var trainingEventsData: Data   // [TrainingEvent] JSON
}
```

#### 2. RecommendationSettingsStore (Actor)

```swift
public actor RecommendationSettingsStore {
    public static let shared = RecommendationSettingsStore()

    public struct Settings: Codable {
        var featureWeights: [FeatureType: Double]
        var serendipitySlotFrequency: Int  // 1 per N papers
        var reRankThrottleMinutes: Int
        var negativePrefDecayDays: Int
        var isEnabled: Bool
    }

    public func settings() async -> Settings
    public func setWeight(_ weight: Double, for feature: FeatureType) async
    public func resetToDefaults() async
}
```

#### 3. SignalCollector (Actor)

Hooks into existing services to collect training signals:

```swift
public actor SignalCollector {
    public static let shared = SignalCollector()

    /// Called by InboxTriageService when user keeps a paper
    public func recordKeep(_ publication: CDPublication) async

    /// Called by InboxTriageService when user dismisses a paper
    public func recordDismiss(_ publication: CDPublication) async

    /// Called by LibraryViewModel when user marks as read
    public func recordRead(_ publication: CDPublication) async

    /// Called when user stars a paper
    public func recordStar(_ publication: CDPublication) async

    /// Called when user downloads PDF
    public func recordPDFDownload(_ publication: CDPublication) async
}
```

#### 4. FeatureExtractor

Extracts feature vectors from publications:

```swift
public struct FeatureExtractor {
    /// Extract all features for a publication
    public static func extract(
        from publication: CDPublication,
        profile: CDRecommendationProfile,
        library: CDLibrary
    ) -> [FeatureType: Double]

    /// Extract author affinity score
    public static func authorAffinity(
        _ publication: CDPublication,
        profile: CDRecommendationProfile
    ) -> Double

    /// Extract topic match score from collections/tags
    public static func topicMatch(
        _ publication: CDPublication,
        library: CDLibrary
    ) -> Double
}
```

#### 5. RecommendationEngine (Actor)

Main scoring and ranking engine:

```swift
public actor RecommendationEngine {
    public static let shared = RecommendationEngine()

    /// Score a single publication
    public func score(_ publication: CDPublication) async -> RecommendationScore

    /// Rank publications for Inbox display
    public func rank(_ publications: [CDPublication]) async -> [RankedPublication]

    /// Get score breakdown for UI display
    public func scoreBreakdown(_ publication: CDPublication) async -> ScoreBreakdown

    /// Update weights based on user action (online learning)
    public func train(on event: TrainingEvent) async
}

public struct RecommendationScore: Sendable {
    let total: Double
    let breakdown: [FeatureType: Double]
    let explanation: String  // Human-readable
}

public struct RankedPublication: Sendable {
    let publication: CDPublication
    let score: RecommendationScore
    let isSerendipitySlot: Bool
}
```

### Integration Points

#### 1. InboxTriageService Integration

```swift
// In InboxTriageService.keepToLibrary()
func keepToLibrary(...) -> TriageResult {
    // Existing code...

    // NEW: Record signal for recommendation training
    Task {
        await SignalCollector.shared.recordKeep(publication)
    }

    return result
}
```

#### 2. Inbox List View Integration

```swift
// In InboxListView or equivalent
@State private var rankedPublications: [RankedPublication] = []

var body: some View {
    List(rankedPublications) { ranked in
        InboxRow(publication: ranked.publication)
            .overlay(alignment: .topTrailing) {
                if ranked.isSerendipitySlot {
                    SerendipityBadge()
                }
            }
            .contextMenu {
                Button("Why this ranking?") {
                    showScoreBreakdown(ranked)
                }
            }
    }
    .task {
        rankedPublications = await RecommendationEngine.shared.rank(inboxPublications)
    }
}
```

#### 3. Settings UI Integration

Add "Recommendations" tab to Settings:

```swift
struct RecommendationSettingsTab: View {
    @State private var settings: RecommendationSettingsStore.Settings

    var body: some View {
        Form {
            Section("Feature Weights") {
                ForEach(FeatureType.allCases) { feature in
                    WeightSlider(feature: feature, weight: $settings.featureWeights[feature])
                }
            }

            Section("Anti-Filter-Bubble") {
                Stepper("Serendipity slot: 1 per \(settings.serendipitySlotFrequency) papers")
                Stepper("Negative preference decay: \(settings.negativePrefDecayDays) days")
            }

            Section("Presets") {
                Button("Research Mode") { applyPreset(.research) }
                Button("Broad Survey") { applyPreset(.broadSurvey) }
                Button("Reset to Defaults") { resetDefaults() }
            }
        }
    }
}
```

### Transparency UI

#### Score Breakdown Popover

When user taps "Why this ranking?" on any paper:

```
┌─────────────────────────────────────────────┐
│  Why this ranking?                     [×]  │
├─────────────────────────────────────────────┤
│                                             │
│  Relevance Score: 0.78                      │
│                                             │
│  ▸ Author familiarity      ████████░░ +0.28 │
│    You've kept 6/7 papers by FirstAuthor    │
│                                             │
│  ▸ Cites your library      ██████░░░░ +0.21 │
│    References 4 papers you've saved         │
│                                             │
│  ▸ Smart search match      █████░░░░░ +0.18 │
│    Matches: "cosmology simulations"         │
│                                             │
│  ▸ Recent publication      ███░░░░░░░ +0.11 │
│    Published 5 days ago                     │
│                                             │
│  [Adjust weights...]       [Less like this] │
└─────────────────────────────────────────────┘
```

#### Training History Log

Accessible from Recommendation Settings:

```
Today
  09:41  Kept "Turbulence in ICM"
         → +0.05 topic:ICM, +0.08 author:ZuHone
  09:38  Dismissed "Exoplanet transits"
         → −0.03 topic:exoplanets

Yesterday
  16:22  Starred "AMR methods review"
         → +0.12 topic:AMR, +0.10 author:Bryan
```

Each entry shows weight changes. User can undo any training event.

### Anti-Filter-Bubble Mechanisms

#### 1. Serendipity Slot

Reserve 1 slot per N papers (configurable, default 10) for high-impact work outside usual topics:

- Selection: High `field_citation_velocity` + low topic match
- Badge: "📡 Trending outside your usual areas"

#### 2. Negative Preference Decay

Suppressed topics regain neutral weight over time (configurable τ, default 90 days).

#### 3. Diversity Warning

Show warning if Inbox ranking becomes highly concentrated:

> "⚠️ 85% of top-ranked papers are on 2 topics. [Show more diversity]"

### Cold Start Strategy

| Condition | Bootstrap Method |
|-----------|------------------|
| Library ≥20 papers | Analyze topics, authors, venues from existing collection |
| Smart searches exist | Use query terms as topic indicators |
| Group feeds exist | Use monitored authors as preferences |
| Muted items exist | Use as negative preferences |
| None of above | Chronological + citation velocity only |

### Learning Mechanism

**Algorithm:** Online stochastic gradient descent with low learning rate (η = 0.05)

**Training signals:**

| Action | Interpretation | Weight Update |
|--------|----------------|---------------|
| Keep paper | Positive example | +η for matching features |
| Dismiss paper | Negative example | −η for matching features |
| Star paper | Strong positive | +2η for matching features |
| Download PDF | Moderate positive | +η for matching features |
| Read paper | Positive | +0.5η for matching features |

**Update timing:**
- Weight updates: Immediate on user action
- Re-ranking: Throttled (configurable, default 5 min)
  - On Inbox open (if >threshold since last rank)
  - On explicit refresh
  - Never mid-triage session

### Data Model

```swift
public struct TrainingEvent: Codable, Sendable {
    let id: UUID
    let date: Date
    let action: TrainingAction
    let publicationID: UUID
    let publicationTitle: String
    let weightDeltas: [String: Double]  // feature -> delta
}

public enum TrainingAction: String, Codable, Sendable {
    case kept, dismissed, starred, read, pdfDownloaded, moreLikeThis, lessLikeThis
}

public enum FeatureType: String, Codable, CaseIterable, Sendable {
    // Explicit
    case authorStarred
    case collectionMatch
    case tagMatch
    case mutedAuthor
    case mutedCategory
    case mutedVenue

    // Implicit
    case keepRateAuthor
    case keepRateVenue
    case dismissRateAuthor
    case readingTimeTopic
    case pdfDownloadAuthor

    // Content
    case citationOverlap
    case authorCoauthorship
    case venueFrequency
    case recency
    case fieldCitationVelocity
    case smartSearchMatch
}
```

### Export and Inspection

User can export full preference model as JSON from Settings:

```json
{
  "featureWeights": {
    "authorStarred": 0.9,
    "citationOverlap": 0.7
  },
  "topicAffinities": {
    "astro-ph.CO": 0.8,
    "astro-ph.GA": 0.6,
    "astro-ph.EP": -0.2
  },
  "authorAffinities": {
    "Bryan, G.": 0.9,
    "Springel, V.": 0.7
  },
  "trainingHistory": [...]
}
```

## Consequences

### Benefits

- **Trust:** Users see exactly why papers are ranked
- **Control:** Every preference adjustable; user remains in charge
- **Privacy:** No behavioral data leaves the device
- **Integration:** Leverages existing imbib infrastructure
- **Serendipity:** Explicit mechanisms prevent intellectual narrowing

### Costs

- **UI complexity:** Transparency UI adds screens/interactions
- **Storage:** Training history grows over time (need pruning)
- **Performance:** Feature extraction adds computation

### Risks

- **Over-reliance:** Users may stop evaluating papers critically
  - *Mitigation:* Serendipity slots and diversity warnings
- **Cold start UX:** Initial rankings may be poor
  - *Mitigation:* Fall back to recency + citation velocity

## Implementation Plan

| Phase | Scope | Files |
|-------|-------|-------|
| 1 | Core Data model (`CDRecommendationProfile`) | `ManagedObjects.swift`, `PersistenceController.swift` |
| 2 | `RecommendationSettingsStore` (actor) | `Recommendation/RecommendationSettings.swift` |
| 3 | `SignalCollector` + integration hooks | `Recommendation/SignalCollector.swift`, `InboxTriageService.swift` |
| 4 | `FeatureExtractor` | `Recommendation/FeatureExtractor.swift` |
| 5 | `RecommendationEngine` (scoring/ranking) | `Recommendation/RecommendationEngine.swift` |
| 6 | Online learning (weight updates) | `Recommendation/OnlineLearner.swift` |
| 7 | Score breakdown popover UI | `SharedViews/ScoreBreakdownView.swift` |
| 8 | Recommendation Settings tab | `Settings/RecommendationSettingsTab.swift` |
| 9 | Training history log | `SharedViews/TrainingHistoryView.swift` |
| 10 | Cold start + serendipity | `Recommendation/ColdStartBootstrap.swift` |
| 11 | Export/import + testing | Tests, export functionality |

## Future Considerations

- **Citation graph integration:** Deeper ADS integration for `citation_overlap`
- **Cross-reference with drafts:** Integration with LaTeX manuscripts
- **Conference deadlines:** Boost papers relevant to upcoming submissions
- **A/B self-testing:** Let user compare ranked vs. chronological

## References

- Ekstrand, M. D., Riedl, J. T., & Konstan, J. A. (2011). Collaborative filtering recommender systems.
- Knijnenburg, B. P., et al. (2012). Explaining the user experience of recommender systems.
- Tintarev, N., & Masthoff, J. (2007). A survey of explanations in recommender systems.
