//! Enrichment domain types
//!
//! Types for publication enrichment from external sources like Semantic Scholar,
//! OpenAlex, and ADS.

use serde::{Deserialize, Serialize};

/// Open access availability status
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
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

impl OpenAccessStatus {
    pub fn display_name(&self) -> &'static str {
        match self {
            OpenAccessStatus::Gold => "Gold Open Access",
            OpenAccessStatus::Green => "Green Open Access",
            OpenAccessStatus::Bronze => "Bronze Open Access",
            OpenAccessStatus::Hybrid => "Hybrid Open Access",
            OpenAccessStatus::Closed => "Closed Access",
            OpenAccessStatus::Unknown => "Unknown",
        }
    }
}

/// Capabilities that an enrichment source can provide
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
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

impl EnrichmentCapability {
    pub fn display_name(&self) -> &'static str {
        match self {
            EnrichmentCapability::CitationCount => "Citation Count",
            EnrichmentCapability::References => "References",
            EnrichmentCapability::Citations => "Citing Papers",
            EnrichmentCapability::Abstract => "Abstract",
            EnrichmentCapability::PdfUrl => "PDF URL",
            EnrichmentCapability::AuthorStats => "Author Stats",
            EnrichmentCapability::OpenAccess => "Open Access",
            EnrichmentCapability::Venue => "Venue",
        }
    }
}

/// Author statistics
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
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
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
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

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn enrichment_data_is_stale(data: &EnrichmentData, threshold_days: i32) -> bool {
    data.is_stale(threshold_days)
}

/// Priority levels for enrichment requests
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
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

impl EnrichmentPriority {
    pub fn display_name(&self) -> &'static str {
        match self {
            EnrichmentPriority::UserTriggered => "User Triggered",
            EnrichmentPriority::RecentlyViewed => "Recently Viewed",
            EnrichmentPriority::LibraryPaper => "Library Paper",
            EnrichmentPriority::BackgroundSync => "Background Sync",
        }
    }
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn enrichment_priority_display_name(priority: EnrichmentPriority) -> String {
    priority.display_name().to_string()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn open_access_status_display_name(status: OpenAccessStatus) -> String {
    status.display_name().to_string()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn enrichment_capability_display_name(capability: EnrichmentCapability) -> String {
    capability.display_name().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_open_access_display_names() {
        assert_eq!(OpenAccessStatus::Gold.display_name(), "Gold Open Access");
        assert_eq!(OpenAccessStatus::Closed.display_name(), "Closed Access");
    }

    #[test]
    fn test_enrichment_priority_ordering() {
        assert!(EnrichmentPriority::UserTriggered < EnrichmentPriority::BackgroundSync);
        assert!(EnrichmentPriority::RecentlyViewed < EnrichmentPriority::LibraryPaper);
    }

    #[test]
    fn test_enrichment_capability_display_names() {
        assert_eq!(
            EnrichmentCapability::CitationCount.display_name(),
            "Citation Count"
        );
        assert_eq!(EnrichmentCapability::PdfUrl.display_name(), "PDF URL");
    }
}
