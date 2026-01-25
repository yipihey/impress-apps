//! Enrichment domain types
//!
//! Types for publication enrichment from external sources like Semantic Scholar,
//! OpenAlex, and ADS.

use serde::{Deserialize, Serialize};

/// Open access availability status
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default, uniffi::Enum,
)]
pub enum OpenAccessStatus {
    /// Published in an open access journal
    Gold,
    /// Self-archived (preprint/postprint)
    Green,
    /// Free to read but not openly licensed
    Bronze,
    /// Open access article in subscription journal
    Hybrid,
    /// Not freely accessible
    Closed,
    /// Status not determined
    #[default]
    Unknown,
}

/// Capabilities that an enrichment source can provide
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum EnrichmentCapability {
    /// Citation count
    CitationCount,
    /// List of references
    References,
    /// List of citing papers
    Citations,
    /// Paper abstract
    Abstract,
    /// PDF download URLs
    PdfUrl,
    /// Author statistics (h-index, etc.)
    AuthorStats,
    /// Open access status
    OpenAccess,
    /// Venue/journal information
    Venue,
}

// Note: PaperStub is defined in sources/ads.rs and re-exported from there

/// Author statistics
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct AuthorStats {
    /// Author ID (source-specific)
    pub author_id: String,
    /// Author name
    pub name: String,
    /// h-index if available
    pub h_index: Option<i32>,
    /// Total citation count
    pub citation_count: Option<i32>,
    /// Total paper count
    pub paper_count: Option<i32>,
    /// List of affiliations
    pub affiliations: Vec<String>,
}

/// Enrichment data for a publication
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct EnrichmentData {
    /// Citation count
    pub citation_count: Option<i32>,
    /// Reference count
    pub reference_count: Option<i32>,
    /// Abstract text
    pub abstract_text: Option<String>,
    /// PDF download URLs
    pub pdf_urls: Vec<String>,
    /// Open access status
    pub open_access_status: OpenAccessStatus,
    /// Venue (journal/conference)
    pub venue: Option<String>,
    /// Source that provided this data
    pub source: String,
    /// Unix timestamp when data was fetched
    pub fetched_at_unix: i64,
}

impl EnrichmentData {
    /// Check if the data is stale (older than threshold days)
    pub fn is_stale(&self, threshold_days: i32) -> bool {
        let now = chrono::Utc::now().timestamp();
        let age_seconds = now - self.fetched_at_unix;
        let threshold_seconds = (threshold_days as i64) * 24 * 60 * 60;
        age_seconds > threshold_seconds
    }
}

pub(crate) fn enrichment_data_is_stale_internal(
    data: &EnrichmentData,
    threshold_days: i32,
) -> bool {
    data.is_stale(threshold_days)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn enrichment_data_is_stale(data: &EnrichmentData, threshold_days: i32) -> bool {
    enrichment_data_is_stale_internal(data, threshold_days)
}

/// Priority levels for enrichment requests
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, uniffi::Enum)]
pub enum EnrichmentPriority {
    /// User explicitly requested enrichment
    UserTriggered,
    /// User recently viewed the paper
    RecentlyViewed,
    /// Paper is in the user's library
    LibraryPaper,
    /// Background periodic refresh
    BackgroundSync,
}

pub(crate) fn enrichment_priority_display_name_internal(priority: EnrichmentPriority) -> String {
    match priority {
        EnrichmentPriority::UserTriggered => "User Triggered".to_string(),
        EnrichmentPriority::RecentlyViewed => "Recently Viewed".to_string(),
        EnrichmentPriority::LibraryPaper => "Library Paper".to_string(),
        EnrichmentPriority::BackgroundSync => "Background Sync".to_string(),
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn enrichment_priority_display_name(priority: EnrichmentPriority) -> String {
    enrichment_priority_display_name_internal(priority)
}

pub(crate) fn open_access_status_display_name_internal(status: OpenAccessStatus) -> String {
    match status {
        OpenAccessStatus::Gold => "Gold Open Access".to_string(),
        OpenAccessStatus::Green => "Green Open Access".to_string(),
        OpenAccessStatus::Bronze => "Bronze Open Access".to_string(),
        OpenAccessStatus::Hybrid => "Hybrid Open Access".to_string(),
        OpenAccessStatus::Closed => "Closed Access".to_string(),
        OpenAccessStatus::Unknown => "Unknown".to_string(),
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn open_access_status_display_name(status: OpenAccessStatus) -> String {
    open_access_status_display_name_internal(status)
}

pub(crate) fn enrichment_capability_display_name_internal(
    capability: EnrichmentCapability,
) -> String {
    match capability {
        EnrichmentCapability::CitationCount => "Citation Count".to_string(),
        EnrichmentCapability::References => "References".to_string(),
        EnrichmentCapability::Citations => "Citing Papers".to_string(),
        EnrichmentCapability::Abstract => "Abstract".to_string(),
        EnrichmentCapability::PdfUrl => "PDF URL".to_string(),
        EnrichmentCapability::AuthorStats => "Author Stats".to_string(),
        EnrichmentCapability::OpenAccess => "Open Access".to_string(),
        EnrichmentCapability::Venue => "Venue".to_string(),
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn enrichment_capability_display_name(capability: EnrichmentCapability) -> String {
    enrichment_capability_display_name_internal(capability)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_open_access_display_names() {
        assert_eq!(
            open_access_status_display_name(OpenAccessStatus::Gold),
            "Gold Open Access"
        );
        assert_eq!(
            open_access_status_display_name(OpenAccessStatus::Closed),
            "Closed Access"
        );
    }

    #[test]
    fn test_enrichment_priority_ordering() {
        assert!(EnrichmentPriority::UserTriggered < EnrichmentPriority::BackgroundSync);
        assert!(EnrichmentPriority::RecentlyViewed < EnrichmentPriority::LibraryPaper);
    }

    #[test]
    fn test_enrichment_capability_display_names() {
        assert_eq!(
            enrichment_capability_display_name(EnrichmentCapability::CitationCount),
            "Citation Count"
        );
        assert_eq!(
            enrichment_capability_display_name(EnrichmentCapability::PdfUrl),
            "PDF URL"
        );
    }
}
