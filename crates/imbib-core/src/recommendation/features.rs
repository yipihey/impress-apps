//! Feature extraction for publication recommendation scoring.
//!
//! This module implements the pure computation parts of feature extraction
//! for the recommendation engine. It receives pre-extracted data from Swift
//! (avoiding Core Data dependencies) and computes all features in batch.

use std::collections::{HashMap, HashSet};

/// Feature types for recommendation scoring
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FeatureType {
    // Explicit signals
    AuthorStarred,
    CollectionMatch,
    TagMatch,
    MutedAuthor,
    MutedCategory,
    MutedVenue,

    // Behavioral signals
    KeepRateAuthor,
    KeepRateVenue,
    DismissRateAuthor,
    ReadingTimeTopic,
    PdfDownloadAuthor,

    // Content signals
    CitationOverlap,
    AuthorCoauthorship,
    VenueFrequency,
    Recency,
    FieldCitationVelocity,
    SmartSearchMatch,
    LibrarySimilarity,
}

/// Input data for a single publication's feature extraction.
///
/// This struct contains pre-extracted data from Core Data objects,
/// allowing the feature computation to happen in Rust.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PublicationFeatureInput {
    /// Author family names (lowercased)
    pub author_family_names: Vec<String>,
    /// Title of the publication
    pub title: String,
    /// Tag names associated with the publication
    pub tag_names: Vec<String>,
    /// arXiv primary class (if available)
    pub primary_class: Option<String>,
    /// Journal/venue name (lowercased)
    pub journal: Option<String>,
    /// Publication year
    pub year: Option<i32>,
    /// Citation count
    pub citation_count: i32,
    /// Whether this publication is in a smart search results collection
    pub in_smart_search: bool,
    /// Pre-computed similarity scores from ANN search
    pub similarity_scores: Vec<f32>,
}

/// User preference profile data for feature extraction.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct ProfileData {
    /// Author name -> affinity score mapping
    pub author_affinities: HashMap<String, f64>,
    /// Topic keyword -> affinity score mapping
    pub topic_affinities: HashMap<String, f64>,
    /// Venue name -> affinity score mapping
    pub venue_affinities: HashMap<String, f64>,
}

/// Library context data for feature extraction.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LibraryContext {
    /// Author family names in the library (lowercased)
    pub library_author_names: Vec<String>,
    /// Venue name -> count in library
    pub venue_counts: HashMap<String, i32>,
    /// Current year for recency calculation
    pub current_year: i32,
}

impl Default for LibraryContext {
    fn default() -> Self {
        Self {
            library_author_names: Vec::new(),
            venue_counts: HashMap::new(),
            current_year: 2026,
        }
    }
}

/// Muted items that should be penalized.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct MutedItems {
    /// Muted author family names (lowercased)
    pub authors: Vec<String>,
    /// Muted arXiv categories (lowercased)
    pub categories: Vec<String>,
    /// Muted venues/journals (lowercased)
    pub venues: Vec<String>,
}

/// Result of feature extraction - a vector of feature values.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FeatureVector {
    /// Map of feature type to computed value (typically 0-1, or -1 to 0 for penalties)
    pub features: HashMap<FeatureType, f64>,
}

/// Extract all features for a single publication.
pub fn extract_features_single(
    input: &PublicationFeatureInput,
    profile: &ProfileData,
    library: &LibraryContext,
    muted: &MutedItems,
) -> FeatureVector {
    let mut features = HashMap::new();

    // Explicit signals
    features.insert(
        FeatureType::AuthorStarred,
        author_starred_score(&input.author_family_names, profile),
    );
    features.insert(
        FeatureType::CollectionMatch,
        collection_match_score(&input.title, profile),
    );
    features.insert(
        FeatureType::TagMatch,
        tag_match_score(&input.tag_names, profile),
    );
    features.insert(
        FeatureType::MutedAuthor,
        muted_author_penalty(&input.author_family_names, muted),
    );
    features.insert(
        FeatureType::MutedCategory,
        muted_category_penalty(input.primary_class.as_deref(), muted),
    );
    features.insert(
        FeatureType::MutedVenue,
        muted_venue_penalty(input.journal.as_deref(), muted),
    );

    // Behavioral signals
    features.insert(
        FeatureType::KeepRateAuthor,
        keep_rate_author_score(&input.author_family_names, profile),
    );
    features.insert(
        FeatureType::KeepRateVenue,
        keep_rate_venue_score(input.journal.as_deref(), profile),
    );
    features.insert(
        FeatureType::DismissRateAuthor,
        dismiss_rate_author_penalty(&input.author_family_names, profile),
    );
    features.insert(
        FeatureType::ReadingTimeTopic,
        reading_time_topic_score(&input.title, profile),
    );
    features.insert(
        FeatureType::PdfDownloadAuthor,
        pdf_download_author_score(&input.author_family_names, profile),
    );

    // Content signals
    features.insert(
        FeatureType::AuthorCoauthorship,
        author_coauthorship_score(&input.author_family_names, library),
    );
    features.insert(
        FeatureType::VenueFrequency,
        venue_frequency_score(input.journal.as_deref(), library),
    );
    features.insert(FeatureType::Recency, recency_score(input.year, library));
    features.insert(
        FeatureType::FieldCitationVelocity,
        citation_velocity_score(input.citation_count, input.year, library),
    );
    features.insert(
        FeatureType::SmartSearchMatch,
        if input.in_smart_search { 1.0 } else { 0.0 },
    );
    features.insert(
        FeatureType::LibrarySimilarity,
        library_similarity_score(&input.similarity_scores),
    );

    // Citation overlap is a placeholder (requires citation graph)
    features.insert(FeatureType::CitationOverlap, 0.0);

    FeatureVector { features }
}

/// Batch extract features for multiple publications.
///
/// This is the main entry point for efficient feature extraction.
/// Reduces FFI overhead by processing all publications in a single call.
pub fn extract_features_batch_internal(
    publications: Vec<PublicationFeatureInput>,
    profile: ProfileData,
    library: LibraryContext,
    muted: MutedItems,
) -> Vec<FeatureVector> {
    publications
        .iter()
        .map(|pub_input| extract_features_single(pub_input, &profile, &library, &muted))
        .collect()
}

/// UniFFI-exported batch feature extraction.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_features_batch(
    publications: Vec<PublicationFeatureInput>,
    profile: ProfileData,
    library: LibraryContext,
    muted: MutedItems,
) -> Vec<FeatureVector> {
    extract_features_batch_internal(publications, profile, library, muted)
}

// MARK: - Explicit Signals

/// Score based on author affinity from starred papers.
fn author_starred_score(authors: &[String], profile: &ProfileData) -> f64 {
    let mut max_affinity: f64 = 0.0;
    for author in authors {
        if let Some(&affinity) = profile.author_affinities.get(&author.to_lowercase()) {
            max_affinity = max_affinity.max(affinity);
        }
    }
    max_affinity.tanh()
}

/// Score based on collection membership patterns (topic keywords in title).
fn collection_match_score(title: &str, profile: &ProfileData) -> f64 {
    let keywords = extract_keywords(title);
    if keywords.is_empty() {
        return 0.0;
    }

    let mut topic_score: f64 = 0.0;
    for keyword in &keywords {
        if let Some(&affinity) = profile.topic_affinities.get(keyword) {
            topic_score += affinity;
        }
    }

    (topic_score / keywords.len() as f64).tanh()
}

/// Score based on tag affinity.
fn tag_match_score(tags: &[String], profile: &ProfileData) -> f64 {
    if tags.is_empty() {
        return 0.0;
    }

    let mut total_affinity: f64 = 0.0;
    for tag in tags {
        if let Some(&affinity) = profile.topic_affinities.get(&tag.to_lowercase()) {
            total_affinity += affinity;
        }
    }

    (total_affinity / tags.len() as f64).tanh()
}

/// Penalty for muted authors (-1.0 if muted, 0.0 otherwise).
fn muted_author_penalty(authors: &[String], muted: &MutedItems) -> f64 {
    let muted_authors: HashSet<&str> = muted.authors.iter().map(|s| s.as_str()).collect();
    for author in authors {
        if muted_authors.contains(author.to_lowercase().as_str()) {
            return -1.0;
        }
    }
    0.0
}

/// Penalty for muted arXiv categories.
fn muted_category_penalty(primary_class: Option<&str>, muted: &MutedItems) -> f64 {
    let muted_cats: HashSet<&str> = muted.categories.iter().map(|s| s.as_str()).collect();
    if let Some(class) = primary_class {
        if muted_cats.contains(class.to_lowercase().as_str()) {
            return -1.0;
        }
    }
    0.0
}

/// Penalty for muted venues/journals.
fn muted_venue_penalty(journal: Option<&str>, muted: &MutedItems) -> f64 {
    let muted_venues: HashSet<&str> = muted.venues.iter().map(|s| s.as_str()).collect();
    if let Some(j) = journal {
        if muted_venues.contains(j.to_lowercase().as_str()) {
            return -1.0;
        }
    }
    0.0
}

// MARK: - Behavioral Signals

/// Score based on historical keep rate for authors.
fn keep_rate_author_score(authors: &[String], profile: &ProfileData) -> f64 {
    let mut max_affinity: f64 = 0.0;
    for author in authors {
        if let Some(&affinity) = profile.author_affinities.get(&author.to_lowercase()) {
            if affinity > 0.0 {
                max_affinity = max_affinity.max(affinity);
            }
        }
    }
    max_affinity.tanh()
}

/// Score based on historical keep rate for venue.
fn keep_rate_venue_score(journal: Option<&str>, profile: &ProfileData) -> f64 {
    if let Some(j) = journal {
        if let Some(&affinity) = profile.venue_affinities.get(&j.to_lowercase()) {
            if affinity > 0.0 {
                return affinity.tanh();
            }
        }
    }
    0.0
}

/// Penalty based on historical dismiss rate for authors.
fn dismiss_rate_author_penalty(authors: &[String], profile: &ProfileData) -> f64 {
    let mut min_affinity: f64 = 0.0;
    for author in authors {
        if let Some(&affinity) = profile.author_affinities.get(&author.to_lowercase()) {
            if affinity < 0.0 {
                min_affinity = min_affinity.min(affinity);
            }
        }
    }
    if min_affinity < 0.0 {
        min_affinity.tanh()
    } else {
        0.0
    }
}

/// Score based on reading time spent on similar topics.
fn reading_time_topic_score(title: &str, profile: &ProfileData) -> f64 {
    let keywords = extract_keywords(title);
    if keywords.is_empty() {
        return 0.0;
    }

    let mut total_affinity: f64 = 0.0;
    for keyword in &keywords {
        if let Some(&affinity) = profile.topic_affinities.get(keyword) {
            if affinity > 0.0 {
                total_affinity += affinity;
            }
        }
    }

    (total_affinity / keywords.len() as f64).tanh()
}

/// Score based on PDF download patterns for this author.
fn pdf_download_author_score(authors: &[String], profile: &ProfileData) -> f64 {
    keep_rate_author_score(authors, profile) * 0.8
}

// MARK: - Content Signals

/// Score based on co-authorship with authors in user's library.
fn author_coauthorship_score(authors: &[String], library: &LibraryContext) -> f64 {
    if authors.is_empty() {
        return 0.0;
    }

    // Convert to HashSet for efficient lookup
    let library_authors: HashSet<&str> = library
        .library_author_names
        .iter()
        .map(|s| s.as_str())
        .collect();

    let match_count = authors
        .iter()
        .filter(|a| library_authors.contains(a.to_lowercase().as_str()))
        .count();

    match_count as f64 / authors.len() as f64
}

/// Score based on venue frequency in user's library.
fn venue_frequency_score(journal: Option<&str>, library: &LibraryContext) -> f64 {
    if let Some(j) = journal {
        if let Some(&count) = library.venue_counts.get(&j.to_lowercase()) {
            // Normalize (diminishing returns after 5 papers)
            return (count as f64 / 5.0).tanh();
        }
    }
    0.0
}

/// Score based on publication recency (exponential decay).
pub fn recency_score(year: Option<i32>, library: &LibraryContext) -> f64 {
    match year {
        Some(y) if y > 0 => {
            let age = library.current_year - y;
            // Exponential decay: 1.0 for current year, ~0.37 for 1 year old
            (-age as f64 / 2.0).exp()
        }
        _ => 0.5, // Unknown year gets neutral score
    }
}

/// Score based on citation velocity (citations per year).
pub fn citation_velocity_score(
    citation_count: i32,
    year: Option<i32>,
    library: &LibraryContext,
) -> f64 {
    if citation_count <= 0 {
        return 0.0;
    }

    match year {
        Some(y) if y > 0 => {
            let age = (library.current_year - y).max(1) as f64;
            let velocity = citation_count as f64 / age;
            // Normalize: 10 citations/year is considered high
            (velocity / 10.0).tanh()
        }
        _ => 0.0,
    }
}

/// Compute library similarity score from ANN search results.
pub fn library_similarity_score(similarities: &[f32]) -> f64 {
    if similarities.is_empty() {
        return 0.0;
    }

    // Use max similarity as primary signal
    let max_similarity = *similarities.iter().max_by(|a, b| a.total_cmp(b)).unwrap() as f64;

    // Add bonus for having multiple similar papers (diminishing returns)
    let count = similarities.len() as f64;
    let avg_similarity = similarities.iter().map(|&s| s as f64).sum::<f64>() / count;
    let count_bonus = (count / 5.0).tanh() * 0.2; // Up to 0.2 bonus for 5+ matches

    // Combine: 80% max + 20% average + count bonus, capped at 1.0
    let score = max_similarity * 0.8 + avg_similarity * 0.2 + count_bonus;
    score.min(1.0)
}

// MARK: - Helpers

/// Stop words for keyword extraction
const STOP_WORDS: &[&str] = &[
    "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by",
    "from", "as", "is", "was", "are", "were", "been", "using", "via", "based", "new", "novel",
    "approach", "method", "study",
];

/// Extract keywords from text.
fn extract_keywords(text: &str) -> Vec<String> {
    let stop_words: HashSet<&str> = STOP_WORDS.iter().copied().collect();

    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| word.len() >= 4 && !stop_words.contains(word))
        .map(|s| s.to_string())
        .collect()
}

/// UniFFI-exported keyword extraction for testing.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_title_keywords(title: String) -> Vec<String> {
    extract_keywords(&title)
}

/// UniFFI-exported recency score for testing.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn compute_recency_score(year: Option<i32>, current_year: i32) -> f64 {
    let library = LibraryContext {
        current_year,
        ..Default::default()
    };
    recency_score(year, &library)
}

/// UniFFI-exported citation velocity score for testing.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn compute_citation_velocity_score(
    citation_count: i32,
    year: Option<i32>,
    current_year: i32,
) -> f64 {
    let library = LibraryContext {
        current_year,
        ..Default::default()
    };
    citation_velocity_score(citation_count, year, &library)
}

/// UniFFI-exported library similarity score for testing.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn compute_library_similarity_score(similarities: Vec<f32>) -> f64 {
    library_similarity_score(&similarities)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_keywords() {
        let keywords = extract_keywords("Machine Learning for Natural Language Processing");
        assert!(keywords.contains(&"machine".to_string()));
        assert!(keywords.contains(&"learning".to_string()));
        assert!(keywords.contains(&"natural".to_string()));
        assert!(keywords.contains(&"language".to_string()));
        assert!(keywords.contains(&"processing".to_string()));
        // "for" is a stop word and should be excluded
        assert!(!keywords.contains(&"for".to_string()));
    }

    #[test]
    fn test_recency_score() {
        let library = LibraryContext {
            current_year: 2026,
            ..Default::default()
        };

        // Current year should be ~1.0
        let current = recency_score(Some(2026), &library);
        assert!(current > 0.9);

        // 1 year old should be ~0.6
        let one_year = recency_score(Some(2025), &library);
        assert!(one_year > 0.5 && one_year < 0.7);

        // 2 years old should be ~0.37
        let two_years = recency_score(Some(2024), &library);
        assert!(two_years > 0.3 && two_years < 0.4);

        // Unknown year gets neutral score
        let unknown = recency_score(None, &library);
        assert!((unknown - 0.5).abs() < 0.01);
    }

    #[test]
    fn test_citation_velocity_score() {
        let library = LibraryContext {
            current_year: 2026,
            ..Default::default()
        };

        // 10 citations in 1 year = high velocity
        let high = citation_velocity_score(10, Some(2025), &library);
        assert!(high > 0.7);

        // 10 citations in 5 years = moderate velocity
        let moderate = citation_velocity_score(10, Some(2021), &library);
        assert!(moderate > 0.1 && moderate < 0.3);

        // Zero citations = zero score
        let zero = citation_velocity_score(0, Some(2025), &library);
        assert!((zero - 0.0).abs() < 0.01);
    }

    #[test]
    fn test_library_similarity_score() {
        // Empty = 0
        assert!((library_similarity_score(&[]) - 0.0).abs() < 0.01);

        // Single high similarity
        let single = library_similarity_score(&[0.9]);
        assert!(single > 0.7);

        // Multiple high similarities (should get count bonus)
        let multiple = library_similarity_score(&[0.9, 0.8, 0.7, 0.6, 0.5]);
        assert!(multiple > library_similarity_score(&[0.9]));

        // Capped at 1.0
        let capped = library_similarity_score(&[1.0, 1.0, 1.0, 1.0, 1.0, 1.0]);
        assert!(capped <= 1.0);
    }

    #[test]
    fn test_muted_author_penalty() {
        let muted = MutedItems {
            authors: vec!["smith".to_string()],
            ..Default::default()
        };

        let authors = vec!["Smith".to_string(), "Jones".to_string()];
        let penalty = muted_author_penalty(&authors, &muted);
        assert!((penalty - (-1.0)).abs() < 0.01);

        let safe_authors = vec!["Jones".to_string()];
        let no_penalty = muted_author_penalty(&safe_authors, &muted);
        assert!((no_penalty - 0.0).abs() < 0.01);
    }

    #[test]
    fn test_batch_extraction() {
        let publications = vec![
            PublicationFeatureInput {
                author_family_names: vec!["Smith".to_string()],
                title: "Machine Learning Paper".to_string(),
                tag_names: vec![],
                primary_class: None,
                journal: Some("nature".to_string()),
                year: Some(2025),
                citation_count: 10,
                in_smart_search: false,
                similarity_scores: vec![0.8],
            },
            PublicationFeatureInput {
                author_family_names: vec!["Jones".to_string()],
                title: "Deep Learning Study".to_string(),
                tag_names: vec![],
                primary_class: None,
                journal: None,
                year: Some(2024),
                citation_count: 5,
                in_smart_search: true,
                similarity_scores: vec![],
            },
        ];

        let profile = ProfileData::default();
        let library = LibraryContext {
            current_year: 2026,
            ..Default::default()
        };
        let muted = MutedItems::default();

        let results = extract_features_batch_internal(publications, profile, library, muted);
        assert_eq!(results.len(), 2);

        // First paper should have smart search = 0
        assert!((results[0].features[&FeatureType::SmartSearchMatch] - 0.0).abs() < 0.01);

        // Second paper should have smart search = 1
        assert!((results[1].features[&FeatureType::SmartSearchMatch] - 1.0).abs() < 0.01);
    }
}
